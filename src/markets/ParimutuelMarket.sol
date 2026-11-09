// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { MarketTypes } from "./MarketTypes.sol";
import { IEligibilityGate, IPredictionRegistry, IParimutuelMarket } from "./interfaces/IMarkets.sol";

/**
 * @title ParimutuelMarket
 * @notice One parimutuel pool in imdUSD, deployed as an EIP-1167 clone by MarketFactory with its terms fixed.
 *
 *         Lifecycle: Open -> Locked -> Proposed -> (Disputed -> Escalated) -> Final | Void.
 *         - Open until `lockAt`. Stakes need a live eligibility pass; per-wallet and per-market caps apply;
 *           the creator and the crew wallets they declared are denied.
 *         - The primary resolver proposes an outcome after `resolveAfter`. If the template locks on the source
 *           clock, the proposal carries the attested official start, and every stake placed after
 *           `attestedStart - lockMargin` is refunded instead of counted.
 *         - Anyone may dispute during the dispute window through the DisputeModule. A second, independent panel
 *           either upholds the proposal or the market escalates to the council, which can only pick one of
 *           the coded outcomes or VOID, within 7 days, else the market voids.
 *         - No proposal within 7 days of `resolveAfter` voids the market. Void refunds every stake in full.
 *         - Final: winners share the losing side minus the rake. Rake legs go to the treasury, the resolver
 *           budget and the insurance reserve; the creator's leg (and bond) vests 7 days after resolution and
 *           is slashable by the council until then.
 *         - One year after resolution, anything left is swept to the treasury.
 *
 *         There is no owner and no admin function. Only the snapshotted resolver, dispute module and council
 *         can move the state machine, and none of them can send stakes anywhere but back to stakers.
 */
