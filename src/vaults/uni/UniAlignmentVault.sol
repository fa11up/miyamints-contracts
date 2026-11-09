// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {CurrencySettler} from "../../libraries/v4/CurrencySettler.sol";
import {LiquidityAmounts} from "../../libraries/v4/LiquidityAmounts.sol";
import {IAlignmentVault, ClaimMode} from "../../interfaces/IAlignmentVault.sol";
import {IMiyaRegistry} from "../../registry/interfaces/IMiyaRegistry.sol";
import {IVaultConfig, SwapCall} from "./IVaultConfig.sol";
import {PendingLedger} from "./PendingLedger.sol";
import {VaultSwaps} from "./VaultSwaps.sol";

/**
 * @title UniAlignmentVault (v2: multi-token, aligned to the INFER/IMD pool)
 * @notice Collections send their vault share in the token paid (ETH or a registry-allowlisted ERC-20). The keeper converts
 *         a batch: any subset of the pending tokens, an exact amount of each, each through one aggregator call the keeper
 *         built (0x AllowanceHolder, or zRouter as the fallback) to an allowlisted target. A token swapped to ETH joins
 *         the batch's ETH, which then goes to IMD in ONE swap (the ETH leg), its output shared by each token's ETH; a
 *         token swapped to IMD (imdUSD) is valued by its own IMD out. The balanced part of the IMD goes to INFER in the
 *         hooked INFER/IMD pool (vault-side, through PoolManager.unlock), then INFER + IMD as one full-range position.
 *         Shares (= liquidity units) go to each token's benefactors in proportion to the IMD value the converted amount
 *         realized, pro rata to each benefactor's pending balance in it (PendingLedger). The position's INFER and IMD
 *         fees (1% to the protocol) are paid to shares, as tokens, as ETH, or reinvested. Shares are never redeemable
 *         for liquidity. Spec: docs/IMD-INFER-VAULT.md.
 * @dev Clone (EIP-1167), initialized once by the factory, which owns it. Keeps v1's hardening:
 *      - conversions cost O(tokens) whatever the number of contributors; each benefactor collects its shares lazily;
 *      - per-share fee indexes with checkpoints (each payout rounds down once), fees booked before every share change;
 *      - conversions are keeper-only (registry.conversionKeeper) with the keeper's floors as the price protection; each
 *        swap is guarded in VaultSwaps (allowlisted target, exact approval reset after, input drops by exactly the
 *        amount in, output rises by at least a non-zero floor);
 *      - the keeper reward comes out of the batch's ETH only (0.0012 ETH, capped at 1% of it);
 *      - receive() ignores ETH the vault pulls in itself (transient flag), everything nonReentrant;
 *      - nothing owed is ever spent: conversions work only from balances beyond what is owed, checked at the end.
 */
