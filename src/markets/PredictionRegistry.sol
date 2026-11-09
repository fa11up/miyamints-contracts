// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { MarketTypes } from "./MarketTypes.sol";
import { IExitDesk, IPredictionRegistry } from "./interfaces/IMarkets.sol";

/**
 * @title PredictionRegistry
 * @notice Slim, non-upgradeable registry for parimutuel prediction markets. The owner (a multisig) can only:
 *         - set the recipients (treasury, resolver budget, insurance reserve) for FUTURE markets;
 *         - set the rake split (capped), the caps, the minimum stake, the lock margin (floored) and the bond
 *           sizes for FUTURE markets;
 *         - set the modules (door, eligibility gate, exit desk, dispute module, dispute resolver, council) that
 *           FUTURE markets snapshot;
 *         - add and deactivate templates, allow-list resolvers, register creators and their crew wallets;
 *         - set the factory.
 *         It cannot touch a deployed market, its terms, or any stake. Markets snapshot their terms at creation.
 *         The registry also keeps the global open interest and refuses a stake that would take it above the
 *         exit desk's USDC balance.
 */
contract PredictionRegistry is Ownable, IPredictionRegistry {
    uint16 public constant BPS = 10_000;
    /// @dev Hard ceiling on the total rake (sum of the four legs), whatever the owner sets.
    uint16 public constant MAX_RAKE_BPS = 500;
    /// @dev Hard ceiling on the variable part of the dispute bond.
    uint16 public constant MAX_BOND_BPS = 1_000;
    /// @dev Stakes inside this many seconds before the attested start are refunded. Floor of three minutes.
    uint32 public constant MIN_LOCK_MARGIN = 180;
    uint32 public constant MAX_LOCK_MARGIN = 1 days;
    uint256 public constant MAX_CREW = 32;
    uint256 public constant MAX_SLOTS = 8;
    uint256 public constant MAX_PART_BYTES = 4096;
    uint32 public constant MIN_DISPUTE_WINDOW = 1 hours;
    uint32 public constant MAX_DISPUTE_WINDOW = 7 days;

    bytes private constant _WINDOW_MARKER = ',"window":{"fromBlock":';

    /// @notice Owner-set defaults that new markets snapshot.
    struct Config {
        address treasury;
        address resolverBudget;
        address insurance;
        address door;
        address eligibility;
        address exitDesk;
        address disputeModule;
        address disputeResolver;
        address council;
        MarketTypes.RakeSplit rake;
        uint128 perWalletCap;
        uint128 perMarketCap;
        uint128 minStake;
        uint128 minBond;
        uint16 bondBps;
        uint128 creatorBond;
        uint32 lockMargin;
    }

    address public immutable token;

    Config internal _config;
    MarketTypes.Template[] internal _templates;

    address public factory;
    mapping(address resolver => bool) public isResolverAllowed;
    mapping(address creator => bool) public isCreator;
    mapping(address creator => address[]) internal _crew;

    mapping(address => bool) public isMarket;
    address[] public markets;
    /// @notice imdUSD staked into markets and not yet paid out, across every market.
    uint256 public openInterest;

    event RecipientsSet(address treasury, address resolverBudget, address insurance);
    event ModulesSet(
        address door,
        address eligibility,
        address exitDesk,
        address disputeModule,
        address disputeResolver,
        address council
    );
    event RakeSet(uint16 treasuryBps, uint16 creatorBps, uint16 resolverBps, uint16 insuranceBps);
    event LimitsSet(uint128 perWalletCap, uint128 perMarketCap, uint128 minStake, uint32 lockMargin);
    event BondsSet(uint128 minBond, uint16 bondBps, uint128 creatorBond);
    event TemplateAdded(uint256 indexed templateId, string name);
    event TemplateActiveSet(uint256 indexed templateId, bool active);
    event ResolverSet(address indexed resolver, bool allowed);
    event CreatorSet(address indexed creator, bool active, address[] crew);
    event FactorySet(address indexed factory);
    event MarketRegistered(address indexed market, address indexed creator, bytes32 indexed questionHash);
    event OpenInterestChanged(uint256 openInterest);

    error InvalidAddress();
    error RakeTooHigh();
    error InvalidLimits();
    error InvalidBond();
    error InvalidTemplate();
    error UnknownTemplate();
    error CrewTooLarge();
    error NotFactory();
    error NotMarket();
    error AlreadyRegistered();
    error ExceedsExitCover(uint256 openInterest, uint256 cover);

    constructor(address owner_, address token_, Config memory config_) {
        if (token_ == address(0)) revert InvalidAddress();
        _initializeOwner(owner_);
        token = token_;
        _setRecipients(config_.treasury, config_.resolverBudget, config_.insurance);
        _setModules(
            config_.door,
            config_.eligibility,
            config_.exitDesk,
            config_.disputeModule,
            config_.disputeResolver,
            config_.council
        );
        _setRake(config_.rake);
        _setLimits(config_.perWalletCap, config_.perMarketCap, config_.minStake, config_.lockMargin);
        _setBonds(config_.minBond, config_.bondBps, config_.creatorBond);
    }

    // ── owner: defaults for future markets ──────────────────────────────────

    function setRecipients(address treasury_, address resolverBudget_, address insurance_) external onlyOwner {
        _setRecipients(treasury_, resolverBudget_, insurance_);
    }

    function setModules(
        address door_,
        address eligibility_,
        address exitDesk_,
        address disputeModule_,
        address disputeResolver_,
        address council_
    ) external onlyOwner {
        _setModules(door_, eligibility_, exitDesk_, disputeModule_, disputeResolver_, council_);
    }

    function setRake(MarketTypes.RakeSplit calldata rake_) external onlyOwner {
        _setRake(rake_);
    }

    function setLimits(uint128 perWalletCap_, uint128 perMarketCap_, uint128 minStake_, uint32 lockMargin_)
        external
        onlyOwner
    {
        _setLimits(perWalletCap_, perMarketCap_, minStake_, lockMargin_);
    }

    function setBonds(uint128 minBond_, uint16 bondBps_, uint128 creatorBond_) external onlyOwner {
        _setBonds(minBond_, bondBps_, creatorBond_);
    }

    function config() external view returns (Config memory) {
        return _config;
    }

    function rakeBps() public view returns (uint256) {
        MarketTypes.RakeSplit memory r = _config.rake;
        return uint256(r.treasuryBps) + r.creatorBps + r.resolverBps + r.insuranceBps;
    }

    // ── owner: templates ────────────────────────────────────────────────────

    function addTemplate(MarketTypes.Template calldata t) external onlyOwner returns (uint256 templateId) {
        _validateTemplate(t);
        templateId = _templates.length;
        _templates.push(t);
        _templates[templateId].active = true;
        emit TemplateAdded(templateId, t.name);
    }

    function setTemplateActive(uint256 templateId, bool active) external onlyOwner {
        if (templateId >= _templates.length) revert UnknownTemplate();
        _templates[templateId].active = active;
        emit TemplateActiveSet(templateId, active);
    }

    function getTemplate(uint256 templateId) external view returns (MarketTypes.Template memory) {
        if (templateId >= _templates.length) revert UnknownTemplate();
        return _templates[templateId];
    }

    function templateCount() external view returns (uint256) {
        return _templates.length;
    }

    // ── owner: resolvers, creators, factory ─────────────────────────────────

    function setResolver(address resolver, bool allowed) external onlyOwner {
        if (resolver == address(0)) revert InvalidAddress();
        isResolverAllowed[resolver] = allowed;
        emit ResolverSet(resolver, allowed);
    }

    /// @notice Register (or deactivate) a KYC'd creator and the crew wallets they declared. Markets copy the
    ///         creator and crew into their deny-list at creation; later edits do not reach existing markets.
    function setCreator(address creator, bool active, address[] calldata crew) external onlyOwner {
        if (creator == address(0)) revert InvalidAddress();
        if (crew.length > MAX_CREW) revert CrewTooLarge();
        for (uint256 i; i < crew.length; ++i) {
            if (crew[i] == address(0)) revert InvalidAddress();
        }
        isCreator[creator] = active;
        _crew[creator] = crew;
        emit CreatorSet(creator, active, crew);
    }

    function crewOf(address creator) external view returns (address[] memory) {
        return _crew[creator];
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert InvalidAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    // ── factory and markets ─────────────────────────────────────────────────

    function registerMarket(address market, address creator, bytes32 questionHash) external {
        if (msg.sender != factory) revert NotFactory();
        if (market == address(0)) revert InvalidAddress();
        if (isMarket[market]) revert AlreadyRegistered();
        isMarket[market] = true;
        markets.push(market);
        emit MarketRegistered(market, creator, questionHash);
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    /// @notice Called by a market for every stake. Refuses a stake that would take the global open interest
    ///         above the exit desk's USDC balance (scaled to 18 decimals).
    function onStake(uint256 amount) external {
        if (!isMarket[msg.sender]) revert NotMarket();
        uint256 oi = openInterest + amount;
        uint256 cover = exitCover();
        if (oi > cover) revert ExceedsExitCover(oi, cover);
        openInterest = oi;
        emit OpenInterestChanged(oi);
    }

    /// @notice Called by a market whenever stake-derived imdUSD leaves it (payouts, refunds, rake, sweep).
    function onRelease(uint256 amount) external {
        if (!isMarket[msg.sender]) revert NotMarket();
        uint256 oi = openInterest;
        oi = amount > oi ? 0 : oi - amount;
        openInterest = oi;
        emit OpenInterestChanged(oi);
    }

    /// @notice The exit desk's USDC balance in 18 decimals; zero when no desk is set.
    function exitCover() public view returns (uint256) {
        address desk = _config.exitDesk;
        return desk == address(0) ? 0 : IExitDesk(desk).capacity();
    }

    /// @notice How much more imdUSD can be staked, protocol-wide, before the exit-cover rule refuses it.
    function openInterestRoom() external view returns (uint256) {
        uint256 cover = exitCover();
        return cover > openInterest ? cover - openInterest : 0;
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _setRecipients(address treasury_, address resolverBudget_, address insurance_) internal {
        if (treasury_ == address(0) || resolverBudget_ == address(0) || insurance_ == address(0)) {
            revert InvalidAddress();
        }
        _config.treasury = treasury_;
        _config.resolverBudget = resolverBudget_;
        _config.insurance = insurance_;
        emit RecipientsSet(treasury_, resolverBudget_, insurance_);
    }

    /// @dev Modules may be zero while the system is being wired; the factory refuses to create a market until
    ///      every module it snapshots is set.
    function _setModules(
        address door_,
        address eligibility_,
        address exitDesk_,
        address disputeModule_,
        address disputeResolver_,
        address council_
    ) internal {
        _config.door = door_;
        _config.eligibility = eligibility_;
        _config.exitDesk = exitDesk_;
        _config.disputeModule = disputeModule_;
        _config.disputeResolver = disputeResolver_;
        _config.council = council_;
        emit ModulesSet(door_, eligibility_, exitDesk_, disputeModule_, disputeResolver_, council_);
    }

    function _setRake(MarketTypes.RakeSplit memory r) internal {
        if (uint256(r.treasuryBps) + r.creatorBps + r.resolverBps + r.insuranceBps > MAX_RAKE_BPS) {
            revert RakeTooHigh();
        }
        _config.rake = r;
        emit RakeSet(r.treasuryBps, r.creatorBps, r.resolverBps, r.insuranceBps);
    }

    function _setLimits(uint128 perWalletCap_, uint128 perMarketCap_, uint128 minStake_, uint32 lockMargin_) internal {
        if (minStake_ == 0 || perWalletCap_ < minStake_ || perMarketCap_ < perWalletCap_) revert InvalidLimits();
        if (lockMargin_ < MIN_LOCK_MARGIN || lockMargin_ > MAX_LOCK_MARGIN) revert InvalidLimits();
        _config.perWalletCap = perWalletCap_;
        _config.perMarketCap = perMarketCap_;
        _config.minStake = minStake_;
        _config.lockMargin = lockMargin_;
        emit LimitsSet(perWalletCap_, perMarketCap_, minStake_, lockMargin_);
    }

    function _setBonds(uint128 minBond_, uint16 bondBps_, uint128 creatorBond_) internal {
        if (minBond_ == 0 || bondBps_ > MAX_BOND_BPS) revert InvalidBond();
        _config.minBond = minBond_;
        _config.bondBps = bondBps_;
        _config.creatorBond = creatorBond_;
        emit BondsSet(minBond_, bondBps_, creatorBond_);
    }

    function _validateTemplate(MarketTypes.Template calldata t) internal pure {
        if (t.slotCount > MAX_SLOTS || t.parts.length != uint256(t.slotCount) + 1) revert InvalidTemplate();
        if (!_partsValid(t.parts)) revert InvalidTemplate();
        if (t.startParts.length != 0) {
            if (t.startParts.length != t.parts.length || !_partsValid(t.startParts)) revert InvalidTemplate();
        }
        if (t.outcomeCount < 2 || t.outcomeCount > MarketTypes.MAX_OUTCOMES) revert InvalidTemplate();
        if (t.disputeWindow < MIN_DISPUTE_WINDOW || t.disputeWindow > MAX_DISPUTE_WINDOW) revert InvalidTemplate();
        if (t.answerMode == MarketTypes.AnswerMode.Coded) {
            if (t.answerType != MarketTypes.ANSWER_UINT256 || t.codeMap.length == 0) revert InvalidTemplate();
            for (uint256 i; i < t.codeMap.length; ++i) {
                if (uint8(t.codeMap[i]) > t.outcomeCount) revert InvalidTemplate();
            }
        } else if (t.answerMode == MarketTypes.AnswerMode.Bool) {
            if (t.answerType != MarketTypes.ANSWER_BOOL || t.outcomeCount != 2 || t.codeMap.length != 0) {
                revert InvalidTemplate();
            }
        } else {
            if (t.answerType != MarketTypes.ANSWER_UINT256 || t.outcomeCount != 2 || t.codeMap.length != 0) {
                revert InvalidTemplate();
            }
        }
    }

    /// @dev Every part is bounded, and the last ends with the window marker the oracle splices the window after.
    function _partsValid(bytes[] calldata parts) internal pure returns (bool) {
        for (uint256 i; i < parts.length; ++i) {
            if (parts[i].length > MAX_PART_BYTES) return false;
        }
        bytes calldata last = parts[parts.length - 1];
        uint256 m = _WINDOW_MARKER.length;
        if (last.length < m) return false;
        return keccak256(last[last.length - m:]) == keccak256(_WINDOW_MARKER);
    }
}
