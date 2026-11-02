// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultPriceValidator {
    /// @notice Validate cross-DEX price deviation and pool liquidity depth.
    /// @dev Reverts if manipulation is detected or liquidity is insufficient.
    ///      Returns silently if price is healthy.
    /// @param token Alignment token address to validate price for
    /// @param pendingETH Total ETH about to be swapped (for liquidity depth check)
    function validatePrice(address token, uint256 pendingETH) external view;

    /// @notice Calculate the proportion of ETH to swap vs. hold for LP.
    /// @dev Returns 5e17 (50%) for full-range positions or when no position exists.
    ///      For concentrated positions, returns tick-weighted ratio.
    /// @param token Alignment token address
    /// @param tickLower Vault's current LP position lower tick
    /// @param tickUpper Vault's current LP position upper tick
    /// @param poolManager V4 PoolManager address
    /// @param poolId V4 pool identifier (keccak256 of PoolKey)
    /// @return proportionToSwap 1e18-scaled value (5e17 = 50%, 1e18 = 100%)
    function calculateSwapProportion(
        address token,
        int24 tickLower,
        int24 tickUpper,
        address poolManager,
        bytes32 poolId
    ) external view returns (uint256 proportionToSwap);

    /// @notice Quote the expected ETH output for selling `tokenAmount` alignment tokens.
    /// @dev Uses TWAP price where available. Returns 0 if no reliable price source exists,
    ///      in which case callers should apply no slippage bound rather than reverting.
    /// @param token Alignment token address
    /// @param tokenAmount Amount of tokens to sell
    /// @return ethAmount Expected ETH output at TWAP price (no slippage deduction applied)
    function quoteEthForTokens(address token, uint256 tokenAmount) external view returns (uint256 ethAmount);
}