contract UniAlignmentVault is ReentrancyGuard, Ownable, IUnlockCallback, IAlignmentVault {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    // ========== Errors ==========

    error InvalidAddress();
    error TargetNotActive();
    error TokenNotInTarget();
    error InvalidPoolKey();
    error AmountMustBePositive();
    error AmountMismatch();
    error ContributionBelowMinimum();
    error TokenNotAllowed(address token);
    error SwapTargetNotAllowed(address target);
    error BadSwapOutput();
    error InputMismatch();
    error TooManyTokens();
    error ReceivedLess();
    error NothingPending();
    error BadParams();
    error Expired();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error PoolNotInitialized();
    error NoShares();
    error NoFeesToClaim();
    error ZeroFloor();
    error NotBenefactor();
    error NotDelegate();
    error TreasuryNotSet();
    error TransferFailed();
    error NotKeeper();
    error Insolvent(address token);
    error UnknownFeeToken();

    // ========== Constants ==========

    address internal constant ETH = address(0);
    /// @notice Least ETH a contribution can carry. ERC-20 minimums are per token in the factory (minContribution).
    uint256 public constant MIN_CONTRIBUTION = 0.001 ether;
    /// @notice Most distinct tokens one batch (and one benefactor's pending batch) can hold.
    uint256 public constant MAX_BATCH_TOKENS = 16;
    /// @notice Flat keeper reward, paid from the batch's pending ETH only, capped at MAX_CONVERSION_REWARD_BPS of it.
    uint256 public constant CONVERSION_REWARD = 0.0012 ether;
    uint256 public constant MAX_CONVERSION_REWARD_BPS = 100;
    uint256 public constant PROTOCOL_YIELD_CUT_BPS = 100;
    uint256 public constant FEE_COLLECTION_INTERVAL = 1 days;

    uint256 internal constant ACC_PRECISION = 1e36;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant MAX_LP_PASSES = 3;
    uint256 private constant LP_PASS_MIN_DIVISOR = 200; // a later pass needs 0.5% of the starting excess to swap

    /// @dev Fee token slots: the position earns INFER and IMD; ETH is dust (rejected rewards, router refunds, strays).
    uint256 internal constant I_INFER = 0;
    uint256 internal constant I_IMD = 1;
    uint256 internal constant I_ETH = 2;

    uint8 private constant ACTION_MODIFY = 1;
    uint8 private constant ACTION_SWAP = 2;

    /// @dev Set while the vault pulls ETH in itself (swap outputs and refunds), so receive() does not book it as a
    ///      contribution. = keccak256("miyamaker.UniAlignmentVault.collecting")
    uint256 private constant _COLLECTING_SLOT = 0x9fffd68a8e82dadd8810fe84758545b0fb4c40f84b514ef129e417c2e244d1a1;

    // ========== Config (set once at initialize) ==========

    IPoolManager public poolManager;
    address public zRouter;
    IMiyaRegistry public registry;
    /// @notice Swap targets, ERC-20 minimums and the ETH-claim pool, read live (the factory).
    IVaultConfig public config;
    address public infer;
    address public imd;
    uint256 public alignmentTargetId;
    PoolKey internal _poolKey;
    bool internal _inferIsCurrency0;
    int24 public tickLower;
    int24 public tickUpper;
    bool private _initialized;

    // ========== Shares and fees ==========

    uint256 public totalShares;
    uint256 public totalLPUnits;
    uint256 public totalUniqueBenefactors;
    uint256 public lastFeeCollectionTime;

    /// @dev Per fee token (I_INFER, I_IMD, I_ETH). A benefactor is owed, per token,
    ///      settled + shares * (accPerShare - checkpoint) / ACC_PRECISION; held owed = distributed - claimed + protocol.
    uint256[3] internal _accPerShare;
    uint256[3] internal _distributed;
    uint256[3] internal _claimed;
    uint256[3] internal _protocolFees;

    mapping(address => uint256) internal _shares;
    mapping(address => uint256[3]) internal _checkpoint;
    mapping(address => uint256[3]) internal _settled;
    mapping(address => address) public benefactorDelegate;
    mapping(address => bool) public isBenefactor;
    /// @notice Lifetime contributions per benefactor per token (bragging rights; never decreases).
    mapping(address => mapping(address => uint256)) public contributionOf;

    // ========== Pending contributions ==========
    // Per token, a pro-rata pool (PendingLedger): a conversion of part of a token's pending converts that fraction of
    // every benefactor's balance in it and records the shares it made; each benefactor collects its shares (and the
    // fees they earned since) the next time it is touched.

    /// @notice Conversions so far (each convertAndAddLiquidity call is one batch).
    uint256 public closedBatches;
    address[] internal _openTokens;
    /// @notice Pending (not yet converted) contributions per token.
    mapping(address => uint256) public pendingByToken;
    mapping(address => PendingLedger.Pool) internal _pools;
    mapping(address => mapping(address => PendingLedger.Record)) internal _records;
    /// @dev The tokens a benefactor has a record in (pending, or converted and not yet collected).
    mapping(address => address[]) internal _benefactorTokens;

    // ========== Keeper call ==========

    /// @param tokens Which pending tokens to convert: any non-empty subset of openBatchTokens(), any order, no
    ///        duplicates. Tokens left out stay pending, their benefactors' balances untouched.
    /// @param amounts Per token, exactly how much to convert: 0 < amount <= pendingByToken(token). What arrives after
    ///        the keeper read it stays pending for a later batch. Each benefactor's balance converts pro rata.
    /// @param swaps One per token (same order): exactly `amounts[i]` of the token to ETH or IMD (SwapCall). Ignored
    ///        (may be empty) for ETH, IMD and INFER.
    /// @param ethLeg The batch's one ETH -> IMD swap (tokenOut IMD), sent all the batch's ETH as value: pending ETH net
    ///        of the keeper reward, plus every swap that output ETH. Required when any ETH reaches it, else ignored.
    ///        Build it to sell its whole msg.value (zRouter: swapAmount 0); ETH it hands back is dust for holders.
    /// @param minSplitOut Floor on the INFER/IMD balancing swap's total output (non-zero if a swap happens).
    /// @param deadline Last timestamp the call may land.
    struct ConvertParams {
        address[] tokens;
        uint256[] amounts;
        SwapCall[] swaps;
        SwapCall ethLeg;
        uint256 minSplitOut;
        uint256 deadline;
    }

    // ========== Events ==========

    event BatchConverted(
        uint256 indexed batchId, uint256 sharesIssued, uint256 inferAdded, uint256 imdAdded, uint256 callerReward
    );
    event TokenConverted(uint256 indexed batchId, address indexed token, uint256 amountIn, uint256 imdValue);
    /// @notice The batch's one ETH -> IMD swap: all its ETH in, the IMD out shared by each token's ETH.
    event EthLegSwapped(uint256 indexed batchId, uint256 ethIn, uint256 imdOut);
    event SplitSwap(bool inferToImd, uint256 amountIn, uint256 amountOut);
    event Reinvested(address indexed benefactor, uint256 inferIn, uint256 imdIn, uint256 sharesIssued);
    event ConversionRewardPaid(address indexed caller, uint256 reward);
    event ConversionRewardRejected(address indexed caller, uint256 rewardAmount);
    event ProtocolYieldCollected(address indexed token, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed token, uint256 amount);
    event BenefactorDelegateSet(address indexed benefactor, address indexed delegate);

    modifier onlyKeeper() {
        if (msg.sender != registry.conversionKeeper()) revert NotKeeper();
        _;
    }

    // ========== Initialize ==========

    /// @notice Spends this contract's one initialization, so the implementation behind the clones can't be claimed.
    function disableInitializer() external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
    }

    /// @param key_ The INFER/IMD pool. Its hook may only have initialize permissions (no swap, liquidity or delta
    ///        hooks), and its fee must be static.
    function initialize(
        address owner_,
        IPoolManager poolManager_,
        address zRouter_,
        IMiyaRegistry registry_,
        IVaultConfig config_,
        address infer_,
        address imd_,
        PoolKey calldata key_,
        uint256 alignmentTargetId_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _initializeOwner(owner_);

        if (
            address(poolManager_) == address(0) || zRouter_ == address(0) || address(registry_) == address(0)
                || address(config_) == address(0) || infer_ == address(0) || imd_ == address(0) || infer_ == imd_
        ) revert InvalidAddress();
        if (!registry_.isAlignmentTargetActive(alignmentTargetId_)) revert TargetNotActive();
        if (!registry_.isTokenInTarget(alignmentTargetId_, infer_)) revert TokenNotInTarget();
        _validatePoolKey(key_, infer_, imd_);

        poolManager = poolManager_;
        zRouter = zRouter_;
        registry = registry_;
        config = config_;
        infer = infer_;
        imd = imd_;
        alignmentTargetId = alignmentTargetId_;
        _poolKey = key_;
        _inferIsCurrency0 = Currency.unwrap(key_.currency0) == infer_;
        tickLower = TickMath.minUsableTick(key_.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key_.tickSpacing);
    }

    function _validatePoolKey(PoolKey calldata key, address infer_, address imd_) internal pure {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool pair = (c0 == infer_ && c1 == imd_) || (c0 == imd_ && c1 == infer_);
        if (!pair || c0 >= c1) revert InvalidPoolKey();
        if (key.fee >= 1_000_000 || key.tickSpacing <= 0) revert InvalidPoolKey(); // static fee only
        // A hook that can act on swaps or liquidity could reprice, block or take a cut of every vault operation.
        uint160 perms = uint160(address(key.hooks)) & Hooks.ALL_HOOK_MASK;
        if (perms & ~(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG) != 0) revert InvalidPoolKey();
    }

    // ========== Contributions ==========

    receive() external payable override {
        if (_isCollecting()) return;
        _receiveDirect();
    }

    function _receiveDirect() private nonReentrant {
        if (msg.value == 0) revert AmountMustBePositive();
        _book(msg.sender, ETH, msg.value);
    }

    /// @inheritdoc IAlignmentVault
    function receiveContribution(Currency currency, uint256 amount, address benefactor)
        external
        payable
        override
        nonReentrant
    {
        if (amount == 0) revert AmountMustBePositive();
        if (benefactor == address(0)) revert InvalidAddress();
        address token = Currency.unwrap(currency);
        if (token == ETH) {
            if (msg.value != amount) revert AmountMismatch();
        } else {
            if (msg.value != 0) revert AmountMismatch();
            if (!registry.isPaymentToken(token)) revert TokenNotAllowed(token);
            if (amount < config.minContribution(token)) revert ContributionBelowMinimum();
            uint256 before = SafeTransferLib.balanceOf(token, address(this));
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
            if (SafeTransferLib.balanceOf(token, address(this)) - before != amount) revert ReceivedLess();
        }
        _book(benefactor, token, amount);
    }

    function _book(address benefactor, address token, uint256 amount) internal {
        if (token == ETH && amount < MIN_CONTRIBUTION) revert ContributionBelowMinimum();
        _settle(benefactor); // collects what was converted first, so every record is current
        PendingLedger.Record storage r = _records[benefactor][token];
        if (r.amount == 0) {
            if (_benefactorTokens[benefactor].length >= MAX_BATCH_TOKENS) revert TooManyTokens();
            _benefactorTokens[benefactor].push(token);
        }
        PendingLedger.add(_pools[token], r, amount);
        if (pendingByToken[token] == 0) {
            if (_openTokens.length >= MAX_BATCH_TOKENS) revert TooManyTokens();
            _openTokens.push(token);
        }
        pendingByToken[token] += amount;
        if (!isBenefactor[benefactor]) {
            isBenefactor[benefactor] = true;
            ++totalUniqueBenefactors;
        }
        contributionOf[benefactor][token] += amount;
        emit ContributionReceived(benefactor, token, amount);
    }

    // ========== Conversion ==========

    /// @notice Convert part of what is pending into INFER/IMD liquidity and issue its shares. Keeper only.
    /// @dev The keeper quotes every swap (0x, zRouter fallback), simulates, and sends through a private mempool: its
    ///      floors are the only price protection (no on-chain reference exists for these pools). Order independent as
    ///      long as no two tokens' swaps share a pool: every token's ETH meets in one ETH -> IMD swap, so permuting
    ///      `tokens` changes nothing.
    // slither-disable-next-line reentrancy-benign,reentrancy-eth
    function convertAndAddLiquidity(ConvertParams calldata p)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 sharesIssued)
    {
        if (block.timestamp > p.deadline) revert Expired();
        if (_openTokens.length == 0) revert NothingPending();
        uint256 n = p.tokens.length;
        if (n == 0 || p.amounts.length != n || p.swaps.length != n) revert BadParams();

        // Yield earned so far belongs to current holders: book it before any share change.
        _collectFees();

        // Before this batch: INFER/IMD already free (earlier leftovers, strays) and the units the position holds. The
        // balancing below adds the leftovers too, but the batch gets shares only for its own value (_batchShares).
        uint256[3] memory before;
        (before[0], before[1]) = _freeAlignmentBalances();
        before[2] = totalLPUnits;

        // Take the converted amounts out of pending first, so the balancing below sees only what is free.
        (uint256[] memory pendingBefore, uint256 reward) = _takePending(p);
        (uint256[] memory values, uint256 inferSlot) = _toImd(p, reward);

        (uint256 liquidity, uint256 inferAdded, uint256 imdAdded, uint256 rateImd, uint256 rateInfer) =
            _balanceAndAdd(p.minSplitOut);
        if (liquidity == 0) revert InsufficientLiquidity();
        if (inferSlot != type(uint256).max) {
            values[inferSlot] = FixedPointMathLib.fullMulDiv(p.amounts[inferSlot], rateImd, rateInfer);
        }

        // ETH beyond what is owed (router refunds, strays) is dust for current holders, before the new shares.
        uint256 ethOwed = _feeOwed(I_ETH) + pendingByToken[ETH] + reward;
        if (address(this).balance > ethOwed) _distribute(I_ETH, address(this).balance - ethOwed);

        sharesIssued = _batchShares(liquidity, values, before, rateImd, rateInfer);
        if (sharesIssued == 0) revert InsufficientLiquidity();
        _closeBatch(p, sharesIssued, values, pendingBefore);
        emit BatchConverted(closedBatches, sharesIssued, inferAdded, imdAdded, reward);
        _payCallerReward(reward);
        _checkSolvent();
        // Every other token still pending is still held: no swap reached what is owed to others.
        for (uint256 k; k < _openTokens.length; ++k) {
            address t = _openTokens[k];
            if (_balanceOf(t) < pendingByToken[t]) revert Insolvent(t);
        }
    }

    /// @dev Check the listed tokens and amounts and take the amounts out of pending. Returns what was pending before,
    ///      per token, and the keeper reward (from the ETH converted, if any).
    function _takePending(ConvertParams calldata p)
        private
        returns (uint256[] memory pendingBefore, uint256 reward)
    {
        uint256 n = p.tokens.length;
        pendingBefore = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address t = p.tokens[i];
            uint256 amt = p.amounts[i];
            for (uint256 j; j < i; ++j) {
                if (p.tokens[j] == t) revert BadParams();
            }
            uint256 pend = pendingByToken[t];
            if (amt == 0 || amt > pend) revert BadParams();
            pendingBefore[i] = pend;
            pendingByToken[t] = pend - amt;
            if (t == ETH) reward = _conversionReward(amt);
        }
    }

    /// @dev Each listed token to IMD, or to ETH for the batch's one ETH -> IMD swap, whose output is shared by each
    ///      token's ETH in. Returns the IMD each token realized (INFER's is filled in after the split).
    function _toImd(ConvertParams calldata p, uint256 reward)
        private
        returns (uint256[] memory values, uint256 inferSlot)
    {
        uint256 n = p.tokens.length;
        values = new uint256[](n);
        uint256[] memory ethIn = new uint256[](n);
        uint256 ethTotal;
        inferSlot = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            address t = p.tokens[i];
            if (t == imd) {
                values[i] = p.amounts[i];
            } else if (t == infer) {
                inferSlot = i;
            } else if (t == ETH) {
                ethIn[i] = p.amounts[i] - reward;
            } else {
                SwapCall calldata s = p.swaps[i];
                uint256 out = VaultSwaps.swap(config, s, t, p.amounts[i], imd, false);
                if (s.tokenOut == ETH) ethIn[i] = out;
                else values[i] = out;
            }
            ethTotal += ethIn[i];
        }
        if (ethTotal != 0) {
            uint256 imdOut = VaultSwaps.swap(config, p.ethLeg, ETH, ethTotal, imd, true);
            emit EthLegSwapped(closedBatches + 1, ethTotal, imdOut);
            for (uint256 i; i < n; ++i) {
                if (ethIn[i] != 0) values[i] = FixedPointMathLib.fullMulDiv(imdOut, ethIn[i], ethTotal); // round down
            }
        }
    }

    /// @dev Caller reward for a batch converting `ethAmount` wei of pending ETH.
    function _conversionReward(uint256 ethAmount) internal pure returns (uint256) {
        uint256 cap = (ethAmount * MAX_CONVERSION_REWARD_BPS) / 10000; // round down: favors benefactors
        return cap < CONVERSION_REWARD ? cap : CONVERSION_REWARD;
    }

    function _splitAmount(uint256 amtInfer, uint256 amtImd, uint160 sqrtP, uint128 poolL)
        internal
        view
        returns (bool, uint256, uint256)
    {
        return VaultSwaps.splitAmount(amtInfer, amtImd, sqrtP, poolL, _inferIsCurrency0, _poolKey.fee);
    }

    /// @dev Balance the free INFER and IMD (everything held beyond fees owed: this batch's IMD and INFER plus earlier
    ///      leftovers) with vault-side swaps in the alignment pool, and add them full range. Swap, add, measure what is
    ///      left and go again, up to MAX_LP_PASSES, always in the first pass's direction. Returns the liquidity added and
    ///      the realized IMD-per-INFER rate as (rateImd / rateInfer): the balancing swap's, else the pool price.
    function _balanceAndAdd(uint256 minSplitOut)
        internal
        returns (uint256 liquidity, uint256 inferAdded, uint256 imdAdded, uint256 rateImd, uint256 rateInfer)
    {
        (uint160 sqrtP, uint128 poolL) = _poolState();
        if (sqrtP == 0) revert PoolNotInitialized();
        uint160 sqrtP0 = sqrtP;

        uint256 swapIn;
        uint256 swapOut;
        uint256 startExcess;
        bool dirSet;
        bool inferToImd;
        for (uint256 pass; pass < MAX_LP_PASSES; ++pass) {
            (uint256 freeInfer, uint256 freeImd) = _freeAlignmentBalances();
            (bool z, uint256 s, uint256 excess) = _splitAmount(freeInfer, freeImd, sqrtP, poolL);
            if (pass == 0) startExcess = excess;
            if (pass != 0 && (s == 0 || z != inferToImd || s < startExcess / LP_PASS_MIN_DIVISOR)) break;
            if (s != 0) {
                if (!dirSet) (dirSet, inferToImd) = (true, z);
                uint256 out = _alignSwap(z, s);
                swapIn += s;
                swapOut += out;
                (freeInfer, freeImd) = _freeAlignmentBalances();
            }
            (uint256 l, uint256 u0, uint256 u1) = _addLiquidity(freeInfer, freeImd);
            if (l == 0) break;
            liquidity += l;
            inferAdded += u0;
            imdAdded += u1;
            (sqrtP, poolL) = _poolState();
        }
        if (swapIn != 0) {
            if (minSplitOut == 0) revert ZeroFloor();
            if (swapOut < minSplitOut) revert InsufficientOutput();
            emit SplitSwap(inferToImd, swapIn, swapOut);
        }
        if (swapIn != 0 && swapOut != 0) {
            (rateImd, rateInfer) = inferToImd ? (swapOut, swapIn) : (swapIn, swapOut);
        } else {
            // No balancing swap: value INFER at the pool price at the start of the conversion (IMD per INFER).
            (rateImd, rateInfer) = _inferIsCurrency0
                ? (FixedPointMathLib.fullMulDiv(sqrtP0, sqrtP0, Q96), Q96)
                : (Q96, FixedPointMathLib.fullMulDiv(sqrtP0, sqrtP0, Q96));
            if (rateImd == 0 || rateInfer == 0) revert PoolNotInitialized();
        }
    }

    /// @dev INFER and IMD held beyond fees owed and beyond what is still pending (a conversion takes its amounts out of
    ///      pending before it balances, so this batch's INFER and IMD are free, the rest stays put).
    function _freeAlignmentBalances() internal view returns (uint256 freeInfer, uint256 freeImd) {
        freeInfer = _free(infer, I_INFER);
        freeImd = _free(imd, I_IMD);
    }

    function _free(address token, uint256 i) private view returns (uint256) {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        uint256 owed = _feeOwed(i) + pendingByToken[token];
        return bal > owed ? bal - owed : 0;
    }

    /// @dev Swap exactly `amountIn` of INFER (inferToImd) or IMD in the alignment pool; returns the output.
    function _alignSwap(bool inferToImd, uint256 amountIn) internal returns (uint256) {
        return _poolSwap(inferToImd == _inferIsCurrency0, amountIn);
    }

    /// @dev Add `amtInfer` / `amtImd` full range (what fits); returns liquidity and what it used of each.
    function _addLiquidity(uint256 amtInfer, uint256 amtImd)
        internal
        returns (uint256 liquidity, uint256 usedInfer, uint256 usedImd)
    {
        if (amtInfer == 0 || amtImd == 0) return (0, 0, 0);
        (uint160 sqrtP,) = _poolState();
        (uint256 a0, uint256 a1) = _inferIsCurrency0 ? (amtInfer, amtImd) : (amtImd, amtInfer);
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), a0, a1
        );
        if (l == 0) return (0, 0, 0);
        (uint256 used0, uint256 used1) = _modifyPosition(int256(uint256(l)));
        totalLPUnits += l;
        liquidity = l;
        (usedInfer, usedImd) = _inferIsCurrency0 ? (used0, used1) : (used1, used0);
    }

    /// @dev Modify the vault's single full-range position and book the fees it accrued (always to current holders:
    ///      every caller changes shares only after this). Returns the principal paid in per currency.
    function _modifyPosition(int256 liquidityDelta) internal returns (uint256 used0, uint256 used1) {
        uint256 fees0;
        uint256 fees1;
        (used0, used1, fees0, fees1) = _poolModify(liquidityDelta);
        (uint256 fInfer, uint256 fImd) = _inferIsCurrency0 ? (fees0, fees1) : (fees1, fees0);
        _creditYield(I_INFER, fInfer);
        _creditYield(I_IMD, fImd);
    }

    /// @dev Split the batch's liquidity across its tokens by realized IMD value; each token's pool pays its part to that
    ///      token's benefactors pro rata (PendingLedger.convert), from the fee indexes as they stand now.
    /// @dev Shares for this batch: the part of `liquidity` its own value paid for (the rest came from leftovers and
    ///      strays, and lifts the shares of holders before this batch), priced at the share price once that rest is in.
    function _batchShares(
        uint256 liquidity,
        uint256[] memory values,
        uint256[3] memory before,
        uint256 rateImd,
        uint256 rateInfer
    ) private view returns (uint256) {
        if (totalShares == 0) return liquidity; // nobody else to own the leftovers
        uint256 own;
        for (uint256 i; i < values.length; ++i) own += values[i];
        uint256 left = before[1] + FixedPointMathLib.fullMulDiv(before[0], rateImd, rateInfer);
        uint256 ownLiquidity = left == 0 ? liquidity : FixedPointMathLib.fullMulDiv(liquidity, own, own + left);
        // Price after the leftover's liquidity is in: holders before this batch keep all of it.
        return _sharesFor(ownLiquidity, before[2] + (liquidity - ownLiquidity));
    }

    /// @dev Shares worth `liquidity` units at the current share price (totalShares / units before the add). The first
    ///      holders get one share per unit.
    function _sharesFor(uint256 liquidity, uint256 unitsBefore) private view returns (uint256) {
        if (totalShares == 0 || unitsBefore == 0) return liquidity;
        return FixedPointMathLib.fullMulDiv(liquidity, totalShares, unitsBefore); // round down
    }

    function _closeBatch(ConvertParams calldata p, uint256 liquidity, uint256[] memory values, uint256[] memory pendingBefore)
        private
    {
        uint256 batchId = closedBatches + 1;
        uint256 totalValue;
        uint256 n = values.length;
        for (uint256 i; i < n; ++i) totalValue += values[i];
        if (totalValue == 0) revert InsufficientOutput();
        uint256[3] memory acc = _accPerShare; // new shares earn from here
        for (uint256 i; i < n; ++i) {
            address t = p.tokens[i];
            uint256 tokenShares = FixedPointMathLib.fullMulDiv(liquidity, values[i], totalValue); // round down
            PendingLedger.convert(_pools[t], pendingBefore[i], p.amounts[i], tokenShares, acc);
            emit TokenConverted(batchId, t, p.amounts[i], values[i]);
            if (pendingByToken[t] == 0) _removeOpenToken(t);
        }
        closedBatches = batchId;
        totalShares += liquidity;
    }

    function _removeOpenToken(address t) private {
        uint256 last = _openTokens.length - 1;
        for (uint256 k; k <= last; ++k) {
            if (_openTokens[k] == t) {
                _openTokens[k] = _openTokens[last];
                _openTokens.pop();
                return;
            }
        }
    }

    // slither-disable-next-line arbitrary-send-eth
    function _payCallerReward(uint256 reward) private {
        if (reward == 0) return;
        (bool ok,) = payable(msg.sender).call{value: reward}("");
        if (ok) {
            emit ConversionRewardPaid(msg.sender, reward);
        } else {
            _distribute(I_ETH, reward);
            emit ConversionRewardRejected(msg.sender, reward);
        }
    }

    // ========== Fee accounting ==========

    /// @notice Collect the position's fees now (no swap; anyone).
    function collectFees() external nonReentrant {
        _collectFees();
    }

    function _collectFees() internal {
        if (totalLPUnits == 0) return;
        _modifyPosition(0);
        lastFeeCollectionTime = block.timestamp;
    }

    // slither-disable-next-line timestamp
    function _maybeCollectFees() internal {
        if (block.timestamp >= lastFeeCollectionTime + FEE_COLLECTION_INTERVAL) _collectFees();
    }

    /// @dev Protocol cut, the rest pro rata to current shareholders.
    function _creditYield(uint256 i, uint256 amount) internal {
        if (amount == 0) return;
        uint256 cut = (amount * PROTOCOL_YIELD_CUT_BPS) / 10000; // round down: favors benefactors
        if (cut != 0) {
            _protocolFees[i] += cut;
            emit ProtocolYieldCollected(_feeToken(i), cut);
        }
        _distribute(i, amount - cut);
    }

    function _distribute(uint256 i, uint256 amount) internal {
        if (amount == 0) return;
        if (totalShares == 0) {
            // Nobody to credit (only before the first conversion closes): keep it accounted.
            _protocolFees[i] += amount;
            emit ProtocolYieldCollected(_feeToken(i), amount);
            return;
        }
        _accPerShare[i] += FixedPointMathLib.fullMulDiv(amount, ACC_PRECISION, totalShares); // round down
        _distributed[i] += amount;
        emit FeesAccumulated(_feeToken(i), amount);
    }

    function _feeOwed(uint256 i) internal view returns (uint256) {
        return _distributed[i] - _claimed[i] + _protocolFees[i];
    }

    function _feeToken(uint256 i) internal view returns (address) {
        return i == I_INFER ? infer : i == I_IMD ? imd : ETH;
    }

    function _feeIndex(address token) internal view returns (uint256) {
        if (token == infer) return I_INFER;
        if (token == imd) return I_IMD;
        if (token == ETH) return I_ETH;
        revert UnknownFeeToken();
    }

    /// @dev A benefactor's shares and the fees owed since its checkpoint, as if everything converted were collected:
    ///      its collected shares times the index growth since the checkpoint, plus, per token record, the shares the
    ///      conversions since its snapshot made for it and what those earned since each conversion.
    function _owedSinceCheckpoint(address b) internal view returns (uint256 shares, uint256[3] memory owed) {
        shares = _shares[b];
        uint256[3] memory acc = _accPerShare;
        uint256[3] storage cp = _checkpoint[b];
        for (uint256 i; i < 3; ++i) owed[i] = FixedPointMathLib.fullMulDiv(shares, acc[i] - cp[i], ACC_PRECISION);
        address[] storage toks = _benefactorTokens[b];
        for (uint256 k; k < toks.length; ++k) {
            address t = toks[k];
            (uint256 s, uint256[3] memory f,) = PendingLedger.accrued(_pools[t], _records[b][t], acc);
            shares += s;
            for (uint256 i; i < 3; ++i) owed[i] += f[i];
        }
    }

    /// @dev Collect what was converted for `b` and move fees earned so far into settled.
    function _settle(address b) internal {
        uint256 shares = _shares[b];
        uint256[3] memory acc = _accPerShare;
        uint256[3] memory owed;
        uint256[3] storage cp = _checkpoint[b];
        for (uint256 i; i < 3; ++i) owed[i] = FixedPointMathLib.fullMulDiv(shares, acc[i] - cp[i], ACC_PRECISION);
        address[] storage toks = _benefactorTokens[b];
        for (uint256 k = toks.length; k != 0;) {
            address t = toks[--k];
            (uint256 s, uint256[3] memory f, uint256 left) = PendingLedger.settle(_pools[t], _records[b][t], acc);
            shares += s;
            for (uint256 i; i < 3; ++i) owed[i] += f[i];
            if (left == 0) {
                toks[k] = toks[toks.length - 1];
                toks.pop();
            }
        }
        _shares[b] = shares;
        for (uint256 i; i < 3; ++i) {
            if (owed[i] != 0) _settled[b][i] += owed[i];
            cp[i] = acc[i];
        }
    }

    function _harvest(address b) internal returns (uint256[3] memory amounts) {
        _settle(b);
        for (uint256 i; i < 3; ++i) {
            uint256 a = _settled[b][i];
            if (a != 0) {
                _settled[b][i] = 0;
                _claimed[i] += a;
                amounts[i] = a;
            }
        }
    }

    /// @dev Credit back what a reinvest could not use. Up to what was harvested in that token it un-claims; beyond that
    ///      (the balancing swap's output in the other token) it is held and newly owed, so it counts as distributed.
    function _unharvest(address b, uint256 i, uint256 amount, uint256 harvested) internal {
        if (amount == 0) return;
        _settled[b][i] += amount;
        uint256 back = amount < harvested ? amount : harvested;
        _claimed[i] -= back;
        _distributed[i] += amount - back;
    }

    // ========== Claims ==========

    /// @inheritdoc IAlignmentVault
    // slither-disable-next-line reentrancy-benign
    function claimFees(ClaimMode mode, uint256 minEthOut)
        external
        override
        nonReentrant
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        address b = msg.sender;
        if (benefactorShares(b) == 0) revert NoShares();
        if (mode == ClaimMode.REINVEST) return _reinvest(b, minEthOut);
        _maybeCollectFees();
        uint256[3] memory a = _harvest(b);
        if (a[0] == 0 && a[1] == 0 && a[2] == 0) revert NoFeesToClaim();
        address to = benefactorDelegate[b];
        if (to == address(0)) to = b;
        (inferOut, imdOut, ethOut) = _payout(to, a, mode, minEthOut);
        emit FeesClaimed(b, mode, inferOut, imdOut, ethOut);
        _checkSolvent();
    }

    /// @inheritdoc IAlignmentVault
    // slither-disable-next-line reentrancy-benign
    function claimFeesAsDelegate(address[] calldata benefactors, ClaimMode mode, uint256 minEthOut)
        external
        override
        nonReentrant
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        if (mode == ClaimMode.REINVEST) revert BadParams();
        _maybeCollectFees();
        uint256[3] memory total;
        for (uint256 k; k < benefactors.length; ++k) {
            address b = benefactors[k];
            if (benefactorDelegate[b] != msg.sender) revert NotDelegate();
            if (benefactorShares(b) == 0) revert NoShares();
            uint256[3] memory a = _harvest(b);
            emit FeesClaimed(b, mode, a[0], a[1], a[2]);
            for (uint256 i; i < 3; ++i) total[i] += a[i];
        }
        if (total[0] == 0 && total[1] == 0 && total[2] == 0) revert NoFeesToClaim();
        (inferOut, imdOut, ethOut) = _payout(msg.sender, total, mode, minEthOut);
        _checkSolvent();
    }

    // slither-disable-next-line arbitrary-send-eth
    function _payout(address to, uint256[3] memory a, ClaimMode mode, uint256 minEthOut)
        internal
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        if (mode == ClaimMode.TOKENS) {
            (inferOut, imdOut, ethOut) = (a[0], a[1], a[2]);
            if (inferOut != 0) SafeTransferLib.safeTransfer(infer, to, inferOut);
            if (imdOut != 0) SafeTransferLib.safeTransfer(imd, to, imdOut);
        } else {
            // ETH: INFER -> IMD in the alignment pool (vault-side), IMD -> ETH in the factory's IMD/ETH pool (zRouter).
            if (minEthOut == 0) revert ZeroFloor();
            uint256 imdTotal = a[1];
            if (a[0] != 0) imdTotal += _alignSwap(true, a[0]);
            ethOut = a[2];
            if (imdTotal != 0) {
                ethOut += VaultSwaps.imdToEth(zRouter, config, imd, imdTotal, minEthOut > ethOut ? minEthOut - ethOut : 1);
            }
            if (ethOut < minEthOut) revert InsufficientOutput();
        }
        if (ethOut != 0) {
            (bool ok,) = payable(to).call{value: ethOut}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @dev Put the caller's INFER + IMD fees back into the position as new shares at the current share price
    ///      (totalShares / totalLPUnits before the add). Balances the two first with a vault-side swap. What the add can't use, and
    ///      any ETH dust, stays claimable.
    function _reinvest(address b, uint256 minShares)
        internal
        returns (uint256 inferIn, uint256 imdIn, uint256 ethOut)
    {
        _collectFees(); // a share change: book the yield first
        uint256[3] memory a = _harvest(b);
        if (a[0] == 0 && a[1] == 0) revert NoFeesToClaim();
        _unharvest(b, I_ETH, a[2], a[2]);

        (uint256 amtInfer, uint256 amtImd) = (a[0], a[1]);
        uint256 unitsBefore = totalLPUnits;
        (uint160 sqrtP, uint128 poolL) = _poolState();
        if (sqrtP == 0) revert PoolNotInitialized();
        (bool inferToImd, uint256 s,) = _splitAmount(amtInfer, amtImd, sqrtP, poolL);
        if (s != 0) {
            uint256 out = _alignSwap(inferToImd, s);
            emit SplitSwap(inferToImd, s, out);
            (amtInfer, amtImd) = inferToImd ? (amtInfer - s, amtImd + out) : (amtInfer + out, amtImd - s);
        }
        (uint256 l, uint256 usedInfer, uint256 usedImd) = _addLiquidity(amtInfer, amtImd);
        if (l == 0) revert InsufficientLiquidity();
        l = _sharesFor(l, unitsBefore); // shares, at the share price before the add
        if (l == 0) revert InsufficientLiquidity();
        if (l < minShares) revert InsufficientOutput();
        // The add booked the position's fees to current holders, b's existing shares included: settle before minting.
        _settle(b);
        _unharvest(b, I_INFER, amtInfer - usedInfer, a[0]);
        _unharvest(b, I_IMD, amtImd - usedImd, a[1]);
        _shares[b] += l;
        totalShares += l;
        emit Reinvested(b, usedInfer, usedImd, l);
        emit FeesClaimed(b, ClaimMode.REINVEST, usedInfer, usedImd, 0);
        _checkSolvent();
        return (usedInfer, usedImd, 0);
    }

    // ========== Protocol cut ==========

    /// @notice Send the protocol's accumulated cut in `token` (INFER, IMD or address(0) for ETH) to the registry treasury.
    // slither-disable-next-line arbitrary-send-eth,reentrancy-events
    function withdrawProtocolFees(address token) external nonReentrant {
        uint256 i = _feeIndex(token);
        address treasury = registry.treasury();
        if (treasury == address(0)) revert TreasuryNotSet();
        uint256 amount = _protocolFees[i];
        if (amount == 0) revert NoFeesToClaim();
        _protocolFees[i] = 0;
        if (token == ETH) {
            (bool ok,) = payable(treasury).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, treasury, amount);
        }
        emit ProtocolFeesWithdrawn(token, amount);
    }

    // ========== Solvency ==========

    /// @dev Everything owed in INFER, IMD and ETH (fees, protocol cut, pending contributions) is held.
    function _checkSolvent() internal view {
        for (uint256 i; i < 3; ++i) {
            address t = _feeToken(i);
            if (_balanceOf(t) < _feeOwed(i) + pendingByToken[t]) revert Insolvent(t);
        }
    }

    function _balanceOf(address token) internal view returns (uint256) {
        return token == ETH ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));
    }

    // ========== Pool access (virtual for unit tests) ==========

    function _poolState() internal view virtual returns (uint160 sqrtPriceX96, uint128 liquidity) {
        PoolId id = _poolKey.toId();
        (sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
        liquidity = StateLibrary.getLiquidity(poolManager, id);
    }

    function _poolSwap(bool zeroForOne, uint256 amountIn) internal virtual returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        bytes memory res = poolManager.unlock(abi.encode(ACTION_SWAP, abi.encode(zeroForOne, amountIn)));
        amountOut = abi.decode(res, (uint256));
    }

    function _poolModify(int256 liquidityDelta)
        internal
        virtual
        returns (uint256 used0, uint256 used1, uint256 fees0, uint256 fees1)
    {
        bytes memory res = poolManager.unlock(abi.encode(ACTION_MODIFY, abi.encode(liquidityDelta)));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = abi.decode(res, (BalanceDelta, BalanceDelta));
        fees0 = _pos(feesAccrued.amount0());
        fees1 = _pos(feesAccrued.amount1());
        // callerDelta = principal + fees; principal is what the add paid in (negative).
        int256 p0 = int256(callerDelta.amount0()) - int256(feesAccrued.amount0());
        int256 p1 = int256(callerDelta.amount1()) - int256(feesAccrued.amount1());
        used0 = p0 < 0 ? uint256(-p0) : 0;
        used1 = p1 < 0 ? uint256(-p1) : 0;
    }

    function _pos(int128 x) private pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }

    /// @notice PoolManager unlock callback: the vault's own swaps and position changes in the alignment pool.
    // slither-disable-next-line unused-return
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        (uint8 action, bytes memory inner) = abi.decode(data, (uint8, bytes));
        PoolKey memory key = _poolKey;
        if (action == ACTION_MODIFY) {
            int256 liquidityDelta = abi.decode(inner, (int256));
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
                }),
                ""
            );
            _settleDelta(key, callerDelta);
            return abi.encode(callerDelta, feesAccrued);
        }
        (bool zeroForOne, uint256 amountIn) = abi.decode(inner, (bool, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settleDelta(key, delta);
        return abi.encode(_pos(zeroForOne ? delta.amount1() : delta.amount0()));
    }

    function _settleDelta(PoolKey memory key, BalanceDelta delta) private {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d0 < 0) key.currency0.settle(poolManager, address(this), uint128(-d0), false);
        else if (d0 > 0) key.currency0.take(poolManager, address(this), uint128(d0), false);
        if (d1 < 0) key.currency1.settle(poolManager, address(this), uint128(-d1), false);
        else if (d1 > 0) key.currency1.take(poolManager, address(this), uint128(d1), false);
    }

    function _isCollecting() private view returns (bool collecting) {
        assembly ("memory-safe") {
            collecting := tload(_COLLECTING_SLOT)
        }
    }

    // ========== Views ==========

    /// @notice Shares the benefactor holds, including any from a converted batch it has not touched since.
    function benefactorShares(address benefactor) public view returns (uint256 shares) {
        (shares,) = _owedSinceCheckpoint(benefactor);
    }

    function getBenefactorShares(address benefactor) external view override returns (uint256) {
        return benefactorShares(benefactor);
    }

    /// @inheritdoc IAlignmentVault
    function pendingOf(address benefactor, address token) external view override returns (uint256) {
        return PendingLedger.pendingOf(_pools[token], _records[benefactor][token]);
    }

    /// @inheritdoc IAlignmentVault
    function claimable(address benefactor) external view override returns (uint256, uint256, uint256) {
        (, uint256[3] memory owed) = _owedSinceCheckpoint(benefactor);
        uint256[3] storage s = _settled[benefactor];
        return (s[0] + owed[0], s[1] + owed[1], s[2] + owed[2]);
    }

    /// @notice The tokens with something pending (any order; convertAndAddLiquidity takes any subset of them).
    function openBatchTokens() external view returns (address[] memory) {
        return _openTokens;
    }

    function alignmentPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Per fee token (INFER, IMD, address(0) = ETH dust): index, lifetime distributed and claimed, protocol cut held.
    function feeStats(address token)
        external
        view
        returns (uint256 accPerShare, uint256 distributed, uint256 claimed, uint256 protocolFees)
    {
        uint256 i = _feeIndex(token);
        return (_accPerShare[i], _distributed[i], _claimed[i], _protocolFees[i]);
    }

    /// @notice Address that receives the protocol's yield cut.
    function protocolTreasury() external view returns (address) {
        return registry.treasury();
    }

    function vaultType() external pure override returns (string memory) {
        return "UniswapV4LP";
    }

    function description() external pure override returns (string memory) {
        return "Turns every contribution into full-range INFER/IMD liquidity on Uniswap v4; shares earn the position's fees";
    }

    function supportsCapability(bytes32 capability) external pure override returns (bool) {
        return capability == keccak256("YIELD_GENERATION") || capability == keccak256("BENEFACTOR_DELEGATION")
            || capability == keccak256("MULTI_ASSET");
    }

    function currentPolicy() external pure override returns (bytes memory) {
        return "";
    }

    function validateCompliance(address) external pure override returns (bool) {
        return true;
    }

    // ========== Delegation ==========

    function delegateBenefactor(address delegate) external override {
        if (!isBenefactor[msg.sender]) revert NotBenefactor();
        benefactorDelegate[msg.sender] = delegate;
        emit BenefactorDelegateSet(msg.sender, delegate);
    }

    function getBenefactorDelegate(address benefactor) external view override returns (address) {
        address delegate = benefactorDelegate[benefactor];
        return delegate == address(0) ? benefactor : delegate;
    }
}
