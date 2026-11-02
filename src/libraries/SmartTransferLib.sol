// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IWETHMinimal {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title SmartTransferLib
/// @notice ETH transfer with WETH fallback for smart contract wallet compatibility.
/// @dev When a direct ETH transfer fails (e.g., EIP-7702 wallets, Safe, Coinbase Smart Wallet),
///      the library wraps the ETH as WETH and sends it as an ERC20 instead.
///      Reverts only if both the ETH transfer AND the WETH fallback fail.
library SmartTransferLib {
    /// @dev Emitted when the direct ETH transfer fails and WETH is sent instead.
    event ETHTransferFallbackToWETH(address indexed to, uint256 amount);

    /// @dev Reverts when both ETH transfer and WETH fallback fail.
    error SmartTransferFailed(address to, uint256 amount);

    /// @notice Transfer ETH to `to`, falling back to WETH if the direct transfer fails.
    /// @param to     Recipient address.
    /// @param amount Amount of ETH (in wei) to transfer.
    /// @param weth   Address of the canonical WETH contract on this chain.
    function smartTransferETH(address to, uint256 amount, address weth) internal {
        if (amount == 0) return;

        // Try direct ETH transfer — forwards all remaining gas.
        if (SafeTransferLib.trySafeTransferETH(to, amount, gasleft())) return;

        // Fallback: wrap as WETH and send as ERC20.
        IWETHMinimal(weth).deposit{value: amount}();
        if (!IWETHMinimal(weth).transfer(to, amount)) {
            revert SmartTransferFailed(to, amount);
        }

        emit ETHTransferFallbackToWETH(to, amount);
    }
}
