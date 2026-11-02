// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAlignmentVault} from "../../src/interfaces/IAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Mock vault that always reverts on receiveContribution (Finding 2)
contract MockRevertingVault is IAlignmentVault {
    error VaultAlwaysReverts();

    function receiveContribution(Currency, uint256, address) external payable override {
        revert VaultAlwaysReverts();
    }

    receive() external payable override { revert VaultAlwaysReverts(); }

    function claimFees() external pure override returns (uint256) { return 0; }
    function claimFeesAsDelegate(address[] calldata) external pure override returns (uint256) { return 0; }
    function delegateBenefactor(address) external pure override {}
    function calculateClaimableAmount(address) external pure override returns (uint256) { return 0; }
    function getBenefactorShares(address) external pure override returns (uint256) { return 0; }
    function getBenefactorContribution(address) external pure override returns (uint256) { return 0; }
    function getBenefactorDelegate(address b) external pure override returns (address) { return b; }
    function totalShares() external pure override returns (uint256) { return 0; }
    function accumulatedFees() external pure override returns (uint256) { return 0; }
    function vaultType() external pure override returns (string memory) { return "RevertingVault"; }
    function description() external pure override returns (string memory) { return ""; }
    function supportsCapability(bytes32) external pure override returns (bool) { return false; }
    function currentPolicy() external pure override returns (bytes memory) { return ""; }
    function validateCompliance(address) external pure override returns (bool) { return true; }
}
