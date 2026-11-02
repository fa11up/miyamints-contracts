// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlignmentVault} from "../../src/interfaces/IAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title MockVault
 * @notice Minimal IAlignmentVault implementation for testing
 * @dev This vault does NOTHING with the ETH except store it
 *      Perfect for testing factory/instance integration without complex yield logic
 *
 * Features:
 * - Accepts ETH via receiveContribution() and receive()
 * - Tracks benefactor contributions
 * - Issues shares 1:1 with ETH (no yield generation)
 * - Allows fee claims (just returns stored ETH)
 * - No V4 pools, no swaps, no complexity
 *
 * Usage:
 * ```solidity
 * MockVault vault = new MockVault();
 * vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, benefactor);
 * uint256 claimable = vault.calculateClaimableAmount(benefactor); // Returns 1 ether
 * uint256 claimed = vault.claimFees(); // Transfers 1 ether to benefactor
 * ```
 */
contract MockVault is IAlignmentVault {
    // ========== State Variables ==========

    // Track total ETH contributed per benefactor (for bragging rights)
    mapping(address => uint256) public benefactorTotalETH;

    // Track shares issued to benefactors (1:1 with ETH)
    // Note: Public mapping automatically creates a getter that satisfies IAlignmentVault.getBenefactorShares()
    mapping(address => uint256) public benefactorShares;

    // Track last claim state for multi-claim support
    mapping(address => uint256) public shareValueAtLastClaim;
    mapping(address => uint256) public lastClaimTimestamp;

    // Global state
    uint256 public override totalShares;
    uint256 public override accumulatedFees;

    // ========== Events ==========
    // (Inherited from IAlignmentVault interface)

    // ========== Fee Reception ==========

    /**
     * @notice Receive alignment taxes with explicit benefactor attribution
     * @dev Just stores the ETH and issues 1:1 shares
     * @param currency Currency of the tax (ignored, only ETH supported)
     * @param amount Amount of tax received
     * @param benefactor Address to credit for this contribution
     */
    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable override {
        require(msg.value >= amount, "Insufficient ETH sent");
        require(amount > 0, "Amount must be positive");
        require(benefactor != address(0), "Invalid benefactor");

        // Track contribution
        benefactorTotalETH[benefactor] += amount;

        // Issue shares 1:1 with ETH
        benefactorShares[benefactor] += amount;
        totalShares += amount;

        // All ETH becomes claimable fees immediately (no yield generation)
        accumulatedFees += amount;

        emit ContributionReceived(benefactor, amount);
        emit FeesAccumulated(amount);
    }

    /**
     * @notice Receive native ETH contributions via fallback
     * @dev Tracks msg.sender as benefactor
     */
    receive() external payable override {
        require(msg.value > 0, "Amount must be positive");

        address benefactor = msg.sender;

        // Track contribution
        benefactorTotalETH[benefactor] += msg.value;

        // Issue shares 1:1 with ETH
        benefactorShares[benefactor] += msg.value;
        totalShares += msg.value;

        // All ETH becomes claimable fees immediately
        accumulatedFees += msg.value;

        emit ContributionReceived(benefactor, msg.value);
        emit FeesAccumulated(msg.value);
    }

    // ========== Fee Claiming ==========

    /**
     * @notice Claim accumulated fees for caller
     * @dev Calculates proportional share and transfers ETH
     *      Mock vault has no "yield" - just returns contributed ETH
     *
     * @return ethClaimed Amount of ETH transferred to caller
     */
    function claimFees() external override returns (uint256 ethClaimed) {
        address benefactor = msg.sender;

        require(benefactorShares[benefactor] > 0, "No shares");
        require(accumulatedFees > 0, "No fees to claim");

        // Calculate current proportional share
        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;

        // Calculate unclaimed amount (delta since last claim)
        ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;

        require(ethClaimed > 0, "No new fees to claim");
        require(address(this).balance >= ethClaimed, "Insufficient ETH balance");

        // Deduct claimed amount from accumulated fees
        accumulatedFees -= ethClaimed;

        // Update claim state (new value after deduction)
        // After claiming, user has claimed up to the new accumulated fees level
        uint256 newShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;
        shareValueAtLastClaim[benefactor] = newShareValue;
        lastClaimTimestamp[benefactor] = block.timestamp;

        // Transfer ETH to benefactor
        (bool success, ) = payable(benefactor).call{value: ethClaimed}("");
        require(success, "ETH transfer failed");

        emit FeesClaimed(benefactor, ethClaimed);

        return ethClaimed;
    }

    /**
     * @notice Calculate claimable amount for benefactor without claiming
     * @param benefactor Address to query
     * @return Amount of ETH claimable by this benefactor (total, not delta)
     */
    function calculateClaimableAmount(address benefactor) external view override returns (uint256) {
        if (totalShares == 0 || accumulatedFees == 0) return 0;
        return (accumulatedFees * benefactorShares[benefactor]) / totalShares;
    }

    // ========== Share Queries ==========

    /**
     * @notice Get benefactor's total historical contribution
     * @param benefactor Address to query
     * @return Total ETH contributed by this benefactor (all-time)
     */
    function getBenefactorContribution(address benefactor) external view override returns (uint256) {
        return benefactorTotalETH[benefactor];
    }

    /**
     * @notice Get benefactor's current share balance
     * @dev In MockVault, shares are 1:1 with ETH contributed
     * @param benefactor Address to query
     * @return Share balance (equals ETH contributed)
     */
    function getBenefactorShares(address benefactor) external view override returns (uint256) {
        return benefactorShares[benefactor];
    }

    // ========== Vault Info ==========

    /**
     * @notice Get vault implementation type identifier
     * @return Vault type identifier
     */
    function vaultType() external pure override returns (string memory) {
        return "MockVault";
    }

    /**
     * @notice Get vault description for frontend display
     * @return Vault description
     */
    function description() external pure override returns (string memory) {
        return "Mock vault for testing - stores ETH without yield generation (testing only, do not use in production)";
    }

    /// @inheritdoc IAlignmentVault
    function supportsCapability(bytes32) external pure override returns (bool) {
        return false; // Mock vault has no real capabilities
    }

    /// @inheritdoc IAlignmentVault
    function currentPolicy() external pure override returns (bytes memory) {
        return ""; // No policy requirements
    }

    /// @inheritdoc IAlignmentVault
    function validateCompliance(address) external pure override returns (bool) {
        return true; // Always compliant
    }

    // ========== Benefactor Delegation ==========

    mapping(address => address) public benefactorDelegate;

    /// @inheritdoc IAlignmentVault
    function delegateBenefactor(address delegate) external override {
        benefactorDelegate[msg.sender] = delegate;
    }

    /// @inheritdoc IAlignmentVault
    function getBenefactorDelegate(address benefactor) external view override returns (address) {
        address delegate = benefactorDelegate[benefactor];
        return delegate == address(0) ? benefactor : delegate;
    }

    /// @inheritdoc IAlignmentVault
    function claimFeesAsDelegate(address[] calldata benefactors) external override returns (uint256 totalClaimed) {
        // Snapshot fees before iteration so all benefactors calculate against same base
        uint256 snapshotFees = accumulatedFees;

        for (uint256 i = 0; i < benefactors.length; i++) {
            address benefactor = benefactors[i];
            require(benefactorDelegate[benefactor] == msg.sender, "Not delegate");
            require(benefactorShares[benefactor] > 0, "No shares");

            if (snapshotFees == 0) continue;

            uint256 currentShareValue = (snapshotFees * benefactorShares[benefactor]) / totalShares;
            uint256 ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
                ? currentShareValue - shareValueAtLastClaim[benefactor]
                : 0;

            if (ethClaimed > 0) {
                totalClaimed += ethClaimed;
                emit FeesClaimed(benefactor, ethClaimed);
            }
        }

        require(totalClaimed > 0, "No fees to claim");
        accumulatedFees -= totalClaimed;

        // Update watermarks after deduction
        for (uint256 i = 0; i < benefactors.length; i++) {
            uint256 newShareValue = (accumulatedFees * benefactorShares[benefactors[i]]) / totalShares;
            shareValueAtLastClaim[benefactors[i]] = newShareValue;
            lastClaimTimestamp[benefactors[i]] = block.timestamp;
        }

        (bool success, ) = payable(msg.sender).call{value: totalClaimed}("");
        require(success, "ETH transfer failed");
    }

    // Note: accumulatedFees() and totalShares() are public state variables,
    // automatically implementing the interface getter requirements

    // ========== Testing Helpers ==========

    /**
     * @notice Get unclaimed fees for benefactor (delta since last claim)
     * @dev Not part of IAlignmentVault but useful for testing
     */
    function getUnclaimedFees(address benefactor) external view returns (uint256) {
        if (totalShares == 0 || accumulatedFees == 0) return 0;
        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;
        return currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;
    }

    /**
     * @notice Reset vault state (testing only)
     * @dev Allows reusing vault in multiple test cases
     */
    function reset() external {
        totalShares = 0;
        accumulatedFees = 0;
    }

    /**
     * @notice Simulate "yield generation" by adding fees
     * @dev In real vaults, fees come from LP/lending yield
     *      In MockVault, we manually add fees for testing
     */
    function simulateYield(uint256 amount) external payable {
        require(msg.value >= amount, "Must send ETH for simulated yield");
        accumulatedFees += amount;
        emit FeesAccumulated(amount);
    }
}
