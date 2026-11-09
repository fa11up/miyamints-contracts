// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice PoolManager stand-in for reads through StateLibrary (extsload): every slot reads `answer`, so any pool reads as
///         initialized (sqrtPriceX96 = the low 160 bits) with liquidity (the low 128 bits), or, with 0, as missing.
contract MockExtsloadPoolManager {
    bytes32 public answer;

    constructor(bytes32 answer_) {
        answer = answer_;
    }

    function setAnswer(bytes32 a) external {
        answer = a;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return answer;
    }
}
