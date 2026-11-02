// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal CreateX interface for CREATE3 deployments
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address);
    function computeCreate3Address(bytes32 salt) external view returns (address);
}

/// @dev CreateX canonical deployment address (same on all chains)
address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
