// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UniAlignmentVault} from "./UniAlignmentVault.sol";
import {IVaultConfig} from "./IVaultConfig.sol";
import {IMiyaRegistry} from "../../registry/interfaces/IMiyaRegistry.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title UniAlignmentVaultFactory (v2)
/// @notice Deploys UniAlignmentVault clones aligned to one INFER/IMD pool and registers each in the MiyaRegistry (this
///         factory must be registered there via setVaultFactory). The factory owns every vault (no passthrough: a
///         vault's config is fixed at deploy) and holds the config every vault reads live (IVaultConfig): the swap
///         targets the keeper's conversion calldata may call (0x AllowanceHolder, zRouter), the least an ERC-20
///         contribution may carry, and the IMD/ETH pool ETH-mode claims swap through. The owner is a Safe; the keeper
///         can't change any of it.
contract UniAlignmentVaultFactory is Ownable, IVaultConfig {
    address internal constant ETH = address(0);

    address public immutable vaultImplementation;
    IMiyaRegistry public immutable registry;
    IPoolManager public immutable poolManager;
    /// @notice zRouter: ETH-mode claims sell IMD for ETH through it (swapV4 on `ethPool`).
    address public immutable zRouter;
    address public immutable infer;
    address public immutable imd;

    /// @notice The alignment pool every vault provides liquidity to (INFER/IMD, hooked, fixed at construction).
    PoolKey internal _poolKey;

    /// @inheritdoc IVaultConfig
    mapping(address target => bool) public isSwapTarget;

    /// @inheritdoc IVaultConfig
    mapping(address token => uint256) public minContribution;

    uint24 internal _ethPoolFee = 10000;
    int24 internal _ethPoolTickSpacing = 200;

    event VaultDeployed(address indexed vault, uint256 indexed alignmentTargetId);
    event SwapTargetSet(address indexed target, bool allowed);
    event MinContributionSet(address indexed token, uint256 amount);
    event EthPoolSet(uint24 fee, int24 tickSpacing);

    error InvalidVaultSalt();
    error InvalidAddress();
    error InvalidPool();

    constructor(
        IMiyaRegistry registry_,
        IPoolManager poolManager_,
        address zRouter_,
        address infer_,
        address imd_,
        PoolKey memory alignmentPoolKey_
    ) {
        if (
            address(registry_) == address(0) || address(poolManager_) == address(0) || zRouter_ == address(0)
                || infer_ == address(0) || imd_ == address(0)
        ) revert InvalidAddress();
        _initializeOwner(msg.sender);
        registry = registry_;
        poolManager = poolManager_;
        zRouter = zRouter_;
        infer = infer_;
        imd = imd_;
        _poolKey = alignmentPoolKey_;
        UniAlignmentVault implementation = new UniAlignmentVault();
        implementation.disableInitializer();
        vaultImplementation = address(implementation);
    }

    // ── vault config ────────────────────────────────────────────────────────

    /// @notice Allow or remove a contract the keeper's conversion calldata may call (0x AllowanceHolder
    ///         0x0000000000001fF3684f28c67538d4D072C22734, zRouter). The vault approves it for exactly each swap's amount
    ///         in and resets the approval after, so only a router that can't be told to spend the vault's other balances
    ///         belongs here: never a token, the PoolManager, the registry, or an EOA (refused).
    function setSwapTarget(address target, bool allowed) external onlyOwner {
        if (
            allowed
                && (target.code.length == 0 || target == infer || target == imd || target == address(poolManager)
                    || target == address(registry) || target == address(this))
        ) revert InvalidAddress();
        isSwapTarget[target] = allowed;
        emit SwapTargetSet(target, allowed);
    }

    /// @notice Least amount of `token` one contribution may carry (0 = none), so dust can't be spammed. ERC-20s only:
    ///         ETH contributions have the vault's fixed MIN_CONTRIBUTION.
    function setMinContribution(address token, uint256 amount) external onlyOwner {
        if (token == ETH) revert InvalidAddress();
        minContribution[token] = amount;
        emit MinContributionSet(token, amount);
    }

    /// @notice The hookless native-ETH/IMD v4 pool ETH-mode claims sell IMD into (default 10000 / 200, mainnet).
    function setEthPool(uint24 fee, int24 tickSpacing) external onlyOwner {
        if (fee >= 1_000_000 || tickSpacing <= 0) revert InvalidPool(); // static fee, a real spacing
        (_ethPoolFee, _ethPoolTickSpacing) = (fee, tickSpacing);
        emit EthPoolSet(fee, tickSpacing);
    }

    /// @inheritdoc IVaultConfig
    function ethPool() external view returns (uint24 fee, int24 tickSpacing) {
        return (_ethPoolFee, _ethPoolTickSpacing);
    }

    function alignmentPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    // ── vaults ──────────────────────────────────────────────────────────────

    /// @notice Deploy a vault clone via CREATE3, bound to `alignmentTargetId` (active, containing INFER).
    // slither-disable-next-line reentrancy-events
    function deployVault(bytes32 salt, uint256 alignmentTargetId) external onlyOwner returns (address vault) {
        _requireFactorySalt(salt);
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", vaultImplementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
        vault = ICreateX(CREATEX).deployCreate3(salt, proxyCreationCode);
        UniAlignmentVault(payable(vault)).initialize(
            address(this), poolManager, zRouter, registry, IVaultConfig(address(this)), infer, imd, _poolKey,
            alignmentTargetId
        );
        registry.registerVault(vault);
        emit VaultDeployed(vault, alignmentTargetId);
    }

    /// @notice Preview the deterministic address for a given salt
    function computeVaultAddress(bytes32 salt) external view returns (address) {
        _requireFactorySalt(salt);
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }

    /// @dev CreateX only binds a salt to its sender when it starts with that sender and a 0x00 byte. Any other salt could
    ///      be claimed by anyone first, and would land somewhere other than computeVaultAddress says.
    function _requireFactorySalt(bytes32 salt) private view {
        if (bytes20(salt) != bytes20(address(this)) || salt[20] != 0x00) revert InvalidVaultSalt();
    }
}
