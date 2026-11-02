// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @notice Testnet-only alignment token for DeployMiyamints on chains with no real target (Sepolia). Never used on
///         mainnet configs (deployMockAlignmentToken = false there). Fixed supply minted to the deployer.
contract TestAlignmentToken is ERC20 {
    constructor(address to, uint256 supply) {
        _mint(to, supply);
    }

    function name() public pure override returns (string memory) {
        return "miyamints Test Alignment";
    }

    function symbol() public pure override returns (string memory) {
        return "tMIYA";
    }
}
