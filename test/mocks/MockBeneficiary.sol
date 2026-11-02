// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockBeneficiary
 * @notice Mock beneficiary module for testing Phase 2 integration
 * @dev Simple mock that tracks when fees are received
 */
contract MockBeneficiary {
    address public vault;
    uint256 public totalFeesReceived;
    uint256 public callCount;

    event FeesReceived(uint256 amount, uint256 totalReceived);

    constructor(address _vault) {
        vault = _vault;
    }

    /**
     * @notice Called by vault when fees accumulate
     */
    function onFeeAccumulated(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        require(amount > 0, "Amount must be positive");

        totalFeesReceived += amount;
        callCount++;

        emit FeesReceived(amount, totalFeesReceived);
    }

    /**
     * @notice Get total fees received
     */
    function getTotalFeesReceived() external view returns (uint256) {
        return totalFeesReceived;
    }

    /**
     * @notice Get number of calls
     */
    function getCallCount() external view returns (uint256) {
        return callCount;
    }

    /**
     * @notice Reset for testing
     */
    function reset() external {
        totalFeesReceived = 0;
        callCount = 0;
    }
}
