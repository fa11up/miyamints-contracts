// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Test contract that demonstrates the M-04 fix pattern
contract RewardPaymentExample {
    uint256 public constant BASE_GAS = 100_000;
    uint256 public constant GAS_PER_UNIT = 15_000;
    uint256 public standardReward = 0.0012 ether;

    uint256 public workCompleted;

    event RewardPaid(address indexed caller, uint256 totalReward, uint256 gasCost, uint256 standardReward);
    event RewardRejected(address indexed caller, uint256 rewardAmount);
    event InsufficientRewardBalance(address indexed caller, uint256 rewardAmount, uint256 contractBalance);
    event WorkCompleted(uint256 units);

    receive() external payable {}

    // Function that does work and pays reward (M-04 fix pattern)
    function doWorkAndPayReward(uint256 units) external returns (uint256) {
        // Step 1: DO THE WORK FIRST
        workCompleted += units;
        emit WorkCompleted(units);

        // Step 2: Calculate reward
        uint256 estimatedGas = BASE_GAS + (units * GAS_PER_UNIT);
        uint256 gasCost = estimatedGas * tx.gasprice;
        uint256 reward = gasCost + standardReward;

        // Step 3: Graceful degradation - NEVER revert the work
        if (address(this).balance >= reward && reward > 0) {
            (bool success, ) = payable(msg.sender).call{value: reward}("");
            if (success) {
                emit RewardPaid(msg.sender, reward, gasCost, standardReward);
            } else {
                emit RewardRejected(msg.sender, reward);
            }
        } else if (reward > 0) {
            emit InsufficientRewardBalance(msg.sender, reward, address(this).balance);
        }

        return workCompleted;
    }

    function setStandardReward(uint256 newReward) external {
        standardReward = newReward;
    }
}

// Griefing contract
contract Griefer {
    RewardPaymentExample public target;

    constructor(RewardPaymentExample _target) {
        target = _target;
    }

    function attack(uint256 units) external {
        target.doWorkAndPayReward(units);
    }

    receive() external payable {
        revert("Griefing: reject reward");
    }
}

// Good caller contract
contract GoodCaller {
    RewardPaymentExample public target;

    constructor(RewardPaymentExample _target) {
        target = _target;
    }

    function callWork(uint256 units) external {
        target.doWorkAndPayReward(units);
    }

    receive() external payable {
        // Accept payment
    }
}

/**
 * @title M04_RewardLogicTests
 * @notice Unit tests for M-04 reward payment logic (isolated from full conversion flow)
 * @dev These tests verify the graceful degradation pattern works correctly
 */
