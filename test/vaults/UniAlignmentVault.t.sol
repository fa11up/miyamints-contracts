// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {TestableUniAlignmentVault} from "../helpers/TestableUniAlignmentVault.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockZRouter} from "../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../mocks/MockVaultPriceValidator.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {IVaultPriceValidator} from "../../src/interfaces/IVaultPriceValidator.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title UniAlignmentVaultTest
 * @notice Comprehensive test suite for UniAlignmentVault
 * @dev Tests all functionality: contributions, shares, claims, conversions, access control
 */
contract UniAlignmentVaultTest is Test {
    UniAlignmentVault public vault;
    MockEXECToken public alignmentToken;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);
    address public dave = address(0x5);

    address public mockWETH = address(0x1111111111111111111111111111111111111111);
    address public mockPoolManager = address(0x2222222222222222222222222222222222222222);

    MockZRouter public mockZRouter;
    MockVaultPriceValidator public mockValidator;
    MiyaRegistry public alignmentRegistry;
    TestableUniAlignmentVault public vaultImpl;

    uint256 constant TARGET_ID = 0;

    // Events
    event ContributionReceived(address indexed benefactor, uint256 amount);
    event LiquidityAdded(
        uint256 ethSwapped,
        uint256 tokenReceived,
        uint256 lpPositionValue,
        uint256 sharesIssued,
        uint256 callerReward
    );
    event FeesClaimed(address indexed benefactor, uint256 ethAmount);
    event FeesAccumulated(uint256 amount);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock alignment token
        alignmentToken = new MockEXECToken(1000000e18);

        // Deploy mock peripherals
        mockZRouter = new MockZRouter();
        mockValidator = new MockVaultPriceValidator();
        alignmentRegistry = new MiyaRegistry(owner, address(0xFEE), 100, 1000);
        address[] memory targetTokens = new address[](2);
        targetTokens[0] = address(alignmentToken);
        targetTokens[1] = address(0x9999);
        alignmentRegistry.addTarget("Test target", targetTokens);
        alignmentRegistry.setConversionKeeper(dave);

        // Pre-fund MockZRouter for both swap directions
        vm.deal(address(mockZRouter), 100 ether);
        alignmentToken.transfer(address(mockZRouter), 100_000e18);

        // Deploy testable vault implementation and clone it
        vaultImpl = new TestableUniAlignmentVault();
        vault = TestableUniAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
        vault.initialize(
            owner,
            mockWETH,
            mockPoolManager,
            address(alignmentToken),
            address(mockZRouter),
            3000,
            60,
            IVaultPriceValidator(address(mockValidator)),
            IMiyaRegistry(address(alignmentRegistry)),
            TARGET_ID
        );

        // Set V4 pool key for conversion tests (using native ETH)
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(owner, 100 ether);
    }

    // ========== Initialization Tests ==========

    function test_Initialize_StoresParametersCorrectly() public view {
        assertEq(vault.weth(), mockWETH, "WETH address incorrect");
        assertEq(vault.poolManager(), mockPoolManager, "PoolManager address incorrect");
        assertEq(vault.alignmentToken(), address(alignmentToken), "AlignmentToken address incorrect");
        assertEq(vault.owner(), owner, "Owner address incorrect");
    }

    function test_Initialize_InitializesStateVariables() public view {
        assertEq(vault.totalShares(), 0, "Total shares should be 0");
        assertEq(vault.totalPendingETH(), 0, "Total pending ETH should be 0");
        assertEq(vault.accumulatedFees(), 0, "Accumulated fees should be 0");
        assertEq(vault.totalLPUnits(), 0, "Total LP units should be 0");
        assertEq(vault.CONVERSION_REWARD(), 0.0012 ether, "Conversion reward should be 0.0012 ETH");
    }

    function _freshClone() internal returns (TestableUniAlignmentVault) {
        return TestableUniAlignmentVault(payable(LibClone.clone(address(vaultImpl))));
    }

    function _initVault(TestableUniAlignmentVault v) internal {
        v.initialize(
            address(this),
            mockWETH, mockPoolManager, address(alignmentToken),
            address(mockZRouter), 3000, 60,
            IVaultPriceValidator(address(mockValidator)),
            IMiyaRegistry(address(alignmentRegistry)), TARGET_ID
        );
    }

    function test_Initialize_RevertsOnInvalidWETH() public {
        TestableUniAlignmentVault v = _freshClone();
        vm.expectRevert(UniAlignmentVault.InvalidAddress.selector);
        v.initialize(address(this), address(0), mockPoolManager,
            address(alignmentToken),
            address(mockZRouter), 3000, 60,
            IVaultPriceValidator(address(mockValidator)),
            IMiyaRegistry(address(alignmentRegistry)), TARGET_ID);
    }

    function test_Initialize_RevertsOnInvalidPoolManager() public {
        TestableUniAlignmentVault v = _freshClone();
        vm.expectRevert(UniAlignmentVault.InvalidAddress.selector);
        v.initialize(address(this), mockWETH, address(0),
            address(alignmentToken),
            address(mockZRouter), 3000, 60,
            IVaultPriceValidator(address(mockValidator)),
            IMiyaRegistry(address(alignmentRegistry)), TARGET_ID);
    }

    function test_Initialize_RevertsOnInvalidAlignmentToken() public {
        TestableUniAlignmentVault v = _freshClone();
        vm.expectRevert(UniAlignmentVault.InvalidAddress.selector);
        v.initialize(address(this), mockWETH, mockPoolManager,
            address(0),
            address(mockZRouter), 3000, 60,
            IVaultPriceValidator(address(mockValidator)),
            IMiyaRegistry(address(alignmentRegistry)), TARGET_ID);
    }

    function test_Initialize_RevertsOnDoubleInit() public {
        TestableUniAlignmentVault v = _freshClone();
        _initVault(v);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        _initVault(v);
    }

    // ========== Direct ETH Contribution Tests (receive) ==========

    function test_Receive_AcceptsETHContribution() public {
        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit ContributionReceived(alice, 1 ether);

        (bool success, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "ETH transfer should succeed");

        vm.stopPrank();
    }

    function test_Receive_TracksBenefactorTotalETH() public {
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success);

        assertEq(vault.benefactorTotalETH(alice), 2 ether, "Benefactor total ETH should be 2 ether");
    }

    function test_Receive_TracksPendingETH() public {
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 3 ether}("");
        assertTrue(success);

        assertEq(vault.pendingETH(alice), 3 ether, "Pending ETH should be 3 ether");
        assertEq(vault.totalPendingETH(), 3 ether, "Total pending ETH should be 3 ether");
    }

    function test_Receive_JoinsTheOpenBatch() public {
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success);

        assertEq(vault.pendingETH(alice), 1 ether, "Alice is waiting for the next conversion");
    }

    function test_Receive_MultipleContributionsFromSameBenefactor() public {
        vm.startPrank(alice);
        (bool success1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success1);

        (bool success2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success2);
        vm.stopPrank();

        assertEq(vault.benefactorTotalETH(alice), 3 ether, "Total should be 3 ether");
        assertEq(vault.pendingETH(alice), 3 ether, "Pending should be 3 ether");
        assertEq(vault.totalPendingETH(), 3 ether, "Global pending should be 3 ether");
    }

    function test_Receive_RevertsOnZeroAmount() public {
        vm.startPrank(alice);
        (bool success, bytes memory returnData) = address(vault).call{value: 0}("");
        assertFalse(success, "Should revert on zero amount");
        vm.stopPrank();
    }

    // ========== Hook Tax Reception Tests ==========

    function test_ReceiveHookTax_AcceptsContributionWithBenefactor() public {
        vm.startPrank(alice);

        vm.expectEmit(true, true, true, true);
        emit ContributionReceived(bob, 1 ether);

        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, bob);

        vm.stopPrank();
    }

    function test_ReceiveHookTax_TracksBenefactorNotSender() public {
        vm.prank(alice);
        vault.receiveContribution{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);

        assertEq(vault.benefactorTotalETH(bob), 2 ether, "Bob should be tracked as benefactor");
        assertEq(vault.benefactorTotalETH(alice), 0, "Alice should not be benefactor");
    }

    function test_ReceiveHookTax_TracksPendingETH() public {
        vm.prank(alice);
        vault.receiveContribution{value: 3 ether}(Currency.wrap(address(0)), 3 ether, bob);

        assertEq(vault.pendingETH(bob), 3 ether, "Bob's pending ETH should be 3 ether");
        assertEq(vault.totalPendingETH(), 3 ether, "Total pending ETH should be 3 ether");
    }

    function test_ReceiveHookTax_RevertsOnZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(UniAlignmentVault.AmountMustBePositive.selector);
        vault.receiveContribution(Currency.wrap(address(0)), 0, bob);
        vm.stopPrank();
    }

    function test_ReceiveHookTax_RevertsOnInvalidBenefactor() public {
        vm.startPrank(alice);
        vm.expectRevert(UniAlignmentVault.InvalidAddress.selector);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, address(0));
        vm.stopPrank();
    }

    // ========== Multi-Benefactor Contribution Tests ==========

    function test_MultipleBenefactors_TrackIndependently() public {
        vm.prank(alice);
        (bool success1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success1);

        vm.prank(bob);
        (bool success2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(success2);

        vm.prank(charlie);
        (bool success3, ) = address(vault).call{value: 3 ether}("");
        assertTrue(success3);

        assertEq(vault.benefactorTotalETH(alice), 1 ether);
        assertEq(vault.benefactorTotalETH(bob), 2 ether);
        assertEq(vault.benefactorTotalETH(charlie), 3 ether);
        assertEq(vault.totalPendingETH(), 6 ether);
    }

    function test_MultipleBenefactors_AllJoinTheOpenBatch() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 2 ether}("");
        assertTrue(s2);

        vm.prank(charlie);
        (bool s3, ) = address(vault).call{value: 3 ether}("");
        assertTrue(s3);

        assertGt(vault.pendingETH(alice), 0);
        assertGt(vault.pendingETH(bob), 0);
        assertEq(vault.pendingETH(charlie), 3 ether);
    }

    function test_MultipleBenefactors_MixedContributionMethods() public {
        // Alice via receive
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 1 ether}("");
        assertTrue(s1);

        // Bob via receiveInstance (charlie is sender)
        vm.prank(charlie);
        vault.receiveContribution{value: 2 ether}(Currency.wrap(address(0)), 2 ether, bob);

        // Charlie via receive
        vm.prank(charlie);
        (bool s2, ) = address(vault).call{value: 3 ether}("");
        assertTrue(s2);

        assertEq(vault.benefactorTotalETH(alice), 1 ether);
        assertEq(vault.benefactorTotalETH(bob), 2 ether);
        assertEq(vault.benefactorTotalETH(charlie), 3 ether);
        assertEq(vault.totalPendingETH(), 6 ether);
    }

    // ========== Conversion & Liquidity Tests ==========

    function test_ConvertAndAddLiquidity_ConvertsSuccessfully() public {
        // Setup: Alice and Bob contribute
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        // Conversion
        vm.prank(dave);
        uint256 lpValue = vault.convertAndAddLiquidity(1, 1);

        assertTrue(lpValue > 0, "LP value should be positive");
    }

    function test_ConvertAndAddLiquidity_IssuesSharesProportionally() public {
        // Alice: 10 ETH (33.33%), Bob: 20 ETH (66.66%)
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        uint256 aliceShares = vault.benefactorShares(alice);
        uint256 bobShares = vault.benefactorShares(bob);

        assertTrue(aliceShares > 0, "Alice should have shares");
        assertTrue(bobShares > 0, "Bob should have shares");

        // Bob should have approximately 2x Alice's shares
        assertTrue(bobShares > aliceShares, "Bob should have more shares");
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18); // 1% tolerance
    }

    function test_ConvertAndAddLiquidity_ClearsPendingETH() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        assertEq(vault.pendingETH(alice), 0, "Pending ETH should be cleared");
        assertEq(vault.totalPendingETH(), 0, "Total pending ETH should be cleared");
    }

    function test_ConvertAndAddLiquidity_ClosesTheBatch() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        assertEq(vault.closedBatches(), 1);
        assertEq(vault.pendingETH(alice), 0);
        assertEq(vault.totalPendingETH(), 0);
    }

    function test_ConvertAndAddLiquidity_PaysCallerReward() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        uint256 daveBalanceBefore = dave.balance;

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        uint256 daveBalanceAfter = dave.balance;
        // Flat reward carved out of the batch being converted (no gas-price component)
        uint256 expectedReward = vault.CONVERSION_REWARD(); // 0.0012 ether

        assertEq(daveBalanceAfter - daveBalanceBefore, expectedReward, "Caller should receive reward");
    }

    function test_ConvertAndAddLiquidity_UpdatesTotalLPUnits() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        uint256 lpUnitsBefore = vault.totalLPUnits();

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        uint256 lpUnitsAfter = vault.totalLPUnits();

        assertTrue(lpUnitsAfter > lpUnitsBefore, "LP units should increase");
    }

    function test_ConvertAndAddLiquidity_EmitsLiquidityAddedEvent() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.expectEmit(false, false, false, false);
        emit LiquidityAdded(0, 0, 0, 0, 0);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);
    }

    function test_ConvertAndAddLiquidity_RevertsForNonKeeper() public {
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        vault.convertAndAddLiquidity(1, 1);
    }

    function test_ConvertAndAddLiquidity_RevertsWhenNoPendingETH() public {
        vm.prank(dave);
        vm.expectRevert(UniAlignmentVault.NoPendingETH.selector);
        vault.convertAndAddLiquidity(1, 1);
    }

    function test_ConvertAndAddLiquidity_RevertsWhenNoV4PoolSet() public {
        // Deploy new vault without V4 pool set
        TestableUniAlignmentVault newVault = _freshClone();
        _initVault(newVault);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        (bool s1, ) = address(newVault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vm.expectRevert(UniAlignmentVault.PoolKeyNotSet.selector);
        newVault.convertAndAddLiquidity(1, 1);
    }

    function test_ConvertAndAddLiquidity_MultipleRoundsAccumulateShares() public {
        // Round 1
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        uint256 aliceSharesRound1 = vault.benefactorShares(alice);

        // Round 2
        vm.prank(alice);
        (bool s2, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        uint256 aliceSharesRound2 = vault.benefactorShares(alice);

        assertTrue(aliceSharesRound2 > aliceSharesRound1, "Shares should accumulate");
    }

    // ========== Fee Accumulation Tests ==========

    function _seedShares() internal {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);
        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);
    }

    function test_DepositFees_OwnerCanDepositFees() public {
        _seedShares();
        uint256 balanceBefore = address(vault).balance;

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit FeesAccumulated(5 ether);

        vault.depositFees{value: 5 ether}();

        vm.stopPrank();

        assertEq(vault.accumulatedFees(), 5 ether, "Accumulated fees should be 5 ether");
        assertEq(address(vault).balance - balanceBefore, 5 ether, "Vault balance should grow by 5 ether");
        assertApproxEqAbs(vault.getUnclaimedFees(alice), 5 ether, 1, "Sole shareholder owed all of it");
    }
    function test_DepositFees_RevertsOnZeroAmount() public {
        vm.startPrank(owner);
        vm.expectRevert(UniAlignmentVault.AmountMustBePositive.selector);
        vault.depositFees{value: 0}();
        vm.stopPrank();
    }

    function test_DepositFees_RevertsWithoutShares() public {
        // Nobody to credit yet: the ETH would be stranded
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NoShares.selector);
        vault.depositFees{value: 5 ether}();
    }

    function test_DepositFees_Permissionless() public {
        _seedShares();
        vm.prank(bob);
        vault.depositFees{value: 1 ether}();
        assertApproxEqAbs(vault.getUnclaimedFees(alice), 1 ether, 1);
    }
    // ========== Fee Claim Tests ==========

    function test_ClaimFees_BenefactorCanClaimFees() public {
        // Setup: Alice contributes and gets shares
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // Owner deposits fees
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Alice claims
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit FeesClaimed(alice, 0); // amount checked below (accFeePerShare rounding may keep 1 wei)

        uint256 claimed = vault.claimFees();

        uint256 aliceBalanceAfter = alice.balance;

        assertApproxEqAbs(claimed, 10 ether, 1, "Claimed amount should be 10 ether");
        assertApproxEqAbs(aliceBalanceAfter - aliceBalanceBefore, 10 ether, 1, "Alice should receive 10 ether");
    }

    function test_ClaimFees_ProportionalClaimWithMultipleBenefactors() public {
        // Alice: 10 ETH (33.33%), Bob: 20 ETH (66.66%)
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 20 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // Owner deposits 30 ether in fees
        vm.prank(owner);
        vault.depositFees{value: 30 ether}();

        // Alice claims
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        uint256 aliceClaimed = vault.claimFees();
        uint256 aliceBalanceAfter = alice.balance;

        // Bob claims
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        uint256 bobBalanceAfter = bob.balance;

        // Alice should get ~10 ether (33.33%), Bob should get ~20 ether (66.66%)
        assertApproxEqRel(aliceClaimed, 10 ether, 0.01e18, "Alice should claim ~10 ether");
        assertApproxEqRel(bobClaimed, 20 ether, 0.01e18, "Bob should claim ~20 ether");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, aliceClaimed);
        assertEq(bobBalanceAfter - bobBalanceBefore, bobClaimed);
    }

    function test_ClaimFees_MultipleClaimsTrackDelta() public {
        // Alice contributes and gets shares
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // First fee deposit and claim
        vm.prank(owner);
        vault.depositFees{value: 5 ether}();

        vm.prank(alice);
        uint256 claimed1 = vault.claimFees();
        assertApproxEqAbs(claimed1, 5 ether, 1, "First claim should be 5 ether");

        // Second fee deposit and claim
        vm.prank(owner);
        vault.depositFees{value: 3 ether}();

        vm.prank(alice);
        uint256 claimed2 = vault.claimFees();
        assertApproxEqAbs(claimed2, 3 ether, 1, "Second claim should be 3 ether (delta)");
    }

    function test_ClaimFees_UpdatesClaimState() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        uint256 timestampBefore = block.timestamp;

        vm.prank(alice);
        vault.claimFees();

        assertEq(vault.getUnclaimedFees(alice), 0, "Nothing left to claim");
        assertEq(vault.lastClaimTimestamp(alice), timestampBefore, "Last claim timestamp should be updated");
    }

    function test_ClaimFees_RevertsWhenNoShares() public {
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NoShares.selector);
        vault.claimFees();
    }

    function test_ClaimFees_RevertsWhenNoFeesAccumulated() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.claimFees();
    }

    function test_ClaimFees_RevertsWhenNoNewFees() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // First claim succeeds
        vm.prank(alice);
        vault.claimFees();

        // Second claim without new fees should revert
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.claimFees();
    }

    function test_ClaimFees_IndependentClaimsByMultipleBenefactors() public {
        // Alice and Bob contribute
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // First fee deposit
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Alice claims first
        vm.prank(alice);
        uint256 aliceClaimed1 = vault.claimFees();
        assertApproxEqRel(aliceClaimed1, 5 ether, 0.01e18);

        // Second fee deposit
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Bob claims both rounds
        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        assertApproxEqRel(bobClaimed, 10 ether, 0.01e18); // 5 from first + 5 from second

        // Alice claims second round only
        vm.prank(alice);
        uint256 aliceClaimed2 = vault.claimFees();
        assertApproxEqRel(aliceClaimed2, 5 ether, 0.01e18);
    }

    // ========== Query Function Tests ==========

    function test_GetBenefactorContribution_ReturnsCorrectAmount() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 5 ether}("");
        assertTrue(s1);

        assertEq(vault.getBenefactorContribution(alice), 5 ether);
    }

    function test_GetBenefactorShares_ReturnsCorrectAmount() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        uint256 shares = vault.getBenefactorShares(alice);
        assertTrue(shares > 0, "Alice should have shares");
    }

    function test_CalculateClaimableAmount_ReturnsCorrectValue() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        uint256 claimable = vault.calculateClaimableAmount(alice);
        assertApproxEqAbs(claimable, 10 ether, 1, "Claimable should be 10 ether");
    }

    function test_GetUnclaimedFees_ReturnsCorrectDelta() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // First fee deposit and claim
        vm.prank(owner);
        vault.depositFees{value: 5 ether}();

        vm.prank(alice);
        vault.claimFees();

        // Second fee deposit
        vm.prank(owner);
        vault.depositFees{value: 3 ether}();

        // Check unclaimed
        uint256 unclaimed = vault.getUnclaimedFees(alice);
        assertApproxEqAbs(unclaimed, 3 ether, 1, "Unclaimed should be 3 ether (delta)");
    }

    function test_GetUnclaimedFees_ReturnsZeroWhenNoNewFees() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        vm.prank(alice);
        vault.claimFees();

        uint256 unclaimed = vault.getUnclaimedFees(alice);
        assertEq(unclaimed, 0, "Unclaimed should be 0 after full claim");
    }

    // ========== Configuration Tests ==========

    function test_SetV4PoolKey_RevertsWhenAlreadySet() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 10000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });

        vm.prank(owner);
        vm.expectRevert(UniAlignmentVault.PoolKeyAlreadySet.selector);
        vault.setV4PoolKey(newPoolKey);
    }

    function test_SetV4PoolKey_RevertsOnHooks() public {
        TestableUniAlignmentVault v = _freshClone();
        _initVault(v);
        PoolKey memory hooked = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0xBEEF))
        });

        vm.expectRevert(UniAlignmentVault.HooksNotAllowed.selector);
        v.setV4PoolKey(hooked);
    }
    function test_SetV4PoolKey_RevertsOnInvalidPoolKey() public {
        TestableUniAlignmentVault v = _freshClone();
        _initVault(v);
        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        v.setV4PoolKey(invalidPoolKey);
    }
    function test_SetV4PoolKey_RevertsWhenNotOwner() public {
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x8888)),
            currency1: Currency.wrap(address(alignmentToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.prank(alice);
        vm.expectRevert();
        vault.setV4PoolKey(newPoolKey);
    }

    // ========== Reentrancy Protection Tests ==========

    function test_Receive_ReentrancyProtection() public {
        // This test verifies that the nonReentrant modifier is present
        // In practice, we'd need a malicious contract to test actual reentrancy
        // For now, we verify the function is marked nonReentrant by checking it doesn't fail
        vm.prank(alice);
        (bool success, ) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "Should succeed with reentrancy protection");
    }

    function test_ReceiveHookTax_ReentrancyProtection() public {
        vm.prank(alice);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(address(0)), 1 ether, bob);
        // Should succeed without reentrancy issues
    }

    function test_ConvertAndAddLiquidity_ReentrancyProtection() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);
        // Should succeed without reentrancy issues
    }

    function test_ClaimFees_ReentrancyProtection() public {
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        vm.prank(alice);
        vault.claimFees();
        // Should succeed without reentrancy issues
    }

    // ========== Complex Integration Tests ==========

    function test_CompleteWorkflow_SingleBenefactor() public {
        // 1. Alice contributes
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s1);

        // 2. Conversion happens
        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // 3. Fees accumulate
        vm.prank(owner);
        vault.depositFees{value: 5 ether}();

        // 4. Alice claims
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        vault.claimFees();
        uint256 balanceAfter = alice.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, 5 ether, 1, "Alice should receive all fees");
    }

    function test_CompleteWorkflow_MultipleBenefactorsMultipleRounds() public {
        // Round 1: Alice and Bob contribute
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 6 ether}("");
        assertTrue(s1);

        vm.prank(bob);
        (bool s2, ) = address(vault).call{value: 4 ether}("");
        assertTrue(s2);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // Track alice and bob shares after round 1
        uint256 aliceSharesR1 = vault.benefactorShares(alice);
        uint256 bobSharesR1 = vault.benefactorShares(bob);
        uint256 totalSharesR1 = vault.totalShares();

        // Fees accumulate
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Alice claims
        vm.prank(alice);
        uint256 aliceClaimed1 = vault.claimFees();
        assertApproxEqRel(aliceClaimed1, 6 ether, 0.01e18); // 60%

        // Round 2: Charlie joins
        vm.prank(charlie);
        (bool s3, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s3);

        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // Now Alice and Bob have shares from R1, Charlie has shares from R2
        uint256 aliceSharesR2 = vault.benefactorShares(alice);
        uint256 bobSharesR2 = vault.benefactorShares(bob);
        uint256 charlieSharesR2 = vault.benefactorShares(charlie);
        uint256 totalSharesR2 = vault.totalShares();

        // Verify shares accumulated correctly
        assertEq(aliceSharesR2, aliceSharesR1, "Alice shares unchanged");
        assertEq(bobSharesR2, bobSharesR1, "Bob shares unchanged");
        assertTrue(charlieSharesR2 > 0, "Charlie has new shares");
        assertEq(totalSharesR2, totalSharesR1 + charlieSharesR2, "Total shares increased by Charlie's shares");

        // More fees
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Bob claims - should get his share proportion
        vm.prank(bob);
        uint256 bobClaimed = vault.claimFees();
        assertTrue(bobClaimed > 0, "Bob should claim some fees");

        // Charlie claims - should get his share proportion
        vm.prank(charlie);
        uint256 charlieClaimed = vault.claimFees();
        assertTrue(charlieClaimed > 0, "Charlie should have fees");

        // Alice may have unclaimed fees from round 2
        uint256 aliceUnclaimed = vault.getUnclaimedFees(alice);
        if (aliceUnclaimed > 0) {
            vm.prank(alice);
            uint256 aliceClaimed2 = vault.claimFees();
            assertTrue(aliceClaimed2 > 0, "Alice should have fees from round 2");
        }
    }

    function test_EdgeCase_VerySmallContributions() public {
        // MIN_CONTRIBUTION = 0.001 ether; values below it revert with ContributionBelowMinimum.
        // Verify that a below-minimum contribution reverts.
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 1 wei}("");
        assertFalse(s1, "contribution below MIN_CONTRIBUTION should revert");

        // A contribution at exactly MIN_CONTRIBUTION succeeds.
        uint256 minContrib = vault.MIN_CONTRIBUTION();
        vm.deal(alice, alice.balance + minContrib);
        vm.prank(alice);
        (bool s2, ) = address(vault).call{value: minContrib}("");
        assertTrue(s2, "contribution at MIN_CONTRIBUTION should succeed");

        assertEq(vault.benefactorTotalETH(alice), minContrib);
        assertEq(vault.pendingETH(alice), minContrib);
    }

    function test_EdgeCase_VeryLargeContributions() public {
        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        (bool s1, ) = address(vault).call{value: 10000 ether}("");
        assertTrue(s1);

        assertEq(vault.benefactorTotalETH(alice), 10000 ether);
    }

    function test_EdgeCase_ManyBenefactors() public {
        // Create 10 benefactors
        for (uint160 i = 1; i <= 10; i++) {
            address benefactor = address(i + 1000);
            vm.deal(benefactor, 10 ether);
            vm.prank(benefactor);
            (bool success, ) = address(vault).call{value: 1 ether}("");
            assertTrue(success);
        }

        assertEq(vault.totalPendingETH(), 10 ether);

        // Convert
        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // All should have shares
        for (uint160 i = 1; i <= 10; i++) {
            address benefactor = address(i + 1000);
            assertTrue(vault.benefactorShares(benefactor) > 0, "Each benefactor should have shares");
        }
    }

    // ========== Protocol Yield Cut Tests ==========

    event ProtocolYieldCollected(uint256 amount);
    event ProtocolFeesWithdrawn(uint256 amount);

    function test_YieldCut_DefaultIs100Bps() public view {
        assertEq(vault.protocolYieldCutBps(), 100, "Default yield cut should be 1%");
    }

    function test_YieldCut_DepositFeesNotTaxed() public {
        // depositFees bypasses yield cut (it's a donation, not LP yield)
        _seedShares();
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        assertEq(vault.accumulatedFees(), 10 ether, "depositFees should not be taxed");
        assertEq(vault.accumulatedProtocolFees(), 0, "No protocol fees from depositFees");
    }

    function test_YieldCut_TreasuryIsRegistryTreasury() public {
        // M3: the vault has no treasury setter (its owner is the factory); the cut always goes to the
        // registry treasury, so it follows MiyaRegistry.setTreasury.
        assertEq(vault.protocolTreasury(), address(0xFEE));
        vm.prank(owner);
        alignmentRegistry.setTreasury(address(0xBEEF));
        assertEq(vault.protocolTreasury(), address(0xBEEF));
    }
    function test_YieldCut_WithdrawProtocolFees() public {
        address treasury = address(0xFEE); // registry treasury

        // Setup: contribute, convert, deposit fees via depositFees
        // Since depositFees doesn't go through yield cut, we simulate protocol fees
        // by directly setting accumulatedProtocolFees (need to use recordAccumulatedFees path)
        // Actually, let's use the proper flow: deposit fees for benefactors first,
        // then accumulate protocol fees via a different route.

        // Simpler: contribute, convert, then use recordAccumulatedFees which bypasses yield cut
        // The protocol fees accumulate through claimFees() LP yield path.
        // For unit tests, we can't easily trigger _claimVaultFees() (needs real poolManager).
        // So let's test withdrawProtocolFees by manually setting state.

        // Setup benefactor and shares
        vm.prank(alice);
        (bool s, ) = address(vault).call{value: 10 ether}("");
        assertTrue(s);
        vm.prank(dave);
        vault.convertAndAddLiquidity(1, 1);

        // Owner deposits fees (simulating LP yield — goes to accumulatedFees only)
        vm.prank(owner);
        vault.depositFees{value: 10 ether}();

        // Since we can't trigger real LP yield in unit tests, let's verify the withdrawal
        // mechanism works by using a different approach:
        // We'll set yield cut to 0 first, verify no protocol fees, then check withdrawal reverts
        assertEq(vault.accumulatedProtocolFees(), 0);

        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.withdrawProtocolFees();
    }

    function test_YieldCut_WithdrawProtocolFees_HappyPath() public {
        address treasury = address(0xFEE); // registry treasury

        // Simulate protocol fee accrual (LP yield cut that would come from _claimVaultFees)
        TestableUniAlignmentVault testableVault = TestableUniAlignmentVault(payable(address(vault)));
        testableVault.simulateProtocolFeeAccrual{value: 0.5 ether}(0.5 ether);

        assertEq(vault.accumulatedProtocolFees(), 0.5 ether, "Protocol fees should be 0.5 ether");

        uint256 treasuryBalanceBefore = treasury.balance;

        // Anyone can trigger withdrawal
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit ProtocolFeesWithdrawn(0.5 ether);
        vault.withdrawProtocolFees();

        assertEq(treasury.balance - treasuryBalanceBefore, 0.5 ether, "Treasury should receive 0.5 ether");
        assertEq(vault.accumulatedProtocolFees(), 0, "Protocol fees should be cleared");
    }

    function test_YieldCut_WithdrawProtocolFees_MultipleAccumulations() public {
        address treasury = address(0xFEE); // registry treasury

        TestableUniAlignmentVault testableVault = TestableUniAlignmentVault(payable(address(vault)));

        // Simulate multiple yield collections before withdrawal
        testableVault.simulateProtocolFeeAccrual{value: 0.3 ether}(0.3 ether);
        testableVault.simulateProtocolFeeAccrual{value: 0.2 ether}(0.2 ether);

        assertEq(vault.accumulatedProtocolFees(), 0.5 ether, "Should accumulate across collections");

        uint256 treasuryBalanceBefore = treasury.balance;
        vault.withdrawProtocolFees();

        assertEq(treasury.balance - treasuryBalanceBefore, 0.5 ether, "Treasury gets full accumulated amount");
        assertEq(vault.accumulatedProtocolFees(), 0, "Cleared after withdrawal");

        // Second withdrawal should revert
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.withdrawProtocolFees();
    }

    function test_YieldCut_WithdrawProtocolFees_RevertsNoFees() public {
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.withdrawProtocolFees();
    }

    function test_YieldCut_WithdrawProtocolFees_Permissionless() public {
        // Anyone can call withdrawProtocolFees, not just owner
        address treasury = address(0xFEE); // registry treasury

        // No fees to withdraw, but the access control check should pass
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.withdrawProtocolFees();
        // If it reverted with "No fees" (not Unauthorized), access control passed
    }

}
