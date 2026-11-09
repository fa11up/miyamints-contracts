// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketTypes } from "./MarketTypes.sol";
import { IDisputeModule, IParimutuelMarket, IPredictionRegistry, IResolver } from "./interfaces/IMarkets.sol";

/**
 * @title SwarmResolver
 * @notice Turns IdentityMD swarm-panel attestations into market outcomes. The verification core is the one used
 *         by the oracle co-op hub and the proposal guard: the plane's EIP-712 `OracleAttestation` struct under
 *         the domain ("IdentityMD Oracle", "2", chainId, verifyingContract = THIS resolver), with the signed
 *         window spliced back into the question document to recompute the questionHash.
 *
 *         An attestation is accepted for a market only if:
 *         - it is signed by `attester` for THIS contract on THIS chain (the request's consumer must be this
 *           resolver; a signature bought for any other consumer does not verify);
 *         - the supplied question prefix hashes to the market's `questionHash` (fixed at creation from the
 *           template and slots) and the attested questionHash equals that prefix with the signed window spliced
 *           in, so it answers exactly this market's question and no other;
 *         - it asks about the market's data chain, with the template's answer type;
 *         - panel floors hold as ABSOLUTE COUNTS: panelSize >= minPanel, quorum >= minQuorum, and
 *           agreed >= quorum. The plane has signed attestations whose agreed count fell short of the requested
 *           quorum, so the quorum is re-checked here rather than trusted;
 *         - it was issued at or after the market's `resolveAfter`, has not expired, and its request id is unused.
 *
 *         Source-clock markets also need a second attestation (the template's start question, uint256 unix
 *         seconds) carrying the official start; it passes the same checks against `startQuestionHash`.
 *
 *         Tier `Primary` proposes to the market; tier `Dispute` reports to the market's dispute module. Deploy
 *         one of each: they have different addresses, so a primary answer can never be replayed as the
 *         independent second-panel answer.
 *
 *         No owner, no setter. Anyone may submit; authority comes only from the signature.
 */
