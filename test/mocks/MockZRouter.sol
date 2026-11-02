// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock zRouter for unit testing ZAMMAlignmentVault
/// Handles both swap directions:
///   ETH  → token: receives ETH as msg.value, sends tokenOut to `to`
///   token → ETH:  pulls tokenIn from caller, sends ETH to `to`
contract MockZRouter {
    // Output amount = swapAmount * outRatio / 1e18 (default 1:1)
    uint256 public outRatio = 1e18;

    receive() external payable {}

    function setOutRatio(uint256 ratio) external { outRatio = ratio; }
    // Keep old name as alias for backwards compat with tests that call setEthOutRatio
    function setEthOutRatio(uint256 ratio) external { outRatio = ratio; }

    /// @notice Simulates swapV4: same bidirectional logic as swapVZ
    function swapV4(
        address to,
        bool /*exactOut*/,
        uint24 /*swapFee*/,
        int24 /*tickSpace*/,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 /*deadline*/
    ) external payable returns (uint256 amountIn, uint256 amountOut) {
        amountIn = swapAmount;
        amountOut = swapAmount * outRatio / 1e18;

        require(amountOut >= amountLimit, "MockZRouter: insufficient output");

        if (tokenIn == address(0)) {
            // ETH → token
            require(tokenOut != address(0), "MockZRouter: tokenOut must be token");
            IERC20(tokenOut).transfer(to, amountOut);
        } else {
            // token → ETH
            IERC20(tokenIn).transferFrom(msg.sender, address(this), swapAmount);
            require(address(this).balance >= amountOut, "MockZRouter: insufficient ETH");
            payable(to).transfer(amountOut);
        }
    }

    function swapVZ(
        address to,
        bool /*exactOut*/,
        uint256 /*feeOrHook*/,
        address tokenIn,
        address tokenOut,
        uint256 /*idIn*/,
        uint256 /*idOut*/,
        uint256 swapAmount,
        uint256 /*amountLimit*/,
        uint256 /*deadline*/
    ) external payable returns (uint256 amountIn, uint256 amountOut) {
        amountIn = swapAmount;
        amountOut = swapAmount * outRatio / 1e18;

        if (tokenIn == address(0)) {
            // ETH → token: ETH arrives as msg.value, send tokenOut to recipient
            require(tokenOut != address(0), "MockZRouter: tokenOut must be token");
            IERC20(tokenOut).transfer(to, amountOut);
        } else {
            // token → ETH: pull tokenIn, send ETH to recipient
            IERC20(tokenIn).transferFrom(msg.sender, address(this), swapAmount);
            require(address(this).balance >= amountOut, "MockZRouter: insufficient ETH");
            payable(to).transfer(amountOut);
        }
    }
}
