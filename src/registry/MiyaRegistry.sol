// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { IMiyaRegistry } from "./interfaces/IMiyaRegistry.sol";

/**
 * @title MiyaRegistry
 * @notice Slim, non-upgradeable protocol registry. The owner (a multisig) can only:
 *         - set the treasury, the protocol fee (capped) and the minimum alignment share for FUTURE launches;
 *         - add and deactivate alignment targets;
 *         - approve and revoke add-on components;
 *         - register and unregister factories and vault factories;
 *         - allow and drop payment tokens (ERC-20s collections may price in; ETH is always allowed). Dropping a token
 *           only stops new sales and contributions in it; balances already held stay withdrawable.
 *         It cannot touch deployed collections, their fee terms, their vaults, or any pool. Collections snapshot
 *         their fee terms at launch.
 */
contract MiyaRegistry is Ownable, IMiyaRegistry {
    uint16 public constant BPS = 10_000;
    /// @dev Hard ceiling on the protocol fee, whatever the owner sets.
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 500;
    /// @notice Most ERC-20s allowed at once. A vault holds at most 16 distinct tokens pending (in all, and per
    ///         benefactor), ETH included, so 15 ERC-20s + ETH always fit and no allowed token can be refused for that.
    uint256 public constant MAX_PAYMENT_TOKENS = 15;

    struct Target {
        string name;
        bool active;
    }

    address public treasury;
    /// @notice The only address allowed to run vault swaps (see UniAlignmentVault). Unset = conversions paused.
    address public conversionKeeper;
    uint16 public protocolFeeBps;
    uint16 public minAlignmentBps;

    Target[] internal _targets;
    mapping(uint256 targetId => mapping(address token => bool)) internal _tokenInTarget;
    mapping(uint256 targetId => address[]) internal _targetTokens;

    mapping(address => bool) public isApprovedComponent;
    mapping(address => bool) public isFactoryRegistered;
    mapping(address => bool) public isVaultFactoryRegistered;
    mapping(address => bool) public isVault;

    mapping(address instance => address) public vaultOf;
    mapping(address instance => address) public factoryOf;
    address[] public instances;

    mapping(address token => bool) internal _paymentToken;
    address[] internal _paymentTokens;

    event TreasuryUpdated(address treasury);
    event ConversionKeeperUpdated(address keeper);
    event FeesUpdated(uint16 protocolFeeBps, uint16 minAlignmentBps);
    event TargetAdded(uint256 indexed targetId, string name, address[] tokens);
    event TargetActiveSet(uint256 indexed targetId, bool active);
    event ComponentSet(address indexed component, bool approved);
    event FactorySet(address indexed factory, bool registered);
    event VaultFactorySet(address indexed factory, bool registered);
    event VaultRegistered(address indexed vault, address indexed factory);
    event PaymentTokenSet(address indexed token, bool allowed);
    event InstanceRegistered(address indexed instance, address indexed factory, address indexed vault, address creator);

    error InvalidAddress();
    error FeeTooHigh();
    error InvalidAlignment();
    error UnknownTarget();
    error NotFactory();
    error NotVaultFactory();
    error AlreadyRegistered();
    error TooManyPaymentTokens();

    constructor(address owner_, address treasury_, uint16 protocolFeeBps_, uint16 minAlignmentBps_) {
        _initializeOwner(owner_);
        _setTreasury(treasury_);
        _setFees(protocolFeeBps_, minAlignmentBps_);
    }

    // ── fees ────────────────────────────────────────────────────────────────

    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    function setConversionKeeper(address keeper) external onlyOwner {
        conversionKeeper = keeper;
        emit ConversionKeeperUpdated(keeper);
    }

    function setFees(uint16 protocolFeeBps_, uint16 minAlignmentBps_) external onlyOwner {
        _setFees(protocolFeeBps_, minAlignmentBps_);
    }

    function checkAlignmentBps(uint16 alignmentBps) external view {
        if (alignmentBps < minAlignmentBps || uint256(alignmentBps) + protocolFeeBps > BPS) revert InvalidAlignment();
    }

    // ── alignment targets ───────────────────────────────────────────────────

    function addTarget(string calldata name, address[] calldata tokens) external onlyOwner returns (uint256 targetId) {
        if (tokens.length == 0) revert InvalidAddress();
        targetId = _targets.length;
        _targets.push(Target(name, true));
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert InvalidAddress();
            if (!_tokenInTarget[targetId][tokens[i]]) {
                _tokenInTarget[targetId][tokens[i]] = true;
                _targetTokens[targetId].push(tokens[i]);
            }
        }
        emit TargetAdded(targetId, name, tokens);
    }

    function setTargetActive(uint256 targetId, bool active) external onlyOwner {
        if (targetId >= _targets.length) revert UnknownTarget();
        _targets[targetId].active = active;
        emit TargetActiveSet(targetId, active);
    }

    function isAlignmentTargetActive(uint256 targetId) external view returns (bool) {
        return targetId < _targets.length && _targets[targetId].active;
    }

    function isTokenInTarget(uint256 targetId, address token) external view returns (bool) {
        return _tokenInTarget[targetId][token];
    }

    function getTarget(uint256 targetId)
        external
        view
        returns (string memory name, bool active, address[] memory tokens)
    {
        if (targetId >= _targets.length) revert UnknownTarget();
        Target storage t = _targets[targetId];
        return (t.name, t.active, _targetTokens[targetId]);
    }

    function targetCount() external view returns (uint256) {
        return _targets.length;
    }

    // ── components and factories ────────────────────────────────────────────

    function setComponent(address component, bool approved) external onlyOwner {
        if (component == address(0)) revert InvalidAddress();
        isApprovedComponent[component] = approved;
        emit ComponentSet(component, approved);
    }

    function setFactory(address factory, bool registered) external onlyOwner {
        if (factory == address(0)) revert InvalidAddress();
        isFactoryRegistered[factory] = registered;
        emit FactorySet(factory, registered);
    }

    function setVaultFactory(address factory, bool registered) external onlyOwner {
        if (factory == address(0)) revert InvalidAddress();
        isVaultFactoryRegistered[factory] = registered;
        emit VaultFactorySet(factory, registered);
    }

    // ── payment tokens ──────────────────────────────────────────────────────

    /// @notice True for ETH (address(0)) and for allowlisted ERC-20s.
    function isPaymentToken(address token) external view returns (bool) {
        return token == address(0) || _paymentToken[token];
    }

    /// @notice Allow or drop an ERC-20 as a payment token. ETH is always allowed and can't be set.
    /// @dev Fee-on-transfer or rebasing tokens must never be allowed: collections and the vault check balance deltas
    ///      and revert on a short transfer.
    function setPaymentToken(address token, bool allowed) external onlyOwner {
        if (token == address(0) || token.code.length == 0) revert InvalidAddress();
        if (_paymentToken[token] == allowed) return;
        _paymentToken[token] = allowed;
        if (allowed) {
            if (_paymentTokens.length >= MAX_PAYMENT_TOKENS) revert TooManyPaymentTokens();
            _paymentTokens.push(token);
        } else {
            uint256 n = _paymentTokens.length;
            for (uint256 i; i < n; ++i) {
                if (_paymentTokens[i] == token) {
                    _paymentTokens[i] = _paymentTokens[n - 1];
                    _paymentTokens.pop();
                    break;
                }
            }
        }
        emit PaymentTokenSet(token, allowed);
    }

    /// @notice The allowlisted ERC-20s (ETH, always allowed, is not listed).
    function paymentTokens() external view returns (address[] memory) {
        return _paymentTokens;
    }

    // ── vaults ──────────────────────────────────────────────────────────────

    function registerVault(address vault) external {
        if (!isVaultFactoryRegistered[msg.sender]) revert NotVaultFactory();
        if (vault == address(0)) revert InvalidAddress();
        if (isVault[vault]) revert AlreadyRegistered();
        isVault[vault] = true;
        emit VaultRegistered(vault, msg.sender);
    }

    // ── collections ─────────────────────────────────────────────────────────

    function registerInstance(address instance, address vault, address creator) external {
        if (!isFactoryRegistered[msg.sender]) revert NotFactory();
        if (instance == address(0)) revert InvalidAddress();
        if (factoryOf[instance] != address(0)) revert AlreadyRegistered();
        factoryOf[instance] = msg.sender;
        vaultOf[instance] = vault;
        instances.push(instance);
        emit InstanceRegistered(instance, msg.sender, vault, creator);
    }

    function instanceCount() external view returns (uint256) {
        return instances.length;
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _setTreasury(address treasury_) internal {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function _setFees(uint16 protocolFeeBps_, uint16 minAlignmentBps_) internal {
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        if (uint256(protocolFeeBps_) + minAlignmentBps_ > BPS) revert InvalidAlignment();
        protocolFeeBps = protocolFeeBps_;
        minAlignmentBps = minAlignmentBps_;
        emit FeesUpdated(protocolFeeBps_, minAlignmentBps_);
    }
}
