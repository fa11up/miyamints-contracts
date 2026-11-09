// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketTypes } from "./MarketTypes.sol";
import { ParimutuelMarket } from "./ParimutuelMarket.sol";
import { PredictionRegistry } from "./PredictionRegistry.sol";

/**
 * @title MarketFactory
 * @notice Deploys ParimutuelMarket clones (EIP-1167) from an allow-listed template plus slot values. Creators
 *         never write free text: the question document is the template's fixed parts with the slots spliced in,
 *         and its hash is computed here, on chain. The full documents are emitted so anyone can buy the exact
 *         question from the oracle and check it against the market's `questionHash`.
 *
 *         Slots are restricted to printable ASCII without `"` or `\`, so a slot can never close the JSON string
 *         it sits in and smuggle extra fields into the hashed document.
 */
contract MarketFactory is ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant MAX_SLOT_BYTES = 256;
    /// @dev Longest a market may stay open.
    uint64 public constant MAX_OPEN_DURATION = 365 days;
    /// @dev Longest a market may wait for its result after locking. Stakes can't move until it resolves or voids, and
    ///      voiding needs `resolveAfter` + PROPOSE_GRACE, so without this a creator could freeze them indefinitely.
    ///      A far-off event sets a later `lockAt`, not a longer gap. Worst case 365 + 30 + 7 days.
    uint64 public constant MAX_RESOLVE_GAP = 30 days;

    struct CreateParams {
        uint256 templateId;
        bytes[] slots;
        uint64 lockAt;
        uint64 resolveAfter;
        /// @dev Threshold templates only (outcome 1 iff answer > threshold); must be 0 otherwise.
        uint256 threshold;
        address resolver;
    }

    PredictionRegistry public immutable registry;
    address public immutable implementation;

    event MarketCreated(
        address indexed market,
        address indexed creator,
        uint256 indexed templateId,
        bytes32 questionHash,
        bytes32 startQuestionHash,
        bytes questionPrefix,
        bytes startPrefix
    );

    error InvalidAddress();
    error NotCreator();
    error TemplateInactive();
    error WrongSlotCount();
    error InvalidSlot(uint256 index);
    error InvalidTimes();
    error InvalidThreshold();
    error ResolverNotAllowed();
    error ModulesNotSet();
    error CloneFailed();

    constructor(PredictionRegistry registry_) {
        if (address(registry_) == address(0)) revert InvalidAddress();
        registry = registry_;
        implementation = address(new ParimutuelMarket());
    }

    // ── views ───────────────────────────────────────────────────────────────

    /// @notice The question documents (main and start; start is empty if the template has none) for slots.
    function buildPrefixes(uint256 templateId, bytes[] calldata slots)
        public
        view
        returns (bytes memory question, bytes memory start)
    {
        MarketTypes.Template memory t = registry.getTemplate(templateId);
        if (slots.length != t.slotCount) revert WrongSlotCount();
        for (uint256 i; i < slots.length; ++i) {
            if (!isValidSlot(slots[i])) revert InvalidSlot(i);
        }
        question = _assemble(t.parts, slots);
        if (t.startParts.length != 0) start = _assemble(t.startParts, slots);
    }

    function isValidSlot(bytes calldata slot) public pure returns (bool) {
        if (slot.length == 0 || slot.length > MAX_SLOT_BYTES) return false;
        for (uint256 i; i < slot.length; ++i) {
            bytes1 c = slot[i];
            if (c < 0x20 || c > 0x7e || c == '"' || c == "\\") return false;
        }
        return true;
    }

    // ── creating ────────────────────────────────────────────────────────────

    /// @notice Create a market. Only registered creators. The creator bond (if any) is pulled from the creator.
    function createMarket(CreateParams calldata p) external nonReentrant returns (address market) {
        if (!registry.isCreator(msg.sender)) revert NotCreator();
        MarketTypes.Template memory tpl = registry.getTemplate(p.templateId);
        if (!tpl.active) revert TemplateInactive();
        if (!registry.isResolverAllowed(p.resolver)) revert ResolverNotAllowed();
        if (p.lockAt <= block.timestamp || p.lockAt > block.timestamp + MAX_OPEN_DURATION) revert InvalidTimes();
        if (p.resolveAfter < uint256(p.lockAt) + tpl.minLockGap) revert InvalidTimes();
        if (p.resolveAfter > uint256(p.lockAt) + MAX_RESOLVE_GAP) revert InvalidTimes();
        if (tpl.answerMode != MarketTypes.AnswerMode.Threshold && p.threshold != 0) revert InvalidThreshold();

        (bytes memory question, bytes memory start) = buildPrefixes(p.templateId, p.slots);
        MarketTypes.Terms memory terms = _terms(tpl, p, keccak256(question), start);

        address[] memory crew = registry.crewOf(msg.sender);
        address[] memory denied = new address[](crew.length + 1);
        denied[0] = msg.sender;
        for (uint256 i; i < crew.length; ++i) {
            denied[i + 1] = crew[i];
        }

        market = _clone(implementation);
        registry.registerMarket(market, msg.sender, terms.questionHash);
        ParimutuelMarket(market).initialize(terms, denied);
        if (terms.creatorBond != 0) terms.token.safeTransferFrom(msg.sender, market, terms.creatorBond);

        emit MarketCreated(
            market, msg.sender, p.templateId, terms.questionHash, terms.startQuestionHash, question, start
        );
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _terms(MarketTypes.Template memory tpl, CreateParams calldata p, bytes32 questionHash, bytes memory start)
        internal
        view
        returns (MarketTypes.Terms memory t)
    {
        PredictionRegistry.Config memory c = registry.config();
        if (
            c.door == address(0) || c.eligibility == address(0) || c.exitDesk == address(0)
                || c.disputeModule == address(0) || c.disputeResolver == address(0) || c.council == address(0)
        ) revert ModulesNotSet();

        t.token = registry.token();
        t.registry = address(registry);
        t.creator = msg.sender;
        t.door = c.door;
        t.eligibility = c.eligibility;
        t.resolver = p.resolver;
        t.disputeResolver = c.disputeResolver;
        t.disputeModule = c.disputeModule;
        t.council = c.council;
        t.treasury = c.treasury;
        t.resolverBudget = c.resolverBudget;
        t.insurance = c.insurance;
        t.rake = c.rake;
        t.perWalletCap = c.perWalletCap;
        t.perMarketCap = c.perMarketCap;
        t.minStake = c.minStake;
        t.minBond = c.minBond;
        t.bondBps = c.bondBps;
        t.creatorBond = c.creatorBond;
        t.lockAt = p.lockAt;
        t.resolveAfter = p.resolveAfter;
        t.lockMargin = c.lockMargin;
        t.disputeWindow = tpl.disputeWindow;
        t.questionHash = questionHash;
        t.startQuestionHash = start.length == 0 ? bytes32(0) : keccak256(start);
        t.dataChainId = tpl.dataChainId;
        t.answerType = tpl.answerType;
        t.answerMode = tpl.answerMode;
        t.outcomeCount = tpl.outcomeCount;
        t.threshold = p.threshold;
        t.codeMap = tpl.codeMap;
    }

    /// @dev Exact EIP-1167 minimal proxy (45-byte runtime), so explorers recognise the clones.
    function _clone(address impl) internal returns (address instance) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    function _assemble(bytes[] memory parts, bytes[] calldata slots) internal pure returns (bytes memory out) {
        out = parts[0];
        for (uint256 i; i < slots.length; ++i) {
            out = bytes.concat(out, slots[i], parts[i + 1]);
        }
    }
}
