// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A price in one payment token. address(0) = ETH. Units are the token's own (wei, USDC 6 decimals, ...).
struct TokenPrice {
    address token;
    uint256 price;
}
