// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAlignmentVault, ClaimMode} from "../../src/interfaces/IAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Mock vault (v2 interface) that always reverts on contributions (Finding 2)
contract MockRevertingVault is IAlignmentVault {
    error VaultAlwaysReverts();

    function receiveContribution(Currency, uint256, address) external payable override {
        revert VaultAlwaysReverts();
    }

    receive() external payable override { revert VaultAlwaysReverts(); }

    function claimFees(ClaimMode, uint256) external pure override returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }
    function claimFeesAsDelegate(address[] calldata, ClaimMode, uint256)
        external
        pure
        override
        returns (uint256, uint256, uint256)
    {
        return (0, 0, 0);
    }
    function claimable(address) external pure override returns (uint256, uint256, uint256) { return (0, 0, 0); }
    function pendingOf(address, address) external pure override returns (uint256) { return 0; }
    function delegateBenefactor(address) external pure override {}
    function getBenefactorShares(address) external pure override returns (uint256) { return 0; }
    function getBenefactorDelegate(address b) external pure override returns (address) { return b; }
    function totalShares() external pure override returns (uint256) { return 0; }
    function vaultType() external pure override returns (string memory) { return "RevertingVault"; }
    function description() external pure override returns (string memory) { return ""; }
    function supportsCapability(bytes32) external pure override returns (bool) { return false; }
    function currentPolicy() external pure override returns (bytes memory) { return ""; }
    function validateCompliance(address) external pure override returns (bool) { return true; }
}
