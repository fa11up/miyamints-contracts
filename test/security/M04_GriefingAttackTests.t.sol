// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/vaults/uni/UniAlignmentVault.sol";
import {TestableUniAlignmentVault} from "../helpers/TestableUniAlignmentVault.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import "../mocks/MockEXECToken.sol";

// ============ Griefing Attack Contracts ============

/**
 * @notice Malicious contract that always reverts on ETH receipt
 * @dev This is the griefing attack vector - revert to block operation
 */
contract GrieferAlwaysReverts {
    UniAlignmentVault public vault;

    constructor(UniAlignmentVault _vault) {
        vault = _vault;
    }

    function attemptConversion(uint256 minOut) external {
        // This will execute all the conversion work
        vault.convertAndAddLiquidity(minOut);
        // But our receive() will revert when reward is sent
    }

    receive() external payable {
        revert("Griefing attack: reject reward to block operation");
    }
}

/**
 * @notice Contract that conditionally reverts (griefs only sometimes)
 */
contract GrieferConditional {
    UniAlignmentVault public vault;
    bool public shouldGrief;

    constructor(UniAlignmentVault _vault) {
        vault = _vault;
    }

    function setGriefing(bool _grief) external {
        shouldGrief = _grief;
    }

    function attemptConversion(uint256 minOut) external {
        vault.convertAndAddLiquidity(minOut);
    }

    receive() external payable {
        if (shouldGrief) {
            revert("Conditional griefing attack");
        }
        // Otherwise accept payment
    }
}

/**
 * @notice Contract that runs out of gas when receiving (accidental griefing)
 */
contract GrieferOutOfGas {
    UniAlignmentVault public vault;

    constructor(UniAlignmentVault _vault) {
        vault = _vault;
    }

    function attemptConversion(uint256 minOut) external {
        vault.convertAndAddLiquidity(minOut);
    }

    receive() external payable {
        // Infinite loop consumes all gas
        while (true) {}
    }
}

/**
 * @notice Good caller contract that accepts payments
 */
contract GoodCaller {
    UniAlignmentVault public vault;

    constructor(UniAlignmentVault _vault) {
        vault = _vault;
    }

    function callConversion(uint256 minOut) external {
        vault.convertAndAddLiquidity(minOut);
    }

    receive() external payable {
        // Accept payment
    }
}

// ============ Main Test Contract ============

/**
 * @title M04_GriefingAttackTests
 * @notice Tests demonstrating M-04 security fix prevents griefing attacks
 * @dev Tests prove that malicious contracts cannot block incentivized functions
 *      by rejecting reward payments (pre-fix vulnerability)
 */
