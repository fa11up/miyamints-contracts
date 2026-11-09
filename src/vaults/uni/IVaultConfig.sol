// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice One keeper-built swap the vault runs: a call to an allowlisted aggregator target (0x AllowanceHolder, or
///         zRouter as the fallback) that turns an exact amount of one token into ETH or IMD for the vault.
/// @param target Allowlisted in the vault factory (`isSwapTarget`); also the only address the vault approves, for
///        exactly the amount in, reset to 0 after the call.
/// @param tokenOut ETH (address(0)) or IMD. The ETH leg (the batch's one ETH -> IMD swap) must output IMD.
/// @param data Calldata for `target`, sent with value = the amount in when the input is ETH (else 0).
/// @param minOut The vault's balance of `tokenOut` must rise by at least this across the call; must be non-zero.
struct SwapCall {
    address target;
    address tokenOut;
    bytes data;
    uint256 minOut;
}

/// @notice What every vault reads live from its factory (owner = a Safe): the swap targets conversions may call, the
///         least an ERC-20 contribution may carry, and the IMD/ETH v4 pool ETH-mode claims swap through (via zRouter).
interface IVaultConfig {
    /// @notice True for contracts conversions may call (0x AllowanceHolder, zRouter). The keeper can't add any.
    function isSwapTarget(address target) external view returns (bool);

    /// @notice Least amount of `token` (an ERC-20) one contribution may carry; 0 = no minimum.
    function minContribution(address token) external view returns (uint256);

    /// @notice The hookless IMD/native-ETH v4 pool ETH-mode claims sell IMD into (through zRouter.swapV4).
    function ethPool() external view returns (uint24 fee, int24 tickSpacing);
}

/// @notice zRouter 0x000000000000FB114709235f1ccBFfb925F600e4 (Sourcify-verified source, mainnet). With
///         `exactOut = false`, `amountLimit` is the minimum out (0 = none) and `swapAmount = 0` means "all of msg.value"
///         for ETH in (or the router's own balance of the token). It pulls a non-ETH `tokenIn` from msg.sender, pays
///         `to`, and after an ETH-in swap refunds its whole ETH balance to msg.sender.
interface IzRouter {
    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}
