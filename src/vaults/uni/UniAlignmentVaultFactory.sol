// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniAlignmentVault} from "./UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../interfaces/IVaultPriceValidator.sol";
import {IMiyaRegistry} from "../../registry/interfaces/IMiyaRegistry.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title UniAlignmentVaultFactory
/// @notice Deploys UniAlignmentVault clones and registers each in the MiyaRegistry (this factory must be
///         registered there via setVaultFactory); zRouter config is shared across all vaults.
///         The factory owns every vault it deploys and sets its V4 pool key exactly once, at deploy: the hookless
///         native-ETH/alignment-token pool at the shared zRouter fee tier, i.e. the same pool zRouter swaps on.
///         There is no way to repoint a vault's pool afterwards.
contract UniAlignmentVaultFactory is Ownable {
    address public immutable vaultImplementation;
    IVaultPriceValidator public immutable defaultPriceValidator;
    IMiyaRegistry public immutable registry;

    address public immutable weth;
    address public immutable poolManager;
    address public immutable zRouter;
    uint24  public immutable zRouterFee;
    int24   public immutable zRouterTickSpacing;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    error InvalidVaultSalt();

    constructor(
        // slither-disable-next-line missing-zero-check
        address _weth,
        // slither-disable-next-line missing-zero-check
        address _poolManager,
        // slither-disable-next-line missing-zero-check
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _defaultPriceValidator,
        IMiyaRegistry _registry
    ) {
        _initializeOwner(msg.sender);
        weth = _weth;
        poolManager = _poolManager;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        defaultPriceValidator = _defaultPriceValidator;
        registry = _registry;
        UniAlignmentVault implementation = new UniAlignmentVault();
        implementation.disableInitializer();
        vaultImplementation = address(implementation);
    }

    /// @notice Deploy a new vault clone via CREATE3
    /// @param salt CREATE3 deployment salt for deterministic vanity address
    /// @param alignmentToken The token this vault aligns to
    /// @param alignmentTargetId The alignment target this vault is bound to
    /// @param priceValidator Custom price validator; uses defaultPriceValidator if address(0)
    /// @return vault Address of the deployed vault clone
    // slither-disable-next-line reentrancy-events
    function deployVault(
        bytes32 salt,
        address alignmentToken,
        uint256 alignmentTargetId,
        IVaultPriceValidator priceValidator
    ) external onlyOwner returns (address vault) {
        _requireFactorySalt(salt);
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            vaultImplementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        vault = ICreateX(CREATEX).deployCreate3(salt, proxyCreationCode);

        UniAlignmentVault(payable(vault)).initialize(
            address(this),
            weth,
            poolManager,
            alignmentToken,
            zRouter,
            zRouterFee,
            zRouterTickSpacing,
            priceValidator == IVaultPriceValidator(address(0)) ? defaultPriceValidator : priceValidator,
            registry,
            alignmentTargetId
        );
        UniAlignmentVault(payable(vault)).setV4PoolKey(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(alignmentToken),
                fee: zRouterFee,
                tickSpacing: zRouterTickSpacing,
                hooks: IHooks(address(0))
            })
        );
        registry.registerVault(vault);

        emit VaultDeployed(vault, alignmentToken);
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
