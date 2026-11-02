// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";

/// @notice Test-only vault that overrides LP with mock behavior.
/// @dev Swap behavior is handled by MockZRouter injected at initialize().
///      Only _addToLpPosition is overridden here since it requires a real V4 pool.
contract TestableUniAlignmentVault is UniAlignmentVault {
    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal override returns (uint128 liquidityUnits) {
        require(amount0 > 0 && amount1 > 0, "Amounts must be positive");
        lastTickLower = tickLower;
        lastTickUpper = tickUpper;
        liquidityUnits = uint128((amount0 + amount1) / 2);
    }

    /// @notice Simulate protocol fee accrual for testing withdrawProtocolFees happy path.
    function simulateProtocolFeeAccrual(uint256 amount) external payable {
        require(msg.value == amount, "Must send exact ETH");
        accumulatedProtocolFees += amount;
    }
}