contract M04_GriefingAttackTests is Test {
    UniAlignmentVault public vault;
    MockEXECToken public alignmentToken;

    TestableUniAlignmentVault public vaultImpl;
    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockValidator;
    MiyaRegistry public alignmentRegistry;

    uint256 constant TARGET_ID = 0;

    address public owner;
    address public alice;
    address public mockPoolManager;
    address public mockWeth;

    // Events to test
    event ConversionRewardPaid(address indexed caller, uint256 reward);
    event ConversionRewardRejected(address indexed caller, uint256 rewardAmount);

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");

        // Deploy mock addresses (as EOAs - no code)
        mockPoolManager = makeAddr("poolManager");
        mockWeth = makeAddr("weth");

        // Deploy real ERC20 token for alignment token
        alignmentToken = new MockEXECToken(1000000e18);

        // Deploy mock alignment registry
        alignmentRegistry = new MiyaRegistry(address(this), address(0xFEE), 100, 1000);
        address[] memory targetTokens = new address[](1);
        targetTokens[0] = address(alignmentToken);
        alignmentRegistry.addTarget("Test target", targetTokens);

        // Deploy vault (using testable version with mock swap/LP overrides)
        mockZRouter = new MockZRouter();
        mockValidator = new MockVaultPriceValidator();
        vm.deal(address(mockZRouter), 100 ether);
        alignmentToken.transfer(address(mockZRouter), 100_000e18);

        vaultImpl = new TestableUniAlignmentVault();
        vault = TestableUniAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        vault.initialize(
            address(this),
            mockWeth,
            mockPoolManager,
            address(alignmentToken),
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockValidator)),
            IMiyaRegistry(address(alignmentRegistry)),
            TARGET_ID
        );

        // Set V4 pool key for conversion tests
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        // Fund vault for rewards
        vm.deal(address(vault), 100 ether);
    }

    // ============ Test: Griefing Attack Blocked ============

    function test_GriefingAttack_AlwaysReverts_OperationSucceeds() public {
        // Setup: Add pending ETH to vault (from alice)
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 5 ether}("");
        assertTrue(success, "Alice contribution failed");

        // Deploy griefing contract
        GrieferAlwaysReverts griefer = new GrieferAlwaysReverts(vault);

        // Record state before attack
        uint256 pendingBefore = vault.totalPendingETH();
        assertEq(pendingBefore, 5 ether, "Should have pending ETH");

        // Attack: Griefer tries to block conversion by rejecting reward
        // ✅ KEY TEST: This should NOT revert (pre-fix it would have reverted)
        griefer.attemptConversion(1);

        // ✅ VERIFY: Operation succeeded despite griefing attempt
        uint256 pendingAfter = vault.totalPendingETH();
        assertEq(pendingAfter, 0, "Conversion should succeed - pending ETH cleared");

        // ✅ VERIFY: Shares were issued (conversion completed)
        uint256 aliceShares = vault.benefactorShares(alice);
        assertGt(aliceShares, 0, "Alice should have shares - conversion completed");

        // ✅ VERIFY: Griefer got no reward (rejected payment)
        assertEq(address(griefer).balance, 0, "Griefer should have no reward");

        // ✅ VERIFY: Rejected reward is not stranded - it is distributed to the batch's benefactors
        assertApproxEqAbs(vault.getUnclaimedFees(alice), vault.CONVERSION_REWARD(), 1, "Rejected reward -> fees");
    }

    function test_GriefingAttack_ConditionalRevert_OperationSucceeds() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 3 ether}("");
        assertTrue(success);

        GrieferConditional griefer = new GrieferConditional(vault);

        // Enable griefing mode
        griefer.setGriefing(true);

        // Attack should fail to block operation
        griefer.attemptConversion(1);

        // Verify conversion completed
        assertEq(vault.totalPendingETH(), 0, "Conversion completed despite griefing");
        assertGt(vault.benefactorShares(alice), 0, "Shares issued");
    }

    function test_GriefingAttack_OutOfGas_OperationSucceeds() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success);

        GrieferOutOfGas griefer = new GrieferOutOfGas(vault);

        // Attack: Out of gas on receive (accidental griefing)
        griefer.attemptConversion(1);

        // Verify operation succeeded
        assertEq(vault.totalPendingETH(), 0, "Conversion completed");
    }

    // ============ Test: Legitimate Callers Get Paid ============

    function test_LegitimateEOA_ReceivesReward() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 5 ether}("");
        assertTrue(s1);

        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);

        // Record balance before
        uint256 balanceBefore = caller.balance;

        // Legitimate call - should receive reward
        vm.prank(caller);
        vault.convertAndAddLiquidity(1);

        // Verify caller received reward
        uint256 balanceAfter = caller.balance;
        assertGt(balanceAfter, balanceBefore, "Caller should receive reward");

        // Flat reward, no gas component
        uint256 rewardReceived = balanceAfter - balanceBefore;
        assertEq(rewardReceived, 0.0012 ether, "Should receive exactly the flat reward");
    }

    function test_LegitimateContract_ReceivesReward() public {
        // Setup
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 5 ether}("");
        assertTrue(s1);

        // Deploy contract that accepts payment
        GoodCaller goodCaller = new GoodCaller(vault);

        // Record balance
        uint256 balanceBefore = address(goodCaller).balance;

        // Legitimate call
        goodCaller.callConversion(1);

        // Verify reward received
        assertGt(address(goodCaller).balance, balanceBefore, "Good caller should receive reward");
    }

    // ============ Test: Reward Funded From The Batch (audit H3) ============

    function test_RewardPaidFromBatch_NoExtraBalanceNeeded() public {
        // Fresh vault holding ONLY the pending contribution: no fee balance, no extra funding.
        MockZRouter poorZRouter = new MockZRouter();
        MockVaultPriceValidator poorValidator = new MockVaultPriceValidator();
        alignmentToken.transfer(address(poorZRouter), 100_000e18);

        UniAlignmentVault poorVault = TestableUniAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        poorVault.initialize(
            address(this),
            mockWeth,
            mockPoolManager,
            address(alignmentToken),
            address(poorZRouter),
            3000,
            60,
            IVaultPriceValidator(address(poorValidator)),
            IMiyaRegistry(address(alignmentRegistry)),
            TARGET_ID
        );

        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poorVault.setV4PoolKey(mockPoolKey);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(poorVault).call{value: 5 ether}("");
        assertTrue(s1);

        address caller = makeAddr("poorCaller");
        vm.prank(caller);
        poorVault.convertAndAddLiquidity(1);

        assertEq(poorVault.totalPendingETH(), 0, "Conversion completed");
        assertGt(poorVault.benefactorShares(alice), 0, "Shares issued");
        assertEq(caller.balance, 0.0012 ether, "Reward carved out of the batch");
        assertEq(poorVault.totalEthLocked(), 5 ether - 0.0012 ether, "Only the remainder is converted");
    }

    // ============ Test: Reward Calculation (audit H3) ============

    function test_Reward_IgnoresGasPrice() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 3 ether}("");
        assertTrue(s1);

        address caller = makeAddr("rewardTester");
        vm.txGasPrice(10_000 gwei);
        vm.prank(caller);
        vault.convertAndAddLiquidity(1);

        assertEq(caller.balance, vault.CONVERSION_REWARD(), "Reward independent of tx.gasprice");
    }

    function test_Reward_CappedAtOnePercentOfBatch() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 0.01 ether}("");
        assertTrue(s1);

        address caller = makeAddr("smallBatchCaller");
        vm.prank(caller);
        vault.convertAndAddLiquidity(1);

        assertEq(caller.balance, 0.0001 ether, "Reward capped at 1% of a small batch");
    }
}