contract ParimutuelMarket is ReentrancyGuard, IParimutuelMarket {
    using SafeTransferLib for address;

    uint256 public constant BPS = 10_000;
    uint64 public constant PROPOSE_GRACE = 7 days;
    uint64 public constant COUNCIL_WINDOW = 7 days;
    uint64 public constant CREATOR_VEST = 7 days;
    uint64 public constant SWEEP_DELAY = 365 days;

    /// @dev Cumulative stake up to and including `ts`. Timestamps are non-decreasing per array.
    struct Checkpoint {
        uint64 ts;
        uint192 cum;
    }

    MarketTypes.Terms internal _t;
    bool internal _initialized;

    MarketTypes.State internal _state;
    uint8 public proposedOutcome;
    /// @notice The winning outcome. Nonzero only when the market is Final; Void leaves it 0.
    uint8 public finalOutcome;
    /// @notice What the last deciding step chose (0 = VOID), including a side nobody counted on, which voids the
    ///         market. The dispute module settles bonds on this: a dispute is lost if the decision matched the proposal.
    uint8 public decidedOutcome;
    /// @notice True when the market voided because nobody resolved it in time (no proposal, or no council).
    bool public timedOut;
    bool public swept;
    bool public creatorSlashed;
    bool public creatorPaid;
    address public proposer;
    uint64 public attestedStart;
    /// @notice Stakes with a timestamp after this are refunded rather than counted.
    uint64 public cutoff;
    uint64 public disputeDeadline;
    uint64 public escalatedAt;
    uint64 public resolvedAt;

    uint256 public totalStaked;
    /// @notice Stake-derived imdUSD still held by this market (mirrors this market's share of the registry's OI).
    uint256 public openInterest;
    uint256 public bondHeld;
    uint256 public creatorEscrow;

    /// @notice Settlement figures, fixed at Final.
    uint256 public countedPool;
    uint256 public winningPool;
    uint256 public distributable;

    mapping(uint256 outcome => Checkpoint[]) internal _outcomeCk;
    mapping(address user => mapping(uint256 outcome => Checkpoint[])) internal _userCk;
    mapping(address user => uint256) public stakedBy;
    mapping(address => bool) public isDenied;
    mapping(address => bool) public claimed;
    mapping(address => bool) public refunded;

    event Initialized(address indexed creator, bytes32 indexed questionHash, uint64 lockAt, uint64 resolveAfter);
    event Staked(address indexed user, address indexed payer, uint8 indexed outcome, uint256 amount);
    event Proposed(
        uint8 outcome, uint64 attestedStart, uint64 cutoff, address indexed proposer, uint64 disputeDeadline
    );
    event Disputed();
    event Escalated();
    event Finalized(uint8 indexed outcome, uint256 countedPool, uint256 winningPool, uint256 rake);
    event Voided(uint8 decidedOutcome, bool timedOut);
    event RakePaid(uint256 toTreasury, uint256 toResolverBudget, uint256 toInsurance, uint256 creatorEscrow);
    event Claimed(address indexed user, uint256 amount);
    event Refunded(address indexed user, uint256 amount);
    event CreatorPaid(address indexed creator, uint256 fee, uint256 bond);
    event CreatorSlashed(uint256 amount);
    event Swept(address indexed treasury, uint256 amount);

    error AlreadyInitialized();
    error NotOpen();
    error WrongState();
    error InvalidOutcome();
    error BelowMinStake();
    error Denied();
    error WalletCapExceeded();
    error MarketCapExceeded();
    error NotDoor();
    error NotResolver();
    error NotDisputeModule();
    error NotCouncil();
    error TooEarly();
    error TooLate();
    error MissingStart();
    error UnknownCode();
    error NothingToPay();
    error AlreadySwept();
    error CreatorVesting();

    constructor() {
        // The implementation is never used directly.
        _initialized = true;
    }

    // ── setup ───────────────────────────────────────────────────────────────

    /// @notice Called once by the factory in the clone's creation transaction.
    function initialize(MarketTypes.Terms calldata terms_, address[] calldata denied) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _t = terms_;
        for (uint256 i; i < denied.length; ++i) {
            isDenied[denied[i]] = true;
        }
        bondHeld = terms_.creatorBond;
        emit Initialized(terms_.creator, terms_.questionHash, terms_.lockAt, terms_.resolveAfter);
    }

    // ── views ───────────────────────────────────────────────────────────────

    function terms() external view returns (MarketTypes.Terms memory) {
        return _t;
    }

    function state() public view returns (MarketTypes.State) {
        MarketTypes.State s = _state;
        if (s == MarketTypes.State.Open && block.timestamp >= _t.lockAt) return MarketTypes.State.Locked;
        return s;
    }

    /// @notice Total staked on `outcome` (every stake, counted or late).
    function outcomePool(uint8 outcome) public view returns (uint256) {
        Checkpoint[] storage ck = _outcomeCk[outcome];
        return ck.length == 0 ? 0 : ck[ck.length - 1].cum;
    }

    /// @notice Total staked by `user` on `outcome` (every stake, counted or late).
    function stakeOf(address user, uint8 outcome) external view returns (uint256) {
        Checkpoint[] storage ck = _userCk[user][outcome];
        return ck.length == 0 ? 0 : ck[ck.length - 1].cum;
    }

    /// @notice Staked on `outcome` at or before `ts`.
    function outcomePoolAt(uint8 outcome, uint64 ts) public view returns (uint256) {
        return _cumAt(_outcomeCk[outcome], ts);
    }

    function userStakeAt(address user, uint8 outcome, uint64 ts) public view returns (uint256) {
        return _cumAt(_userCk[user][outcome], ts);
    }

    /// @notice The rake this market would take from a losing side of `losing`.
    function rakeOn(uint256 losing) public view returns (uint256) {
        MarketTypes.RakeSplit memory r = _t.rake;
        return losing * r.treasuryBps / BPS + losing * r.creatorBps / BPS + losing * r.resolverBps / BPS + losing
            * r.insuranceBps / BPS;
    }

    /// @notice Map an attested answer to an outcome (0 = VOID). Reverts on an answer the template cannot map.
    function outcomeForAnswer(uint256 answer) external view returns (uint8) {
        MarketTypes.AnswerMode mode = _t.answerMode;
        if (mode == MarketTypes.AnswerMode.Coded) {
            bytes memory map = _t.codeMap;
            if (answer >= map.length) revert UnknownCode();
            return uint8(map[answer]);
        }
        if (mode == MarketTypes.AnswerMode.Bool) {
            if (answer > 1) revert UnknownCode();
            return answer == 1 ? 1 : 2;
        }
        return answer > _t.threshold ? 1 : 2;
    }

    /// @notice Winnings `user` can claim now (zero unless Final).
    function claimable(address user) public view returns (uint256) {
        if (_state != MarketTypes.State.Final || swept || claimed[user]) return 0;
        uint256 s = _cumAt(_userCk[user][finalOutcome], cutoff);
        if (s == 0) return 0;
        return s + FixedPointMathLib.fullMulDiv(s, distributable, winningPool);
    }

    /// @notice Refund `user` can take now: everything on Void, the late (uncounted) stakes on Final.
    function refundable(address user) public view returns (uint256) {
        if (swept || refunded[user]) return 0;
        MarketTypes.State s = _state;
        if (s == MarketTypes.State.Void) return stakedBy[user];
        if (s != MarketTypes.State.Final) return 0;
        uint256 counted;
        uint8 n = _t.outcomeCount;
        for (uint8 i = 1; i <= n; ++i) {
            counted += _cumAt(_userCk[user][i], cutoff);
        }
        return stakedBy[user] - counted;
    }

    // ── staking ─────────────────────────────────────────────────────────────

    function stake(uint8 outcome, uint256 amount, MarketTypes.EligibilityPass calldata pass, bytes calldata sig)
        external
        nonReentrant
    {
        _stake(msg.sender, msg.sender, outcome, amount, pass, sig);
    }

    /// @notice Stake on behalf of `user`, paid by the caller. Only the registered USDC door.
    function stakeFor(
        address user,
        uint8 outcome,
        uint256 amount,
        MarketTypes.EligibilityPass calldata pass,
        bytes calldata sig
    ) external nonReentrant {
        if (msg.sender != _t.door) revert NotDoor();
        _stake(msg.sender, user, outcome, amount, pass, sig);
    }

    // ── resolution ──────────────────────────────────────────────────────────

    /// @notice The primary resolver proposes an outcome (0 = VOID) and, for source-clock templates, the
    ///         attested official start.
    function propose(uint8 outcome, uint64 attestedStart_, address proposer_) external {
        if (msg.sender != _t.resolver) revert NotResolver();
        if (state() != MarketTypes.State.Locked) revert WrongState();
        if (block.timestamp < _t.resolveAfter) revert TooEarly();
        if (block.timestamp > uint256(_t.resolveAfter) + PROPOSE_GRACE) revert TooLate();
        if (outcome > _t.outcomeCount) revert InvalidOutcome();
        if (_t.startQuestionHash != bytes32(0) && attestedStart_ == 0) revert MissingStart();

        uint64 c = _t.lockAt;
        if (_t.startQuestionHash != bytes32(0)) {
            uint64 latest = attestedStart_ > _t.lockMargin ? attestedStart_ - _t.lockMargin : 0;
            if (latest < c) c = latest;
        }
        cutoff = c;
        attestedStart = attestedStart_;
        proposedOutcome = outcome;
        proposer = proposer_;
        uint64 deadline = uint64(block.timestamp) + _t.disputeWindow;
        disputeDeadline = deadline;
        _state = MarketTypes.State.Proposed;
        emit Proposed(outcome, attestedStart_, c, proposer_, deadline);
    }

    /// @notice Settle an undisputed proposal once the dispute window has closed. Anyone may call.
    function finalize() external nonReentrant {
        if (_state != MarketTypes.State.Proposed || block.timestamp < disputeDeadline) revert WrongState();
        _settle(proposedOutcome);
    }

    /// @notice Void a market nobody resolved in time: no proposal within PROPOSE_GRACE of `resolveAfter`, or
    ///         no council decision within COUNCIL_WINDOW of escalation. Anyone may call.
    function voidUnresolved() external {
        MarketTypes.State s = state();
        bool expired;
        if (s == MarketTypes.State.Open || s == MarketTypes.State.Locked) {
            expired = block.timestamp > uint256(_t.resolveAfter) + PROPOSE_GRACE;
        } else if (s == MarketTypes.State.Escalated) {
            expired = block.timestamp > uint256(escalatedAt) + COUNCIL_WINDOW;
        }
        if (!expired) revert WrongState();
        timedOut = true;
        resolvedAt = uint64(block.timestamp);
        finalOutcome = MarketTypes.VOID;
        _void();
    }

    // ── dispute module and council ──────────────────────────────────────────

    function markDisputed() external {
        if (msg.sender != _t.disputeModule) revert NotDisputeModule();
        if (_state != MarketTypes.State.Proposed || block.timestamp >= disputeDeadline) revert WrongState();
        _state = MarketTypes.State.Disputed;
        emit Disputed();
    }

    /// @notice The second panel agreed with the proposal.
    function upholdProposal() external nonReentrant {
        if (msg.sender != _t.disputeModule) revert NotDisputeModule();
        if (_state != MarketTypes.State.Disputed) revert WrongState();
        _settle(proposedOutcome);
    }

    /// @notice The panels disagreed, or the second panel did not answer in time.
    function escalate() external {
        if (msg.sender != _t.disputeModule) revert NotDisputeModule();
        if (_state != MarketTypes.State.Disputed) revert WrongState();
        _state = MarketTypes.State.Escalated;
        escalatedAt = uint64(block.timestamp);
        emit Escalated();
    }

    /// @notice The council picks one of the coded outcomes or VOID (0). It cannot do anything else.
    function councilResolve(uint8 outcome) external nonReentrant {
        if (msg.sender != _t.council) revert NotCouncil();
        if (_state != MarketTypes.State.Escalated) revert WrongState();
        if (block.timestamp > uint256(escalatedAt) + COUNCIL_WINDOW) revert TooLate();
        if (outcome > _t.outcomeCount) revert InvalidOutcome();
        _settle(outcome);
    }

    /// @notice The council forfeits the creator's bond and fee share to the insurance reserve, e.g. when a
    ///         wallet linked to the creator is found trading. Only before the creator's share has vested.
    function slashCreator() external nonReentrant {
        if (msg.sender != _t.council) revert NotCouncil();
        if (creatorSlashed || creatorPaid) revert WrongState();
        if (resolvedAt != 0 && block.timestamp >= uint256(resolvedAt) + CREATOR_VEST) revert TooLate();
        creatorSlashed = true;
        uint256 fee = creatorEscrow;
        uint256 bond = bondHeld;
        creatorEscrow = 0;
        bondHeld = 0;
        if (fee != 0) _release(fee);
        if (fee + bond != 0) _t.token.safeTransfer(_t.insurance, fee + bond);
        emit CreatorSlashed(fee + bond);
    }

    // ── payouts ─────────────────────────────────────────────────────────────

    /// @notice Pay `msg.sender`'s winnings. Ungated: no eligibility pass needed.
    function claim() external nonReentrant returns (uint256 amount) {
        if (swept) revert AlreadySwept();
        amount = claimable(msg.sender);
        if (amount == 0) revert NothingToPay();
        claimed[msg.sender] = true;
        _release(amount);
        _t.token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice Refund `msg.sender`: everything on Void, late stakes on Final. Ungated.
    function refund() external nonReentrant returns (uint256 amount) {
        if (swept) revert AlreadySwept();
        amount = refundable(msg.sender);
        if (amount == 0) revert NothingToPay();
        refunded[msg.sender] = true;
        _release(amount);
        _t.token.safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    /// @notice Pay the creator their vested fee share and bond. Anyone may call; funds go to the creator.
    function payCreator() external nonReentrant {
        if (resolvedAt == 0 || swept) revert WrongState();
        if (block.timestamp < uint256(resolvedAt) + CREATOR_VEST) revert CreatorVesting();
        if (creatorSlashed || creatorPaid) revert WrongState();
        creatorPaid = true;
        uint256 fee = creatorEscrow;
        uint256 bond = bondHeld;
        creatorEscrow = 0;
        bondHeld = 0;
        if (fee != 0) _release(fee);
        if (fee + bond != 0) _t.token.safeTransfer(_t.creator, fee + bond);
        emit CreatorPaid(_t.creator, fee, bond);
    }

    /// @notice One year after resolution, send everything left to the treasury. Anyone may call.
    function sweep() external nonReentrant {
        if (resolvedAt == 0) revert WrongState();
        if (swept) revert AlreadySwept();
        if (block.timestamp < uint256(resolvedAt) + SWEEP_DELAY) revert TooEarly();
        swept = true;
        creatorEscrow = 0;
        bondHeld = 0;
        _release(openInterest);
        uint256 amount = _t.token.balanceOf(address(this));
        if (amount != 0) _t.token.safeTransfer(_t.treasury, amount);
        emit Swept(_t.treasury, amount);
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _stake(
        address payer,
        address user,
        uint8 outcome,
        uint256 amount,
        MarketTypes.EligibilityPass calldata pass,
        bytes calldata sig
    ) internal {
        if (state() != MarketTypes.State.Open) revert NotOpen();
        if (outcome == 0 || outcome > _t.outcomeCount) revert InvalidOutcome();
        if (amount < _t.minStake) revert BelowMinStake();
        if (isDenied[user]) revert Denied();
        IEligibilityGate(_t.eligibility).check(user, pass, sig);
        uint256 walletTotal = stakedBy[user] + amount;
        if (walletTotal > _t.perWalletCap) revert WalletCapExceeded();
        uint256 marketTotal = totalStaked + amount;
        if (marketTotal > _t.perMarketCap) revert MarketCapExceeded();

        stakedBy[user] = walletTotal;
        totalStaked = marketTotal;
        openInterest += amount;
        _push(_outcomeCk[outcome], amount);
        _push(_userCk[user][outcome], amount);

        IPredictionRegistry(_t.registry).onStake(amount);
        _t.token.safeTransferFrom(payer, address(this), amount);
        emit Staked(user, payer, outcome, amount);
    }

    function _settle(uint8 outcome) internal {
        resolvedAt = uint64(block.timestamp);
        decidedOutcome = outcome;
        if (outcome == MarketTypes.VOID) return _void();

        uint64 c = cutoff;
        uint256 counted;
        uint256 win;
        uint8 n = _t.outcomeCount;
        for (uint8 i = 1; i <= n; ++i) {
            uint256 v = _cumAt(_outcomeCk[i], c);
            counted += v;
            if (i == outcome) win = v;
        }
        // Nobody counted on the winning side: there is no one to pay, so everyone is refunded.
        if (win == 0) return _void();

        uint256 losing = counted - win;
        MarketTypes.RakeSplit memory r = _t.rake;
        uint256 toTreasury = losing * r.treasuryBps / BPS;
        uint256 toCreator = losing * r.creatorBps / BPS;
        uint256 toResolver = losing * r.resolverBps / BPS;
        uint256 toInsurance = losing * r.insuranceBps / BPS;
        uint256 rake = toTreasury + toCreator + toResolver + toInsurance;

        countedPool = counted;
        winningPool = win;
        distributable = losing - rake;
        finalOutcome = outcome;
        _state = MarketTypes.State.Final;
        emit Finalized(outcome, counted, win, rake);

        // A creator slashed before resolution forfeits the fee share straight to insurance.
        if (creatorSlashed) {
            toInsurance += toCreator;
        } else {
            creatorEscrow = toCreator;
        }
        uint256 paidOut = toTreasury + toResolver + toInsurance;
        if (paidOut != 0) _release(paidOut);
        if (toTreasury != 0) _t.token.safeTransfer(_t.treasury, toTreasury);
        if (toResolver != 0) _t.token.safeTransfer(_t.resolverBudget, toResolver);
        if (toInsurance != 0) _t.token.safeTransfer(_t.insurance, toInsurance);
        emit RakePaid(toTreasury, toResolver, toInsurance, creatorSlashed ? 0 : toCreator);
    }

    function _void() internal {
        _state = MarketTypes.State.Void;
        emit Voided(decidedOutcome, timedOut);
    }

    function _release(uint256 amount) internal {
        uint256 held = openInterest;
        if (amount > held) amount = held;
        if (amount == 0) return;
        openInterest = held - amount;
        IPredictionRegistry(_t.registry).onRelease(amount);
    }

    function _push(Checkpoint[] storage ck, uint256 amount) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint256 len = ck.length;
        if (len == 0) {
            ck.push(Checkpoint(nowTs, uint192(amount)));
            return;
        }
        Checkpoint storage last = ck[len - 1];
        uint192 cum = last.cum + uint192(amount);
        if (last.ts == nowTs) last.cum = cum;
        else ck.push(Checkpoint(nowTs, cum));
    }

    /// @dev Cumulative amount of the last checkpoint with ts <= `ts`, by binary search.
    function _cumAt(Checkpoint[] storage ck, uint64 ts) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = ck.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (ck[mid].ts > ts) hi = mid;
            else lo = mid + 1;
        }
        return lo == 0 ? 0 : ck[lo - 1].cum;
    }
}
