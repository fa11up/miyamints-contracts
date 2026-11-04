// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { UniAlignmentVault } from "../../src/vaults/uni/UniAlignmentVault.sol";
import { MiyaRegistry } from "../../src/registry/MiyaRegistry.sol";
import { IVaultPriceValidator } from "../../src/interfaces/IVaultPriceValidator.sol";
import { IMiyaRegistry } from "../../src/registry/interfaces/IMiyaRegistry.sol";
import { MockZRouter } from "../mocks/MockZRouter.sol";
import { MockVaultPriceValidator } from "../mocks/MockVaultPriceValidator.sol";
import { MockEXECToken } from "../mocks/MockEXECToken.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @notice Regression for audit H1: against a REAL v4 PoolManager, PoolManager.take(ETH) and the zRouter
///         token->ETH swap push ETH into the vault's receive() while claimFees() holds the reentrancy lock.
///         Before the fix every claim reverted with Reentrancy() once the position accrued native-ETH fees.
/// @dev PoolManager is pinned to solc 0.8.26, so this file compiles with 0.8.26 (see foundry.toml).
contract UniAlignmentVaultRealV4Test is Test {
    PoolManager pm;
    PoolSwapTest swapper;
    PoolModifyLiquidityTest lper;
    MockEXECToken token;
    MockZRouter zr;
    UniAlignmentVault vault;
    PoolKey key;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = address(0xFEE);
    MiyaRegistry reg;

    function setUp() public {
        pm = new PoolManager(address(this));
        swapper = new PoolSwapTest(pm);
        lper = new PoolModifyLiquidityTest(pm);
        token = new MockEXECToken(1_000_000_000e18);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        pm.initialize(key, 79228162514264337593543950336); // 1:1

        token.approve(address(lper), type(uint256).max);
        token.approve(address(swapper), type(uint256).max);
        vm.deal(address(this), 1000 ether);
        lper.modifyLiquidity{ value: 100 ether }(
            key, IPoolManager.ModifyLiquidityParams(-887220, 887220, 50 ether, 0), ""
        );

        reg = new MiyaRegistry(address(this), treasury, 100, 1000);
        address[] memory toks = new address[](1);
        toks[0] = address(token);
        reg.addTarget("t", toks);
        reg.setConversionKeeper(address(this));
        zr = new MockZRouter();
        token.transfer(address(zr), 1_000_000e18);
        vm.deal(address(zr), 100 ether); // liquidity for the token->ETH leg of fee collection
        MockVaultPriceValidator val = new MockVaultPriceValidator();

        vault = UniAlignmentVault(payable(LibClone.clone(address(new UniAlignmentVault()))));
        vault.initialize(address(this), address(0xBEEF), address(pm), address(token), address(zr), 3000, 60,
            IVaultPriceValidator(address(val)), IMiyaRegistry(address(reg)), 0);
        vault.setV4PoolKey(key);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    receive() external payable { }

    function _trade(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            swapper.swap{ value: 5 ether }(key, IPoolManager.SwapParams(true, -5 ether, TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false), "");
            swapper.swap(key, IPoolManager.SwapParams(false, -5 ether, TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(false, false), "");
        }
    }

    function _contribute(address who, uint256 amt) internal {
        vm.prank(who);
        vault.receiveContribution{ value: amt }(Currency.wrap(address(0)), amt, who);
    }

    function test_claimFeesSucceedsWhenEthFeesAccrue() public {
        _contribute(alice, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        assertGt(vault.totalLPUnits(), 0, "LP added via real PoolManager");

        _trade(3);

        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 claimed = vault.claimFees();
        assertGt(claimed, 0, "LP yield claimable");
        assertEq(alice.balance - before, claimed);
        assertGt(vault.accumulatedProtocolFees(), 0, "protocol cut accrued");

        // Collection is repeatable: later claims keep working.
        _trade(2);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        assertGt(vault.claimFees(), 0);

        // Protocol cut reaches the registry treasury (M3).
        uint256 tBefore = treasury.balance;
        uint256 cut = vault.accumulatedProtocolFees();
        vault.withdrawProtocolFees();
        assertEq(treasury.balance - tBefore, cut);
    }

    function test_claimFeesAsDelegateSucceedsWhenEthFeesAccrue() public {
        _contribute(alice, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        vm.prank(alice);
        vault.delegateBenefactor(bob);
        _trade(3);

        address[] memory bs = new address[](1);
        bs[0] = alice;
        vm.prank(bob);
        assertGt(vault.claimFeesAsDelegate(bs), 0);
    }

    /// Fees accrued in the LP before a second conversion belong to the existing holders only.
    function test_secondConversionDoesNotDiluteAccruedLpFees() public {
        _contribute(alice, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        _trade(3);

        _contribute(bob, 2 ether);
        vault.convertAndAddLiquidity(1, 1); // collects LP fees for alice before bob's shares exist

        uint256 aliceOwed = vault.getUnclaimedFees(alice);
        assertGt(aliceOwed, 0);
        assertEq(vault.getUnclaimedFees(bob), 0, "bob earns nothing from fees accrued before he joined");

        vm.prank(alice);
        assertEq(vault.claimFees(), aliceOwed);
        assertGe(address(vault).balance, vault.accumulatedProtocolFees(), "solvent");
    }

    // ── M2: only the keeper swaps ───────────────────────────────────────────

    function test_onlyKeeperConverts() public {
        _contribute(alice, 2 ether);
        vm.startPrank(alice);
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        vault.convertAndAddLiquidity(1, 1);
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        vault.convertFeeTokens(1);
        vm.stopPrank();

        reg.setConversionKeeper(address(0));
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        vault.convertAndAddLiquidity(1, 1);
    }

    function test_onlyOwnerSetsKeeper() public {
        vm.prank(alice);
        vm.expectRevert();
        reg.setConversionKeeper(alice);
    }

    /// A claim is open to anyone: it must not swap, or it could be sandwiched with no price floor.
    function test_claimLeavesFeeTokensForTheKeeper() public {
        _contribute(alice, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        _trade(3);

        vm.expectCall(address(zr), abi.encodeWithSelector(MockZRouter.swapV4.selector), 0);
        vm.prank(alice);
        vault.claimFees();

        uint256 pending = vault.pendingFeeTokens();
        assertGt(pending, 0, "token-side fees wait for the keeper");
        assertGe(token.balanceOf(address(vault)), pending, "and are still held");
    }

    /// The keeper's floor covers the tokens bought across every pass.
    function test_floorCoversAllPasses() public {
        _contribute(alice, 2 ether);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.convertAndAddLiquidity(type(uint128).max, 1);
    }

    function test_keeperConvertsFeeTokensAndCreditsHolders() public {
        _contribute(alice, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        _trade(3);

        // A floor of 0 leaves them pending, so tokens worth under 1 wei can't block the keeper.
        vault.convertFeeTokens(0);
        assertGt(vault.pendingFeeTokens(), 0, "collected and left pending");

        uint256 before = vault.getUnclaimedFees(alice);
        vault.convertFeeTokens(1);
        assertEq(vault.pendingFeeTokens(), 0);
        assertGt(vault.getUnclaimedFees(alice), before, "converted fees reach the holder");
    }

    /// H2 must survive the deferred swap: fee tokens earned before a join stay with the earlier holders.
    function test_pendingFeeTokensDoNotDiluteToNewShares() public {
        _contribute(alice, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        _trade(3);
        vm.prank(alice);
        vault.claimFees();
        assertGt(vault.pendingFeeTokens(), 0);

        _contribute(bob, 2 ether);
        vault.convertAndAddLiquidity(1, 1);
        assertEq(vault.pendingFeeTokens(), 0, "converted before the join");
        assertGt(vault.benefactorShares(bob), 0);
        assertEq(vault.getUnclaimedFees(bob), 0, "bob earned nothing yet");
        assertGt(vault.getUnclaimedFees(alice), 0, "alice keeps them");
    }
}
