// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

/// @notice A hookless INFER/IMD-shaped alignment pool key for tests that deploy vault v2 without a pool
///         (contributions only; conversions need TestableUniAlignmentVault or a mainnet fork).
function testAlignmentKey(address infer, address imd) pure returns (PoolKey memory) {
    (address a, address b) = infer < imd ? (infer, imd) : (imd, infer);
    return PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(address(0)));
}
