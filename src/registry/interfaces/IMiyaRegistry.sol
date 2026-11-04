// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMiyaRegistry
/// @notice The one protocol registry miyamaker contracts read from. It replaces ms2fun's master, component,
///         alignment, vault and global-message registries and its upgradeable treasury.
interface IMiyaRegistry {
    // ── fees ────────────────────────────────────────────────────────────────
    /// @notice Where protocol fees go (the imdUSD treasury on mainnet).
    function treasury() external view returns (address);
    function conversionKeeper() external view returns (address);

    /// @notice Protocol fee in basis points, snapshotted by each collection at launch.
    function protocolFeeBps() external view returns (uint16);

    /// @notice Lowest alignment share, in basis points, a collection may choose at launch.
    function minAlignmentBps() external view returns (uint16);

    /// @notice Reverts unless `alignmentBps` is valid for a collection launching now.
    function checkAlignmentBps(uint16 alignmentBps) external view;

    // ── alignment targets ───────────────────────────────────────────────────
    function isAlignmentTargetActive(uint256 targetId) external view returns (bool);

    function isTokenInTarget(uint256 targetId, address token) external view returns (bool);

    // ── components and factories ────────────────────────────────────────────
    function isApprovedComponent(address component) external view returns (bool);

    function isFactoryRegistered(address factory) external view returns (bool);

    // ── vaults ──────────────────────────────────────────────────────────────
    /// @notice True if `vault` was deployed by a registered vault factory.
    function isVault(address vault) external view returns (bool);

    /// @notice Called by a registered vault factory when it deploys a vault.
    function registerVault(address vault) external;

    // ── collections ─────────────────────────────────────────────────────────
    /// @notice Called by a registered factory when it deploys a collection.
    function registerInstance(address instance, address vault, address creator) external;

    function vaultOf(address instance) external view returns (address);

    function factoryOf(address instance) external view returns (address);
}
