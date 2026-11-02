// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockBenefactorStaking
 * @notice Mock Phase 2 benefactor distribution module for testing
 * @dev Simulates benefactor staking system without actual token transfers
 *      Used to test that Phase 2 can be swapped in without touching vault
 */
contract MockBenefactorStaking {
    address public vault;

    // Staking data
    mapping(address => uint256) public benefactorStakes; // benefactor => amount staked
    address[] public benefactors;
    uint256 public totalStaked;

    // Fee distribution
    uint256 public totalFeesReceived;
    uint256 public totalFeesClaimed;
    mapping(address => uint256) public feesClaimable;
    uint256 public callCount;

    event BenefactorStaked(address indexed benefactor, uint256 amount);
    event BenefactorUnstaked(address indexed benefactor, uint256 amount);
    event FeesClaimed(address indexed benefactor, uint256 amount);
    event FeesReceived(uint256 amount, uint256 totalReceived);

    constructor(address _vault) {
        vault = _vault;
    }

    /**
     * @notice Called by vault when fees accumulate (Phase 2)
     */
    function onFeeAccumulated(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        require(amount > 0, "Amount must be positive");

        totalFeesReceived += amount;
        callCount++;

        // Distribute fees proportionally to stakers (simplified)
        if (totalStaked > 0) {
            uint256 feesPerStaker = amount / benefactors.length;
            for (uint256 i = 0; i < benefactors.length; i++) {
                uint256 stake = benefactorStakes[benefactors[i]];
                if (stake > 0) {
                    uint256 share = (amount * stake) / totalStaked;
                    feesClaimable[benefactors[i]] += share;
                }
            }
        }

        emit FeesReceived(amount, totalFeesReceived);
    }

    /**
     * @notice Benefactor stakes tokens
     */
    function stake(uint256 amount) external {
        require(amount > 0, "Amount must be positive");

        if (benefactorStakes[msg.sender] == 0) {
            benefactors.push(msg.sender);
        }

        benefactorStakes[msg.sender] += amount;
        totalStaked += amount;

        emit BenefactorStaked(msg.sender, amount);
    }

    /**
     * @notice Benefactor unstakes tokens
     */
    function unstake(uint256 amount) external {
        require(benefactorStakes[msg.sender] >= amount, "Insufficient stake");
        require(amount > 0, "Amount must be positive");

        benefactorStakes[msg.sender] -= amount;
        totalStaked -= amount;

        emit BenefactorUnstaked(msg.sender, amount);
    }

    /**
     * @notice Benefactor claims earned fees
     */
    function claimFees() external {
        uint256 claimable = feesClaimable[msg.sender];
        require(claimable > 0, "No fees to claim");

        feesClaimable[msg.sender] = 0;
        totalFeesClaimed += claimable;

        // In real implementation, transfer ETH here
        // For mock: just track it

        emit FeesClaimed(msg.sender, claimable);
    }

    // ========== Query Functions ==========

    /**
     * @notice Get total fees received
     */
    function getTotalFeesReceived() external view returns (uint256) {
        return totalFeesReceived;
    }

    /**
     * @notice Get number of onFeeAccumulated calls
     */
    function getCallCount() external view returns (uint256) {
        return callCount;
    }

    /**
     * @notice Get benefactor stake
     */
    function getBenefactorStake(address benefactor) external view returns (uint256) {
        return benefactorStakes[benefactor];
    }

    /**
     * @notice Get claimable fees for benefactor
     */
    function getClaimableFees(address benefactor) external view returns (uint256) {
        return feesClaimable[benefactor];
    }

    /**
     * @notice Get total staked
     */
    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }

    /**
     * @notice Get number of benefactors
     */
    function getBenefactorCount() external view returns (uint256) {
        return benefactors.length;
    }

    /**
     * @notice Get all benefactors
     */
    function getAllBenefactors() external view returns (address[] memory) {
        return benefactors;
    }

    /**
     * @notice Reset for testing
     */
    function reset() external {
        totalFeesReceived = 0;
        totalFeesClaimed = 0;
        callCount = 0;
        totalStaked = 0;
        for (uint256 i = 0; i < benefactors.length; i++) {
            feesClaimable[benefactors[i]] = 0;
            benefactorStakes[benefactors[i]] = 0;
        }
        delete benefactors;
    }
}
