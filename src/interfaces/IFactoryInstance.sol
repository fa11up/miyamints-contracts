// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFactoryInstance
/// @notice Minimal interface every factory-deployed instance must implement.
///         Vault, treasury and fee terms are fixed at launch.
interface IFactoryInstance {
    /// @notice Returns the vault address this instance is aligned to (fixed at launch)
    function vault() external view returns (address);

    /// @notice Returns the protocol treasury address for fee routing (snapshotted at launch)
    function protocolTreasury() external view returns (address);

    /// @notice Protocol fee in basis points, snapshotted from MiyaRegistry at launch
    function protocolFeeBps() external view returns (uint16);

    /// @notice Alignment vault share in basis points, chosen by the creator at launch
    function alignmentBps() external view returns (uint16);

    /// @notice Claim fees from this instance's vault
    function claimAllFees() external;
}