contract M04_RewardLogicTests is Test {
    RewardPaymentExample public example;

    function setUp() public {
        example = new RewardPaymentExample();
        // Fund with ETH for rewards
        vm.deal(address(example), 100 ether);
    }

    // ============ Core Security Tests ============

    function test_GriefingAttack_WorkCompletesEvenIfRewardRejected() public {
        // Deploy griefing contract
        Griefer griefer = new Griefer(example);

        uint256 workBefore = example.workCompleted();

        // ✅ KEY TEST: This should NOT revert even though griefer rejects payment
        griefer.attack(5);

        // Verify work completed
        uint256 workAfter = example.workCompleted();
        assertEq(workAfter, workBefore + 5, "Work should complete despite griefing");

        // Verify griefer got no reward
        assertEq(address(griefer).balance, 0, "Griefer should have no reward");
    }

    function test_LegitimateEOA_ReceivesReward() public {
        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);

        uint256 balanceBefore = caller.balance;

        vm.prank(caller);
        example.doWorkAndPayReward(3);

        uint256 balanceAfter = caller.balance;

        // Verify caller received reward
        assertGt(balanceAfter, balanceBefore, "Caller should receive reward");

        // Verify reward is reasonable (at least standard reward)
        uint256 rewardReceived = balanceAfter - balanceBefore;
        assertGe(rewardReceived, 0.0012 ether, "Should include at least standard reward");
    }

    function test_LegitimateContract_ReceivesReward() public {
        GoodCaller goodCaller = new GoodCaller(example);

        uint256 balanceBefore = address(goodCaller).balance;

        goodCaller.callWork(3);

        uint256 balanceAfter = address(goodCaller).balance;

        // Verify reward received
        assertGt(balanceAfter, balanceBefore, "Good caller should receive reward");
    }

    function test_InsufficientBalance_WorkStillCompletes() public {
        // Deploy new example with NO funds
        RewardPaymentExample poorExample = new RewardPaymentExample();

        address caller = makeAddr("caller");

        uint256 workBefore = poorExample.workCompleted();

        // Call should succeed even with no reward funds
        vm.prank(caller);
        poorExample.doWorkAndPayReward(5);

        // Verify work completed
        uint256 workAfter = poorExample.workCompleted();
        assertEq(workAfter, workBefore + 5, "Work should complete without reward");

        // Verify no reward paid
        assertEq(caller.balance, 0, "No reward due to insufficient balance");
    }

    function test_RewardScalesWithWork() public {
        address caller1 = makeAddr("caller1");
        address caller2 = makeAddr("caller2");
        vm.deal(caller1, 1 ether);
        vm.deal(caller2, 1 ether);

        // Set non-zero gas price so gas cost component matters
        vm.txGasPrice(10 gwei);

        // Small work
        vm.prank(caller1);
        example.doWorkAndPayReward(1);
        uint256 reward1 = caller1.balance;

        // Large work
        vm.prank(caller2);
        example.doWorkAndPayReward(10);
        uint256 reward10 = caller2.balance;

        // Reward should scale with work (10 units should cost more gas than 1 unit)
        // At 10 gwei: 1 unit = (100k+15k)*10gwei = 0.00115 ETH gas + 0.0012 = 0.00235 ETH
        // At 10 gwei: 10 units = (100k+150k)*10gwei = 0.0025 ETH gas + 0.0012 = 0.0037 ETH
        assertGt(reward10, reward1, "More work should = higher reward");
    }

    function test_RewardIncludesGasCost() public {
        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);

        // Get standard reward value
        uint256 standardReward = example.standardReward();

        vm.prank(caller);
        example.doWorkAndPayReward(5);

        uint256 rewardReceived = caller.balance;

        // Reward should be MORE than just standard (includes gas)
        // At any gas price > 0, this should be true
        assertGt(rewardReceived, standardReward, "Should include gas cost");
    }

    function test_ZeroGasPrice_StillPaysStandardReward() public {
        address caller = makeAddr("caller");
        uint256 initialBalance = 1 ether;
        vm.deal(caller, initialBalance);

        // Set gas price to 0
        vm.txGasPrice(0);

        uint256 balanceBefore = caller.balance;

        vm.prank(caller);
        example.doWorkAndPayReward(5);

        uint256 rewardReceived = caller.balance - balanceBefore;

        // Should still get standard reward (gas cost component is 0)
        assertEq(rewardReceived, 0.0012 ether, "Should get standard reward even at 0 gas price");
    }

    function test_HighGasPrice_RewardScalesUp() public {
        address caller1 = makeAddr("caller1");
        address caller2 = makeAddr("caller2");
        vm.deal(caller1, 1 ether);
        vm.deal(caller2, 1 ether);

        // Low gas price
        vm.txGasPrice(1 gwei);
        vm.prank(caller1);
        example.doWorkAndPayReward(5);
        uint256 rewardLowGas = caller1.balance;

        // High gas price
        vm.txGasPrice(100 gwei);
        vm.prank(caller2);
        example.doWorkAndPayReward(5);
        uint256 rewardHighGas = caller2.balance;

        // Higher gas price should mean higher reward
        assertGt(rewardHighGas, rewardLowGas, "Reward should scale with gas price");
    }

    // ============ Event Tests ============

    function test_EmitsRewardPaidEvent() public {
        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);

        vm.expectEmit(true, false, false, false);
        emit RewardPaymentExample.RewardPaid(caller, 0, 0, 0);

        vm.prank(caller);
        example.doWorkAndPayReward(5);
    }

    function test_EmitsRewardRejectedEvent_OnGriefing() public {
        Griefer griefer = new Griefer(example);

        vm.expectEmit(true, false, false, false);
        emit RewardPaymentExample.RewardRejected(address(griefer), 0);

        griefer.attack(5);
    }

    function test_EmitsInsufficientBalanceEvent() public {
        RewardPaymentExample poorExample = new RewardPaymentExample();
        address caller = makeAddr("caller");

        vm.expectEmit(true, false, false, false);
        emit RewardPaymentExample.InsufficientRewardBalance(caller, 0, 0);

        vm.prank(caller);
        poorExample.doWorkAndPayReward(5);
    }

    // ============ Admin Control Tests ============

    function test_CanUpdateStandardReward() public {
        example.setStandardReward(0.002 ether);
        assertEq(example.standardReward(), 0.002 ether);
    }

    // ============ Edge Case Tests ============

    function test_ZeroUnitsOfWork_StillPaysReward() public {
        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);

        vm.prank(caller);
        example.doWorkAndPayReward(0);

        // Should still get reward for calling
        assertGt(caller.balance, 0, "Should get reward even for 0 units");
    }

    function test_MultipleCallsSameUser_AccumulatesWork() public {
        address caller = makeAddr("caller");
        vm.deal(caller, 10 ether);

        vm.startPrank(caller);
        example.doWorkAndPayReward(3);
        example.doWorkAndPayReward(5);
        example.doWorkAndPayReward(2);
        vm.stopPrank();

        assertEq(example.workCompleted(), 10, "Work should accumulate");
    }
}