contract SwarmResolver is IResolver {
    enum Tier {
        Primary,
        Dispute
    }

    /// @dev Field-for-field the plane's signed struct.
    struct Attestation {
        bytes32 requestId;
        uint256 chainId; // the chain the question is ABOUT, not the chain this resolver runs on
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    /// @notice An attestation, its signature, and the market question prefix it answers.
    struct Signed {
        Attestation a;
        bytes sig;
        bytes prefix;
    }

    struct Result {
        bool answered;
        uint8 outcome;
        uint64 attestedStart;
        bytes32 requestId;
    }

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    /// @dev Smallest panel the plane accepts for an oracle request.
    uint16 public constant PLANE_MIN_PANEL = 5;

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("IdentityMD Oracle");
    bytes32 private constant _VERSION_HASH = keccak256("2");
    uint256 private constant _HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    IPredictionRegistry public immutable registry;
    /// @notice The oracle service key whose signatures this resolver accepts.
    address public immutable attester;
    Tier public immutable tier;
    uint16 public immutable minPanel;
    uint16 public immutable minQuorum;

    mapping(bytes32 requestId => bool) public usedRequests;
    mapping(address market => Result) internal _results;

    event Resolved(
        address indexed market, bytes32 indexed requestId, uint8 outcome, uint64 attestedStart, address submitter
    );

    error InvalidConfiguration();
    error UnknownMarket();
    error AlreadyAnswered();
    error WrongQuestion(bytes32 expected, bytes32 given);
    error WrongDataChain();
    error WrongAnswerType();
    error PanelTooSmall();
    error QuorumTooLow();
    error NotEnoughAgreement();
    error IssuedBeforeEvent();
    error InvalidTimestamp();
    error ExpiredAttestation();
    error ReplayedAttestation();
    error InvalidWindow();
    error InvalidAnswer();
    error UnexpectedStart();
    error InvalidSignature();

    constructor(IPredictionRegistry registry_, address attester_, Tier tier_, uint16 minPanel_, uint16 minQuorum_) {
        if (address(registry_) == address(0) || attester_ == address(0)) revert InvalidConfiguration();
        if (minPanel_ < PLANE_MIN_PANEL || minQuorum_ == 0 || minQuorum_ > minPanel_) revert InvalidConfiguration();
        registry = registry_;
        attester = attester_;
        tier = tier_;
        minPanel = minPanel_;
        minQuorum = minQuorum_;
    }

    // ── submitting ──────────────────────────────────────────────────────────

    /// @notice Submit the panel's answer for `market` (and, for source-clock markets, the start-time answer).
    ///         Pass an empty `start.prefix` when the market has no start question. Anyone may call.
    function submit(address market, Signed calldata answer, Signed calldata start) external {
        if (!registry.isMarket(market)) revert UnknownMarket();
        if (_results[market].answered) revert AlreadyAnswered();
        IParimutuelMarket m = IParimutuelMarket(market);
        MarketTypes.Terms memory t = m.terms();

        _verify(answer, t.questionHash, t.answerType, t);
        uint8 outcome = m.outcomeForAnswer(_word(answer.a.answer));

        uint64 attestedStart;
        if (tier == Tier.Primary && t.startQuestionHash != bytes32(0)) {
            _verify(start, t.startQuestionHash, MarketTypes.ANSWER_UINT256, t);
            uint256 s = _word(start.a.answer);
            if (s == 0 || s > type(uint64).max) revert InvalidAnswer();
            attestedStart = uint64(s);
        } else if (start.prefix.length != 0 || start.sig.length != 0) {
            revert UnexpectedStart();
        }

        _results[market] = Result(true, outcome, attestedStart, answer.a.requestId);
        emit Resolved(market, answer.a.requestId, outcome, attestedStart, msg.sender);

        if (tier == Tier.Primary) {
            m.propose(outcome, attestedStart, msg.sender);
        } else {
            IDisputeModule(t.disputeModule).onPanelResult(market, outcome);
        }
    }

    // ── views ───────────────────────────────────────────────────────────────

    /// @inheritdoc IResolver
    function result(address market) external view returns (bool answered, uint8 outcome, uint64 attestedStart) {
        Result storage r = _results[market];
        return (r.answered, r.outcome, r.attestedStart);
    }

    /// @notice The questionHash the plane signs for `prefix` over a given window.
    function expectedQuestionHash(bytes calldata prefix, uint64 fromBlock, uint64 toBlock)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prefix, _decimal(fromBlock), ',"toBlock":', _decimal(toBlock), "}}"));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice EIP-712 digest of an attestation under this resolver's domain.
    function digest(Attestation calldata a) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), _structHash(a)));
    }

    /// @notice The address that signed `a` for this resolver (reverts on a malformed signature).
    function signerOf(Attestation calldata a, bytes calldata sig) external view returns (address) {
        return _recover(digest(a), sig);
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _verify(Signed calldata s, bytes32 questionHash, uint8 answerType, MarketTypes.Terms memory t) internal {
        Attestation calldata a = s.a;
        if (keccak256(s.prefix) != questionHash) revert WrongQuestion(questionHash, keccak256(s.prefix));
        if (a.chainId != t.dataChainId) revert WrongDataChain();
        if (a.answerType != answerType) revert WrongAnswerType();
        if (a.panelSize < minPanel) revert PanelTooSmall();
        if (a.quorum < minQuorum) revert QuorumTooLow();
        if (a.agreed < a.quorum || a.agreed > a.panelSize) revert NotEnoughAgreement();
        if (block.timestamp > a.expiresAt) revert ExpiredAttestation();
        if (a.issuedAt > block.timestamp || a.issuedAt > a.expiresAt) revert InvalidTimestamp();
        if (a.issuedAt < t.resolveAfter) revert IssuedBeforeEvent();
        if (a.toBlock < a.fromBlock) revert InvalidWindow();
        if (a.answer.length != 32) revert InvalidAnswer();
        if (usedRequests[a.requestId]) revert ReplayedAttestation();
        bytes32 expected = expectedQuestionHash(s.prefix, a.fromBlock, a.toBlock);
        if (a.questionHash != expected) revert WrongQuestion(expected, a.questionHash);
        if (_recover(digest(a), s.sig) != attester) revert InvalidSignature();
        usedRequests[a.requestId] = true;
    }

    function _word(bytes calldata answer) internal pure returns (uint256 v) {
        v = uint256(bytes32(answer[:32]));
    }

    /// @dev Two `abi.encode` calls concatenated: every field is one static word, so this is byte-identical to
    ///      encoding all sixteen at once and stays clear of stack-too-deep.
    function _structHash(Attestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock
                ),
                abi.encode(
                    a.toBlock, a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt
                )
            )
        );
    }

    function _recover(bytes32 d, bytes calldata sig) internal pure returns (address signer) {
        if (sig.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (uint256(s) > _HALF_CURVE_ORDER || (v != 27 && v != 28)) revert InvalidSignature();
        signer = ecrecover(d, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    /// @dev Minimal decimal ASCII, because the window's numbers appear in the hashed JSON as digits.
    function _decimal(uint64 value) internal pure returns (bytes memory out) {
        if (value == 0) return "0";
        uint64 digits;
        for (uint64 v = value; v != 0; v /= 10) {
            ++digits;
        }
        out = new bytes(digits);
        for (uint64 v = value; v != 0; v /= 10) {
            out[--digits] = bytes1(uint8(48 + (v % 10)));
        }
    }
}
