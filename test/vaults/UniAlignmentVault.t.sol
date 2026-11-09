// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {UniAlignmentVaultFactory} from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {IVaultConfig, SwapCall} from "../../src/vaults/uni/IVaultConfig.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {IAlignmentVault, ClaimMode} from "../../src/interfaces/IAlignmentVault.sol";
import {TestableUniAlignmentVault} from "../helpers/TestableUniAlignmentVault.sol";
import {MockToken, MockFeeOnTransferToken} from "./mocks/VaultMocks.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @dev Keeper that refuses ETH (rejected reward path).
contract RefusingKeeper {
    function convert(UniAlignmentVault v, UniAlignmentVault.ConvertParams calldata p) external returns (uint256) {
        return v.convertAndAddLiquidity(p);
    }
}

/// @dev Benefactor contract (a collection stand-in) that may refuse ETH.
contract Benefactor {
    bool public refuse;

    function setRefuse(bool r) external {
        refuse = r;
    }

    function claim(UniAlignmentVault v, ClaimMode m, uint256 minOut) external returns (uint256, uint256, uint256) {
        return v.claimFees(m, minOut);
    }

    function delegate(UniAlignmentVault v, address d) external {
        v.delegateBenefactor(d);
    }

    receive() external payable {
        require(!refuse, "no");
    }
}

contract UniAlignmentVaultTest is VaultTestBase {
    // ═══ contributions ═══════════════════════════════════════════════════

    function test_ethContribution_booksPending() public {
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IAlignmentVault.ContributionReceived(alice, ETH, 1 ether);
        vm.prank(alice);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(ETH), 1 ether, alice);
        assertEq(vault.pendingOf(alice, ETH), 1 ether);
        assertEq(vault.pendingByToken(ETH), 1 ether);
        assertEq(vault.openBatchTokens().length, 1);
        assertEq(vault.contributionOf(alice, ETH), 1 ether);
        assertEq(vault.totalUniqueBenefactors(), 1);
    }

    function test_receive_creditsSender() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingOf(alice, ETH), 0.5 ether);
    }

    function test_ethContribution_validations() public {
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        vm.expectRevert(UniAlignmentVault.AmountMismatch.selector);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(ETH), 2 ether, alice);
        vm.expectRevert(UniAlignmentVault.ContributionBelowMinimum.selector);
        vault.receiveContribution{value: 0.0009 ether}(Currency.wrap(ETH), 0.0009 ether, alice);
        vm.expectRevert(UniAlignmentVault.AmountMustBePositive.selector);
        vault.receiveContribution(Currency.wrap(ETH), 0, alice);
        vm.expectRevert(UniAlignmentVault.InvalidAddress.selector);
        vault.receiveContribution{value: 1 ether}(Currency.wrap(ETH), 1 ether, address(0));
        vm.stopPrank();
    }

    function test_erc20Contribution_pullsExactAmount() public {
        usdc.mint(address(this), 3000e6);
        usdc.approve(address(vault), 3000e6);
        vault.receiveContribution(Currency.wrap(USDC_ADDR), 3000e6, alice); // credited to alice, paid by this
        assertEq(usdc.balanceOf(address(vault)), 3000e6);
        assertEq(vault.pendingOf(alice, USDC_ADDR), 3000e6);
        assertEq(vault.pendingOf(address(this), USDC_ADDR), 0);
    }

    function test_erc20Contribution_refusals() public {
        MockToken stray = new MockToken("X", "X", 18);
        stray.mint(alice, 1e18);
        usdc.mint(alice, 1e6);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        stray.approve(address(vault), 1e18);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(UniAlignmentVault.TokenNotAllowed.selector, address(stray)));
        vault.receiveContribution(Currency.wrap(address(stray)), 1e18, alice);
        vm.expectRevert(UniAlignmentVault.AmountMismatch.selector);
        vault.receiveContribution{value: 1}(Currency.wrap(USDC_ADDR), 1e6, alice);
        vm.stopPrank();

        // Allowlisted in the registry: accepted (no route needed; the keeper brings the swap).
        registry.setPaymentToken(address(stray), true);
        vm.prank(alice);
        vault.receiveContribution(Currency.wrap(address(stray)), 1e18, alice);
        assertEq(vault.pendingOf(alice, address(stray)), 1e18);

        // No allowance: the pull fails.
        imd.mint(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.receiveContribution(Currency.wrap(IMD_ADDR), 1e18, bob);
    }

    function test_erc20Contribution_tinyAmountsAcceptedWithoutMinimum() public {
        _contribute(alice, wbtc, 1); // 1 sat: no minimum set for WBTC in this table
        assertEq(vault.pendingOf(alice, WBTC_ADDR), 1);
    }

    function test_erc20Contribution_minimumFromFactory() public {
        factory.setMinContribution(WBTC_ADDR, 3000);
        factory.setMinContribution(IMD_ADDR, 1e18); // IMD is never swapped, but can still have a minimum
        wbtc.mint(alice, 1e8);
        imd.mint(alice, 1e18);
        vm.startPrank(alice);
        wbtc.approve(address(vault), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
        vm.expectRevert(UniAlignmentVault.ContributionBelowMinimum.selector);
        vault.receiveContribution(Currency.wrap(WBTC_ADDR), 2999, alice);
        vm.expectRevert(UniAlignmentVault.ContributionBelowMinimum.selector);
        vault.receiveContribution(Currency.wrap(IMD_ADDR), 1e18 - 1, alice);
        vault.receiveContribution(Currency.wrap(WBTC_ADDR), 3000, alice);
        vault.receiveContribution(Currency.wrap(IMD_ADDR), 1e18, alice);
        vm.stopPrank();
        assertEq(vault.pendingOf(alice, WBTC_ADDR), 3000);
        // 0 = no minimum again; ETH keeps the vault's own MIN_CONTRIBUTION and is not in the table.
        factory.setMinContribution(WBTC_ADDR, 0);
        _contribute(bob, wbtc, 1);
        vm.expectRevert(UniAlignmentVaultFactory.InvalidAddress.selector);
        factory.setMinContribution(ETH, 1);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setMinContribution(WBTC_ADDR, 1);
    }

    function test_feeOnTransferToken_refused() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken();
        registry.setPaymentToken(address(fot), true);
        fot.mint(alice, 100e18);
        vm.startPrank(alice);
        fot.approve(address(vault), 100e18);
        vm.expectRevert(UniAlignmentVault.ReceivedLess.selector);
        vault.receiveContribution(Currency.wrap(address(fot)), 100e18, alice);
        vm.stopPrank();
    }

    function test_droppedToken_refusedForNewContributions() public {
        _contribute(alice, usdc, 1000e6);
        registry.setPaymentToken(USDC_ADDR, false);
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(UniAlignmentVault.TokenNotAllowed.selector, USDC_ADDR));
        vault.receiveContribution(Currency.wrap(USDC_ADDR), 1e6, bob);
        vm.stopPrank();
        // What was already pending still converts.
        _convert();
        assertGt(vault.benefactorShares(alice), 0);
    }

    function test_tooManyTokens() public {
        // The registry allows at most 15 ERC-20s, so ETH + every allowed token fits the vault's 16 (in all and per
        // benefactor): alice holds all 16.
        _contributeEth(alice, 0.01 ether);
        MockToken[6] memory base = [infer, imd, usdc, imdUsd, cbBtc, wbtc];
        for (uint256 i; i < 6; ++i) _contribute(alice, base[i], 1e8);
        MockToken last;
        for (uint256 i; i < 9; ++i) {
            last = new MockToken("T", "T", 18);
            registry.setPaymentToken(address(last), true);
            _contribute(alice, last, 1e18);
        }
        assertEq(vault.openBatchTokens().length, 16);
        MockToken extra = new MockToken("X", "X", 18);
        vm.expectRevert(MiyaRegistry.TooManyPaymentTokens.selector);
        registry.setPaymentToken(address(extra), true);
        // Only a token dropped while still pending can push past it: the vault then refuses the 17th (a collection
        // parks that cut until the dropped token converts).
        registry.setPaymentToken(address(last), false);
        registry.setPaymentToken(address(extra), true);
        extra.mint(bob, 1e18);
        vm.startPrank(bob);
        extra.approve(address(vault), 1e18);
        vm.expectRevert(UniAlignmentVault.TooManyTokens.selector);
        vault.receiveContribution(Currency.wrap(address(extra)), 1e18, bob);
        vm.stopPrank();
    }

    // ═══ conversion: access and params ═══════════════════════════════════

    function test_convert_keeperOnly() public {
        _contributeEth(alice, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        vault.convertAndAddLiquidity(p);
    }

    function test_convert_nothingPending() public {
        UniAlignmentVault.ConvertParams memory p;
        p.deadline = block.timestamp;
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.NothingPending.selector);
        vault.convertAndAddLiquidity(p);
    }

    function test_convert_badParamsAndDeadline() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, usdc, 3000e6);
        UniAlignmentVault.ConvertParams memory p = _params(vault);

        // A duplicate token, an amount above what is pending, a zero amount, a token with nothing pending, arrays of
        // the wrong length (amounts or swaps): all BadParams.
        UniAlignmentVault.ConvertParams memory q = _paramsFor(_two(USDC_ADDR, USDC_ADDR), _amts(1e6, 1e6));
        _expectBadParams(q);
        q = _paramsFor(_one(USDC_ADDR), _amts(3000e6 + 1));
        _expectBadParams(q);
        q = _paramsFor(_one(USDC_ADDR), _amts(0));
        _expectBadParams(q);
        q = _paramsFor(_one(WBTC_ADDR), _amts(1));
        _expectBadParams(q);
        q = _paramsFor(_one(USDC_ADDR), _amts(1e6, 1e6));
        _expectBadParams(q);
        q = _paramsFor(new address[](0), new uint256[](0));
        _expectBadParams(q);
        q = _params(vault);
        q.swaps = new SwapCall[](1); // two tokens, one swap
        _expectBadParams(q);
        q = _params(vault);
        q.ethLeg.target = address(0); // ETH reaches the leg: it is required
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(UniAlignmentVault.SwapTargetNotAllowed.selector, address(0)));
        vault.convertAndAddLiquidity(q);

        q = _params(vault);
        q.deadline = block.timestamp - 1;
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.Expired.selector);
        vault.convertAndAddLiquidity(q);

        vm.prank(keeper);
        vault.convertAndAddLiquidity(p);
    }

    function _expectBadParams(UniAlignmentVault.ConvertParams memory q) internal {
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.BadParams.selector);
        vault.convertAndAddLiquidity(q);
    }

    function test_convert_swapFloorEnforced() public {
        _contribute(bob, usdc, 3000e6);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        p.swaps[0].minOut = 1.0001 ether; // 3000 USDC -> 1 ETH
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector); // the vault's own balance check
        vault.convertAndAddLiquidity(p);
        p = _params(vault);
        p.ethLeg.minOut = 10_001e18; // 1 ETH -> 10,000 IMD (the merged ETH leg)
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.convertAndAddLiquidity(p);
        p = _params(vault);
        vm.prank(keeper);
        vault.convertAndAddLiquidity(p);
    }

    function test_convert_splitFloors() public {
        _contributeEth(alice, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        p.minSplitOut = 0;
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.ZeroFloor.selector);
        vault.convertAndAddLiquidity(p);

        p.minSplitOut = 5000e18; // ~4,962 INFER is what ~5,025 IMD buys at 1:1 less 1.25%
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.convertAndAddLiquidity(p);
    }

    function test_convert_poolNotInitialized() public {
        vault.setMockPool(0, 0);
        _contributeEth(alice, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        vm.prank(keeper);
        vm.expectRevert(UniAlignmentVault.PoolNotInitialized.selector);
        vault.convertAndAddLiquidity(p);
    }

    // ═══ conversion: every token (the spec's pools, as zRouter calldata) ═══

    function _assertSingleRoute(MockToken t, uint256 amount, uint256 expectedImdValue) internal {
        _contribute(alice, t, amount);
        uint256 shares = _convert();
        assertGt(shares, 0);
        // Sole benefactor: every share, less the ledger's rounding (its pending in raw units / 1e18 at most).
        assertApproxEqAbs(vault.benefactorShares(alice), shares, shares / 1e15 + 1, "sole benefactor gets every share");
        assertEq(vault.pendingOf(alice, address(t)), 0);
        assertEq(vault.pendingByToken(address(t)), 0);
        assertEq(t.balanceOf(address(vault)), 0, "the route spent it all");
        assertEq(vault.openBatchTokens().length, 0);
        // Liquidity at 1:1 full range ~ the IMD value each side carries ~ half the value.
        assertApproxEqRel(shares, expectedImdValue / 2, 0.02e18);
        _assertSolvent(vault);
    }

    function test_route_eth() public {
        _contributeEth(alice, 1 ether);
        uint256 shares = _convert();
        assertEq(vault.benefactorShares(alice), shares);
        assertApproxEqRel(shares, 9988e18 / 2, 0.02e18); // 1 ETH less the 0.0012 reward
        assertEq(keeper.balance, 0.0012 ether, "flat reward");
        _assertSolvent(vault);
    }

    function test_route_usdc() public {
        _assertSingleRoute(usdc, 3000e6, 10_000e18);
    }

    function test_route_wbtc() public {
        _assertSingleRoute(wbtc, 1e7, 30_000e18); // 0.1 BTC = 3 ETH
    }

    function test_route_cbBtc_viaV3() public {
        _contribute(alice, cbBtc, 1e7);
        uint256 callsBefore = router.calls();
        _convert();
        assertEq(router.calls(), callsBefore + 2);
        assertFalse(router.lastWasV3(), "second hop v4");
        assertApproxEqRel(vault.benefactorShares(alice), 15_000e18, 0.02e18);
        _assertSolvent(vault);
    }

    function test_route_imdUsd() public {
        _assertSingleRoute(imdUsd, 1000e18, 3000e18);
    }

    function test_route_imdOnly() public {
        _contribute(alice, imd, 10_000e18);
        uint256 calls = router.calls();
        _convert();
        assertEq(router.calls(), calls, "no router swap");
        assertApproxEqRel(vault.benefactorShares(alice), 5000e18, 0.02e18);
        _assertSolvent(vault);
    }

    function test_route_inferOnly() public {
        _contribute(alice, infer, 10_000e18);
        _convert();
        assertApproxEqRel(vault.benefactorShares(alice), 5000e18, 0.02e18);
        _assertSolvent(vault);
    }

    function test_route_dustTokenConvertsToNothingWithoutBlocking() public {
        _contribute(alice, wbtc, 1); // 1 sat -> 3e11 wei -> 3e15 IMD: tiny but nonzero
        _contributeEth(bob, 1 ether);
        _convert();
        assertGt(vault.benefactorShares(bob), 0);
        assertLe(vault.benefactorShares(alice), vault.benefactorShares(bob) / 1e5);
    }

    function test_targetRemovedAtConversion_reverts() public {
        _contribute(alice, usdc, 3000e6);
        factory.setSwapTarget(address(router), false); // the Safe drops the target while USDC is pending
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(UniAlignmentVault.SwapTargetNotAllowed.selector, address(router)));
        vault.convertAndAddLiquidity(p);
    }

    // ═══ mixed batches and share split ═══════════════════════════════════

    function test_mixedBatch_sharesByRealizedValue() public {
        _contributeEth(alice, 1 ether); //            -> 0.9988 ETH routed (reward) -> 9,988 IMD
        _contribute(bob, usdc, 3000e6); //            -> 1 ETH -> 10,000 IMD
        _contribute(carol, imd, 10_000e18); //        10,000 IMD
        _contribute(dan, infer, 10_000e18); //        valued at the split's realized IMD-per-INFER rate
        uint256 shares = _convert();

        uint256 sa = vault.benefactorShares(alice);
        uint256 sb = vault.benefactorShares(bob);
        uint256 sc = vault.benefactorShares(carol);
        uint256 sd = vault.benefactorShares(dan);
        assertLe(sa + sb + sc + sd, shares);
        assertApproxEqAbs(sa + sb + sc + sd, shares, shares / 1e15);

        assertApproxEqRel(sb * 1e18 / sc, 1e18, 1e9, "USDC worth 10,000 IMD = 10,000 IMD");
        assertApproxEqRel(sa * 1e18 / sc, 0.9988e18, 1e9, "ETH net of the keeper reward");
        // The batch was IMD-heavy: IMD was swapped to INFER at 1 / (1 - 1.25%) IMD per INFER.
        assertApproxEqRel(sd * 1e18 / sc, uint256(1e24) / 987_500, 1e9, "INFER at the realized buy rate");
        _assertSolvent(vault);
    }

    function test_mixedBatch_inferHeavy_valuedAtSellRate() public {
        _contribute(carol, imd, 1000e18);
        _contribute(dan, infer, 10_000e18); // INFER-heavy: the vault sells INFER for IMD
        _convert();
        uint256 sc = vault.benefactorShares(carol);
        uint256 sd = vault.benefactorShares(dan);
        assertApproxEqRel(sd * 1e18 / sc, 0.9875e18 * 10, 1e9, "INFER at the realized sell rate");
    }

    function test_mixedBatch_eightAndSixDecimals() public {
        _contribute(alice, wbtc, uint256(1e8) / 30); // ~1 ETH of WBTC (8 decimals)
        _contribute(bob, usdc, 3000e6); //     1 ETH of USDC (6 decimals)
        _contribute(carol, cbBtc, uint256(1e8) / 30); // ~1 ETH of cbBTC via v3
        _convert();
        uint256 sa = vault.benefactorShares(alice);
        uint256 sb = vault.benefactorShares(bob);
        uint256 sc = vault.benefactorShares(carol);
        assertApproxEqRel(sa, sb, 1e14);
        assertEq(sa, sc);
    }

    function test_twoBatches_lazyCollection() public {
        _contributeEth(alice, 1 ether);
        uint256 s1 = _convert();
        assertEq(vault.benefactorShares(alice), s1, "view includes the uncollected batch");
        _contributeEth(bob, 1 ether);
        uint256 s2 = _convert();
        assertEq(vault.benefactorShares(bob), s2);
        assertEq(vault.totalShares(), s1 + s2);
        assertEq(vault.closedBatches(), 2);
        // Alice contributing again collects batch 1 first; batch-1 shares stay.
        _contributeEth(alice, 1 ether);
        assertEq(vault.benefactorShares(alice), s1);
        assertEq(vault.pendingOf(alice, ETH), 1 ether);
        _convert();
        assertGt(vault.benefactorShares(alice), s1);
    }

    function test_batchCostIndependentOfContributors() public {
        for (uint256 i; i < 200; ++i) {
            _contributeEth(address(uint160(0x10000 + i)), 0.01 ether);
        }
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        vm.prank(keeper);
        uint256 g = gasleft();
        vault.convertAndAddLiquidity(p);
        assertLt(g - gasleft(), 1_000_000);
        assertGt(vault.benefactorShares(address(0x10000)), 0);
    }

    // ═══ subsets, exact amounts, the merged ETH leg ══════════════════════

    function test_subset_unlistedTokensStayPending() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, usdc, 3000e6);
        _contribute(carol, imd, 10_000e18);
        _contribute(dan, infer, 5000e18);
        uint256 shares = _convertSome(_one(USDC_ADDR), _amts(3000e6));
        assertEq(vault.benefactorShares(bob), shares, "only bob converted");
        assertApproxEqRel(shares, 5000e18, 0.02e18, "bob's 10,000 IMD only: pending IMD/INFER stay out of the add");
        assertEq(vault.pendingOf(alice, ETH), 1 ether);
        assertEq(vault.pendingOf(carol, IMD_ADDR), 10_000e18);
        assertEq(vault.pendingOf(dan, INFER_ADDR), 5000e18);
        assertEq(vault.pendingOf(bob, USDC_ADDR), 0);
        assertEq(vault.benefactorShares(alice) + vault.benefactorShares(carol) + vault.benefactorShares(dan), 0);
        assertEq(keeper.balance, 0, "no ETH converted, no reward");
        assertEq(address(vault).balance, 1 ether);
        assertGe(imd.balanceOf(address(vault)), 10_000e18);
        assertGe(infer.balanceOf(address(vault)), 5000e18);
        assertEq(vault.openBatchTokens().length, 3);
        _assertSolvent(vault);
        // The rest converts later, as usual.
        _convert();
        assertGt(vault.benefactorShares(alice), 0);
        assertGt(vault.benefactorShares(carol), 0);
        assertGt(vault.benefactorShares(dan), 0);
        assertEq(vault.openBatchTokens().length, 0);
        _assertSolvent(vault);
    }

    function test_partial_proRataAcrossBenefactors() public {
        _contributeEth(alice, 3 ether);
        _contributeEth(bob, 1 ether);
        uint256 s1 = _convertSome(_one(ETH), _amts(2 ether));
        assertEq(vault.pendingOf(alice, ETH), 1.5 ether);
        assertEq(vault.pendingOf(bob, ETH), 0.5 ether);
        assertEq(vault.pendingByToken(ETH), 2 ether);
        assertApproxEqAbs(vault.benefactorShares(alice), s1 * 3 / 4, 2);
        assertApproxEqAbs(vault.benefactorShares(bob), s1 / 4, 2);
        assertEq(keeper.balance, 0.0012 ether, "reward from the ETH converted");
        uint256 s2 = _convertSome(_one(ETH), _amts(2 ether));
        assertEq(vault.pendingOf(alice, ETH) + vault.pendingOf(bob, ETH) + vault.pendingByToken(ETH), 0);
        assertEq(vault.openBatchTokens().length, 0);
        assertApproxEqAbs(vault.benefactorShares(alice), (s1 + s2) * 3 / 4, 3);
        assertApproxEqAbs(vault.benefactorShares(bob), (s1 + s2) / 4, 3);
        _assertSolvent(vault);
    }

    function test_partial_benefactorWithSeveralTokens() public {
        // Alice: ETH, USDC and WBTC pending; bob: ETH. Convert all USDC and half the ETH; WBTC stays.
        _contributeEth(alice, 1 ether);
        _contribute(alice, usdc, 3000e6);
        _contribute(alice, wbtc, 1e6);
        _contributeEth(bob, 1 ether);
        vm.recordLogs();
        uint256 shares = _convertSome(_two(USDC_ADDR, ETH), _amts(3000e6, 1 ether));
        (uint256 vUsdc, uint256 vEth) = _values(USDC_ADDR, ETH);
        // 3000 USDC -> 1 ETH; 1 ETH less the 0.0012 reward: one leg of 1.9988 ETH -> 19,988 IMD, shared by ETH in.
        assertApproxEqAbs(vUsdc, 10_000e18, 1e5); // 3000 USDC -> 1 ETH less a wei at the mock's rate
        assertApproxEqAbs(vEth, 9_988e18, 1e5);
        uint256 usdcShares = shares * vUsdc / (vUsdc + vEth);
        uint256 ethShares = shares * vEth / (vUsdc + vEth);
        assertApproxEqAbs(vault.benefactorShares(alice), usdcShares + ethShares / 2, 2);
        assertApproxEqAbs(vault.benefactorShares(bob), ethShares / 2, 2);
        assertEq(vault.pendingOf(alice, ETH), 0.5 ether);
        assertEq(vault.pendingOf(alice, USDC_ADDR), 0);
        assertEq(vault.pendingOf(alice, WBTC_ADDR), 1e6);
        assertEq(vault.pendingOf(bob, ETH), 0.5 ether);
        // Touching alice collects exactly that and keeps the rest pending.
        _contributeEth(alice, 0.01 ether);
        assertApproxEqAbs(vault.benefactorShares(alice), usdcShares + ethShares / 2, 2);
        assertEq(vault.pendingOf(alice, ETH), 0.51 ether);
        assertEq(vault.pendingOf(alice, WBTC_ADDR), 1e6);
        _convert();
        assertEq(vault.pendingOf(alice, WBTC_ADDR) + vault.pendingOf(alice, ETH) + vault.pendingOf(bob, ETH), 0);
        _assertSolvent(vault);
    }

    /// @dev The IMD value each token realized in the last recorded conversion (TokenConverted).
    function _values(address a, address b) internal returns (uint256 va, uint256 vb) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 tc = keccak256("TokenConverted(uint256,address,uint256,uint256)");
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(vault) || logs[j].topics[0] != tc) continue;
            address t = address(uint160(uint256(logs[j].topics[2])));
            (, uint256 v) = abi.decode(logs[j].data, (uint256, uint256));
            if (t == a) va = v;
            if (t == b) vb = v;
        }
    }

    /// @dev Convert half of what is pending in ETH and in IMD; returns the shares the ETH part made.
    function _halveEthAndImd() internal returns (uint256) {
        vm.recordLogs();
        uint256 shares = _convertSome(
            _two(ETH, IMD_ADDR), _amts(vault.pendingByToken(ETH) / 2, vault.pendingByToken(IMD_ADDR) / 2)
        );
        (uint256 ve, uint256 vi) = _values(ETH, IMD_ADDR);
        return shares * ve / (ve + vi);
    }

    function test_ethLeg_oneSwapSharedByEthIn() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, usdc, 6000e6); // 2 ETH
        _contribute(carol, wbtc, 1e7); // 0.1 BTC = 3 ETH
        _contribute(dan, cbBtc, uint256(1e8) / 30); // ~1 ETH via v3
        uint256 calls = router.calls();
        _convert();
        assertEq(router.calls(), calls + 4, "three hops to ETH, one ETH -> IMD swap for all of it");
        uint256 sa = vault.benefactorShares(alice);
        assertApproxEqRel(vault.benefactorShares(bob) * 1e18 / sa, uint256(2e18) * 1e18 / 0.9988e18, 1e9);
        assertApproxEqRel(vault.benefactorShares(carol) * 1e18 / sa, uint256(3e18) * 1e18 / 0.9988e18, 1e9);
        assertApproxEqRel(vault.benefactorShares(dan) * 1e18 / sa, uint256(0.9999999e18) * 1e18 / 0.9988e18, 1e9);
        _assertSolvent(vault);
    }

    function test_orderIndependent() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, usdc, 6000e6);
        _contribute(carol, wbtc, 1e7);
        _contribute(dan, imdUsd, 1000e18);
        address[] memory toks = vault.openBatchTokens();
        uint256[] memory amts = new uint256[](4);
        for (uint256 i; i < 4; ++i) amts[i] = vault.pendingByToken(toks[i]);
        address[4] memory who = [alice, bob, carol, dan];

        uint256 snap = vm.snapshotState();
        _convertSome(toks, amts);
        uint256[4] memory fwd;
        for (uint256 i; i < 4; ++i) fwd[i] = vault.benefactorShares(who[i]);
        vm.revertToState(snap);

        // Reversed order.
        address[] memory rt = new address[](4);
        uint256[] memory ra = new uint256[](4);
        for (uint256 i; i < 4; ++i) (rt[i], ra[i]) = (toks[3 - i], amts[3 - i]);
        _convertSome(rt, ra);
        for (uint256 i; i < 4; ++i) assertEq(vault.benefactorShares(who[i]), fwd[i], "same shares in any order");
    }

    function test_griefing_contributionAfterQuoteDoesNotBreakTheCall() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, usdc, 3000e6);
        UniAlignmentVault.ConvertParams memory p = _params(vault); // the keeper's quote
        // Between the quote and landing: dust in a new token, a top-up of a token in the call, a new benefactor.
        address mallory = makeAddr("mallory");
        _contribute(mallory, wbtc, 1);
        _contributeEth(mallory, 0.001 ether);
        _contribute(carol, usdc, 1e6);
        vm.prank(keeper);
        vault.convertAndAddLiquidity(p);
        assertGt(vault.benefactorShares(alice), 0);
        assertGt(vault.benefactorShares(bob), 0);
        // Exactly what arrived later stays pending in total, spread pro rata over the token's benefactors.
        assertEq(vault.pendingOf(mallory, WBTC_ADDR), 1);
        assertApproxEqAbs(vault.pendingOf(mallory, ETH), uint256(0.001 ether) * 0.001 ether / 1.001 ether, 1);
        assertApproxEqAbs(vault.pendingOf(alice, ETH), uint256(1 ether) * 0.001 ether / 1.001 ether, 1);
        assertApproxEqAbs(vault.pendingOf(carol, USDC_ADDR), uint256(1e6) * 1e6 / 3001e6, 1);
        assertEq(vault.pendingByToken(ETH), 0.001 ether);
        assertEq(vault.pendingByToken(USDC_ADDR), 1e6);
        _assertSolvent(vault);
    }

    function test_partial_laterConversionTakesNoEarlierFees() public {
        _contributeEth(alice, 1 ether);
        _contributeEth(bob, 1 ether);
        _convertSome(_one(ETH), _amts(1 ether)); // half of each
        vault.accrueFees(100e18, 100e18);
        vault.collectFees();
        _contributeEth(carol, 1 ether); // joins after the fees
        _convert(); // alice's and bob's other halves, and carol's ETH
        (uint256 ia, uint256 ma,) = vault.claimable(alice);
        (uint256 ib, uint256 mb,) = vault.claimable(bob);
        (uint256 ic, uint256 mc,) = vault.claimable(carol);
        assertApproxEqAbs(ia, 49.5e18, 1e6);
        assertApproxEqAbs(ma, 49.5e18, 1e6);
        assertApproxEqAbs(ib, 49.5e18, 1e6);
        assertApproxEqAbs(mb, 49.5e18, 1e6);
        assertEq(ic + mc, 0, "carol's shares came after the fees");
        // New fees split by the share counts.
        vault.accrueFees(30e18, 0);
        vault.collectFees();
        (uint256 ia2,,) = vault.claimable(alice);
        (uint256 ic2,,) = vault.claimable(carol);
        assertApproxEqRel((ia2 - ia) * 1e18 / ic2, vault.benefactorShares(alice) * 1e18 / vault.benefactorShares(carol), 1e9);
        _assertSolvent(vault);
        // Claims pay out exactly the claimable amounts.
        vm.prank(alice);
        (uint256 io,,) = vault.claimFees(ClaimMode.TOKENS, 0);
        assertEq(io, ia2);
    }

    function test_partial_manyConversionsCollectedLazily() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, imd, 100_000e18); // a big IMD holder so each tiny ETH slice still makes liquidity
        uint256 total;
        for (uint256 i; i < 5; ++i) total += _halveEthAndImd();
        assertEq(vault.pendingOf(alice, ETH), 1 ether / 32, "1/32 of it left");
        assertApproxEqAbs(vault.benefactorShares(alice), total, 10, "five conversions, collected in one go");
        // Converting all that is left starts a new epoch; alice's record still pays out, and a new one starts clean.
        _convert();
        assertEq(vault.pendingOf(alice, ETH), 0);
        uint256 before = vault.benefactorShares(alice);
        assertGt(before, total);
        _contributeEth(alice, 1 ether);
        assertEq(vault.pendingOf(alice, ETH), 1 ether);
        assertEq(vault.benefactorShares(alice), before);
        _convert();
        assertGt(vault.benefactorShares(alice), before);
        _assertSolvent(vault);
    }

    function test_partial_tinyRemainderRescales() public {
        // Leave 1e-12 of a huge IMD balance: the pool's product rescales (scale + 1) and the balance carries over.
        _contribute(alice, imd, 1e30);
        _convertSome(_one(IMD_ADDR), _amts(1e30 - 1e18));
        assertEq(vault.pendingOf(alice, IMD_ADDR), 1e18);
        uint256 before = vault.benefactorShares(alice);
        _contribute(bob, imd, 1e22); // bob books in the new scale; alice's balance spans both
        uint256 shares = _convert();
        // 1e-14: shares are priced at totalShares / units, one more rounding than one share per unit.
        assertApproxEqAbs(vault.benefactorShares(alice) - before, shares * 1e18 / (1e22 + 1e18), shares / 1e14);
        assertApproxEqAbs(vault.benefactorShares(bob), shares * 1e22 / (1e22 + 1e18), shares / 1e14);
        assertEq(vault.pendingOf(alice, IMD_ADDR) + vault.pendingOf(bob, IMD_ADDR), 0);
        _assertSolvent(vault);
    }

    function test_partial_remainderTooSmallToRescaleIsDust() public {
        // 1e-19 of what was pending is left (too small for one rescale): the epoch restarts, that dust stays pending,
        // unowned.
        _contribute(alice, imd, 1e30);
        _convertSome(_one(IMD_ADDR), _amts(1e30 - 1e11));
        assertEq(vault.pendingOf(alice, IMD_ADDR), 0);
        assertEq(vault.pendingByToken(IMD_ADDR), 1e11);
        _contribute(bob, imd, 1e22);
        assertEq(vault.pendingOf(bob, IMD_ADDR), 1e22, "a new epoch: bob's balance is exact");
        _assertSolvent(vault);
    }

    function test_partial_imdRemainderStaysOutOfTheAdd() public {
        _contribute(carol, imd, 20_000e18);
        uint256 shares = _convertSome(_one(IMD_ADDR), _amts(10_000e18));
        assertApproxEqRel(shares, 5000e18, 0.02e18, "only the 10,000 converted went into the position");
        assertEq(vault.pendingOf(carol, IMD_ADDR), 10_000e18);
        _assertSolvent(vault);
    }

    // ═══ keeper reward ═══════════════════════════════════════════════════

    function test_reward_cappedAtOnePercentOfBatchEth() public {
        _contributeEth(alice, 0.05 ether);
        _convert();
        assertEq(keeper.balance, 0.0005 ether);
    }

    function test_reward_zeroWithoutEth() public {
        _contribute(alice, usdc, 3000e6);
        _convert();
        assertEq(keeper.balance, 0);
    }

    function test_reward_rejectedGoesToHolders() public {
        _contributeEth(alice, 1 ether);
        _convert();
        RefusingKeeper rk = new RefusingKeeper();
        registry.setConversionKeeper(address(rk));
        _contributeEth(bob, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        rk.convert(vault, p);
        (,, uint256 ethA) = vault.claimable(alice);
        (,, uint256 ethB) = vault.claimable(bob);
        assertApproxEqAbs(ethA + ethB, 0.0012 ether, 2);
        assertGt(ethA, 0);
        _assertSolvent(vault);
    }

    // ═══ ETH dust ════════════════════════════════════════════════════════

    function test_routerRefund_isDustForCurrentHolders() public {
        _contributeEth(alice, 1 ether);
        _convert();
        router.setRefundExtra(0.3 ether); // the router refunds stray ETH to the payer after an ETH-in swap
        _contributeEth(bob, 1 ether);
        _convert();
        (,, uint256 ethA) = vault.claimable(alice);
        (,, uint256 ethB) = vault.claimable(bob);
        assertApproxEqAbs(ethA, 0.3 ether, 1, "refund booked before bob's shares");
        assertEq(ethB, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        (,, uint256 ethOut) = vault.claimFees(ClaimMode.TOKENS, 0);
        assertEq(alice.balance - before, ethOut);
        _assertSolvent(vault);
    }

    // ═══ fees ════════════════════════════════════════════════════════════

    function _seedTwoHolders() internal {
        _contributeEth(alice, 1 ether);
        _contributeEth(bob, 3 ether);
        _convert();
    }

    function test_convert_strayInferImdLiftsHoldersNotTheNextBatch() public {
        // Twin vaults, same history; one holds 100 IMD of strays (INFER + IMD sent in) when a tiny batch converts.
        TestableUniAlignmentVault twin = _newVault();
        _contributeEth(alice, 1 ether);
        _contributeEth(bob, 3 ether);
        _convert();
        _giveEth(alice, 1 ether, twin);
        _giveEth(bob, 3 ether, twin);
        _convert(twin);

        infer.mint(address(vault), 50e18);
        imd.mint(address(vault), 50e18);
        _contributeEth(dan, 0.01 ether);
        _giveEth(dan, 0.01 ether, twin);
        uint256 shares = _convert();
        uint256 twinShares = _convert(twin);

        // dan's slice of the position is what his own value bought; the strays go to the holders before him.
        assertApproxEqRel(
            shares * vault.totalLPUnits() / vault.totalShares(),
            twinShares * twin.totalLPUnits() / twin.totalShares(),
            0.001e18,
            "the strays don't go to the batch"
        );
        assertLt(vault.totalShares(), vault.totalLPUnits(), "the strays raised every share");
        assertGt(vault.totalLPUnits() - twin.totalLPUnits(), 0);
        _assertSolvent(vault);
    }

    function test_convert_largeBatchTakesNoneOfTheStrays() public {
        // A batch as large as the position: with the strays priced in before its shares, it still gets none of them.
        TestableUniAlignmentVault twin = _newVault();
        _contributeEth(alice, 1 ether);
        _convert();
        _giveEth(alice, 1 ether, twin);
        _convert(twin);
        infer.mint(address(vault), 2500e18);
        imd.mint(address(vault), 2500e18);
        _contributeEth(bob, 1 ether);
        _giveEth(bob, 1 ether, twin);
        uint256 shares = _convert();
        uint256 twinShares = _convert(twin);
        // Shares cost more once the strays lift the price, so compare what bob's shares are worth in liquidity units.
        uint256 bobUnits = shares * vault.totalLPUnits() / vault.totalShares();
        uint256 twinBobUnits = twinShares * twin.totalLPUnits() / twin.totalShares();
        assertApproxEqRel(bobUnits, twinBobUnits, 0.001e18, "bob's slice as if no strays");
        // alice's shares now hold her units plus all the strays' liquidity
        uint256 aliceUnits = vault.benefactorShares(alice) * vault.totalLPUnits() / vault.totalShares();
        uint256 twinAliceUnits = twin.benefactorShares(alice) * twin.totalLPUnits() / twin.totalShares();
        assertGt(aliceUnits, twinAliceUnits + 2000e18, "alice keeps the strays");
        _assertSolvent(vault);
    }

    function test_convert_firstBatchTakesStraysToo() public {
        infer.mint(address(vault), 5e18);
        imd.mint(address(vault), 5e18);
        _contributeEth(alice, 1 ether);
        uint256 shares = _convert();
        assertEq(shares, vault.totalLPUnits(), "nobody else to own them");
    }

    function test_fees_proRataWithProtocolCut() public {
        _seedTwoHolders();
        vault.accrueFees(100e18, 200e18); // INFER, IMD (INFER is currency0)
        vault.collectFees();
        (uint256 ia, uint256 ma,) = vault.claimable(alice);
        (uint256 ib, uint256 mb,) = vault.claimable(bob);
        assertApproxEqAbs(ia + ib, 99e18, 1e3);
        assertApproxEqAbs(ma + mb, 198e18, 1e3);
        uint256 sa = vault.benefactorShares(alice);
        uint256 sb = vault.benefactorShares(bob);
        assertApproxEqRel(ia * 1e18 / ib, sa * 1e18 / sb, 1e9);
        (,,, uint256 protInfer) = vault.feeStats(INFER_ADDR);
        (,,, uint256 protImd) = vault.feeStats(IMD_ADDR);
        assertEq(protInfer, 1e18);
        assertEq(protImd, 2e18);
        _assertSolvent(vault);
    }

    function test_fees_notDilutedByLaterBatch() public {
        _contributeEth(alice, 1 ether);
        _convert();
        vault.accrueFees(50e18, 50e18);
        // Bob joins; the conversion books alice's yield before minting bob's shares.
        _contributeEth(bob, 10 ether);
        _convert();
        (uint256 ia, uint256 ma,) = vault.claimable(alice);
        (uint256 ib, uint256 mb,) = vault.claimable(bob);
        assertApproxEqAbs(ia, 49.5e18, 2);
        assertApproxEqAbs(ma, 49.5e18, 2);
        assertEq(ib + mb, 0);
    }

    function test_fees_survivesRecontribution() public {
        _contributeEth(alice, 1 ether);
        _convert();
        vault.accrueFees(10e18, 10e18);
        vault.collectFees();
        (uint256 i0, uint256 m0,) = vault.claimable(alice);
        _contributeEth(alice, 1 ether);
        (uint256 i1, uint256 m1,) = vault.claimable(alice);
        assertEq(i1, i0);
        assertEq(m1, m0);
    }

    function test_fees_collectionIntervalOnClaim() public {
        _seedTwoHolders();
        vm.warp(block.timestamp + 1 days);
        vault.accrueFees(10e18, 10e18);
        vm.prank(alice);
        (uint256 inferOut, uint256 imdOut,) = vault.claimFees(ClaimMode.TOKENS, 0); // collects (interval passed)
        assertGt(inferOut, 0);
        assertGt(imdOut, 0);
        vault.accrueFees(10e18, 10e18);
        vm.prank(bob);
        (uint256 ib, uint256 mb,) = vault.claimFees(ClaimMode.TOKENS, 0); // first round only (no new collect)
        assertApproxEqAbs(ib, 9.9e18 * 3 / 4, 1e12);
        assertApproxEqAbs(mb, 9.9e18 * 3 / 4, 1e12);
    }

    // ═══ claims ══════════════════════════════════════════════════════════

    function test_claimTokens() public {
        _seedTwoHolders();
        vault.accrueFees(100e18, 100e18);
        vault.collectFees();
        (uint256 ci, uint256 cm,) = vault.claimable(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit IAlignmentVault.FeesClaimed(alice, ClaimMode.TOKENS, ci, cm, 0);
        vm.prank(alice);
        (uint256 io, uint256 mo, uint256 eo) = vault.claimFees(ClaimMode.TOKENS, 0);
        assertEq(infer.balanceOf(alice), io);
        assertEq(imd.balanceOf(alice), mo);
        assertEq(eo, 0);
        (ci, cm,) = vault.claimable(alice);
        assertEq(ci + cm, 0);
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.claimFees(ClaimMode.TOKENS, 0);
        vm.prank(carol);
        vm.expectRevert(UniAlignmentVault.NoShares.selector);
        vault.claimFees(ClaimMode.TOKENS, 0);
        _assertSolvent(vault);
    }

    function test_claimEth() public {
        _seedTwoHolders();
        vault.accrueFees(100e18, 100e18);
        vault.collectFees();
        (uint256 ci, uint256 cm,) = vault.claimable(alice);
        // INFER -> IMD at 1:1 less 1.25%, then IMD -> ETH at 1e-4.
        uint256 expected = (ci * 987_500 / 1e6 + cm) / 10_000;
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.ZeroFloor.selector);
        vault.claimFees(ClaimMode.ETH, 0);
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.claimFees(ClaimMode.ETH, expected + 1e12);
        uint256 before = alice.balance;
        vm.prank(alice);
        (,, uint256 eo) = vault.claimFees(ClaimMode.ETH, expected - 1e12);
        assertApproxEqAbs(eo, expected, 1e9);
        assertEq(alice.balance - before, eo);
        assertEq(infer.balanceOf(alice) + imd.balanceOf(alice), 0);
        _assertSolvent(vault);
    }

    function test_claimEth_refusingRecipientReverts() public {
        Benefactor c = new Benefactor();
        vm.deal(address(c), 1 ether);
        vm.prank(address(c));
        vault.receiveContribution{value: 1 ether}(Currency.wrap(ETH), 1 ether, address(c));
        _convert();
        vault.accrueFees(10e18, 10e18);
        vault.collectFees();
        c.setRefuse(true);
        vm.expectRevert(UniAlignmentVault.TransferFailed.selector);
        c.claim(vault, ClaimMode.ETH, 1);
        // Tokens still work for a contract that can't take ETH.
        (uint256 io, uint256 mo,) = c.claim(vault, ClaimMode.TOKENS, 0);
        assertGt(io + mo, 0);
    }

    function test_claimReinvest_issuesSharesAtLiquidityPrice() public {
        _seedTwoHolders();
        vault.accrueFees(100e18, 100e18);
        vault.collectFees();
        uint256 sa = vault.benefactorShares(alice);
        uint256 sb = vault.benefactorShares(bob);
        uint256 total = vault.totalShares();
        uint256 lp = vault.totalLPUnits();
        (uint256 ib0, uint256 mb0,) = vault.claimable(bob);
        (uint256 ci, uint256 cm,) = vault.claimable(alice);

        vm.prank(alice);
        (uint256 usedI, uint256 usedM,) = vault.claimFees(ClaimMode.REINVEST, 1);
        uint256 minted = vault.benefactorShares(alice) - sa;
        assertGt(minted, 0);
        assertEq(vault.totalShares(), total + minted);
        assertEq(vault.totalLPUnits(), lp + minted, "1 share = 1 liquidity unit");
        // At 1:1 full range, liquidity ~ each side's amount.
        assertApproxEqRel(minted, (ci + cm) / 2, 0.01e18);
        assertLe(usedI, ci);
        assertLe(usedM, cm);
        // Leftover of the add stays claimable; bob is untouched.
        (uint256 li, uint256 lm,) = vault.claimable(alice);
        assertLt(li + lm, (ci + cm) / 100);
        assertEq(vault.benefactorShares(bob), sb);
        (uint256 ib1, uint256 mb1,) = vault.claimable(bob);
        assertEq(ib1, ib0);
        assertEq(mb1, mb0);
        _assertSolvent(vault);

        // New fees split by the new share counts.
        vault.accrueFees(10e18, 0);
        vault.collectFees();
        (uint256 ia2,,) = vault.claimable(alice);
        (uint256 ib2,,) = vault.claimable(bob);
        assertApproxEqRel(
            (ia2 - li) * 1e18 / (ib2 - ib1), vault.benefactorShares(alice) * 1e18 / sb, 1e12
        );
    }

    function test_claimReinvest_minShares() public {
        _seedTwoHolders();
        vault.accrueFees(10e18, 10e18);
        vault.collectFees();
        vm.prank(alice);
        vm.expectRevert(UniAlignmentVault.InsufficientOutput.selector);
        vault.claimFees(ClaimMode.REINVEST, 1e30);
    }

    function test_claimReinvest_booksPendingYieldFirst() public {
        _seedTwoHolders();
        vault.accrueFees(40e18, 40e18); // uncollected yet
        uint256 sb = vault.benefactorShares(bob);
        uint256 total = vault.totalShares();
        vm.prank(alice);
        vault.claimFees(ClaimMode.REINVEST, 1);
        (uint256 ib, uint256 mb,) = vault.claimable(bob);
        assertApproxEqAbs(ib, 39.6e18 * sb / total, 1e6, "bob's share of the pre-reinvest yield");
        assertApproxEqAbs(mb, 39.6e18 * sb / total, 1e6);
    }

    function test_claimReinvest_oneSidedFees() public {
        _seedTwoHolders();
        vault.accrueFees(0, 100e18); // only IMD
        vault.collectFees();
        uint256 sa = vault.benefactorShares(alice);
        vm.prank(alice);
        vault.claimFees(ClaimMode.REINVEST, 1);
        assertGt(vault.benefactorShares(alice), sa);
        _assertSolvent(vault);
    }

    // ═══ delegation ══════════════════════════════════════════════════════

    function test_delegate_receivesClaims() public {
        _seedTwoHolders();
        vault.accrueFees(10e18, 10e18);
        vault.collectFees();
        vm.prank(carol);
        vm.expectRevert(UniAlignmentVault.NotBenefactor.selector);
        vault.delegateBenefactor(dan);
        vm.prank(alice);
        vault.delegateBenefactor(dan);
        assertEq(vault.getBenefactorDelegate(alice), dan);
        vm.prank(alice);
        (uint256 io, uint256 mo,) = vault.claimFees(ClaimMode.TOKENS, 0);
        assertEq(infer.balanceOf(dan), io);
        assertEq(imd.balanceOf(dan), mo);
        assertEq(infer.balanceOf(alice), 0);
    }

    function test_claimFeesAsDelegate_tokensAndEth() public {
        _seedTwoHolders();
        vault.accrueFees(10e18, 10e18);
        vault.collectFees();
        vm.prank(alice);
        vault.delegateBenefactor(dan);
        vm.prank(bob);
        vault.delegateBenefactor(dan);
        address[] memory bs = new address[](2);
        (bs[0], bs[1]) = (alice, bob);

        vm.prank(carol);
        vm.expectRevert(UniAlignmentVault.NotDelegate.selector);
        vault.claimFeesAsDelegate(bs, ClaimMode.TOKENS, 0);
        vm.prank(dan);
        vm.expectRevert(UniAlignmentVault.BadParams.selector);
        vault.claimFeesAsDelegate(bs, ClaimMode.REINVEST, 0);

        address[] memory one = new address[](1);
        one[0] = alice;
        vm.prank(dan);
        (uint256 io, uint256 mo,) = vault.claimFeesAsDelegate(one, ClaimMode.TOKENS, 0);
        assertEq(infer.balanceOf(dan), io);
        assertEq(imd.balanceOf(dan), mo);

        one[0] = bob;
        uint256 before = dan.balance;
        vm.prank(dan);
        (,, uint256 eo) = vault.claimFeesAsDelegate(one, ClaimMode.ETH, 1);
        assertEq(dan.balance - before, eo);
        assertGt(eo, 0);
        _assertSolvent(vault);
    }

    // ═══ protocol cut ════════════════════════════════════════════════════

    function test_withdrawProtocolFees_perToken() public {
        _seedTwoHolders();
        vault.accrueFees(100e18, 300e18);
        vault.collectFees();
        vault.withdrawProtocolFees(INFER_ADDR);
        vault.withdrawProtocolFees(IMD_ADDR);
        assertEq(infer.balanceOf(treasury), 1e18);
        assertEq(imd.balanceOf(treasury), 3e18);
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.withdrawProtocolFees(IMD_ADDR);
        vm.expectRevert(UniAlignmentVault.NoFeesToClaim.selector);
        vault.withdrawProtocolFees(ETH);
        vm.expectRevert(UniAlignmentVault.UnknownFeeToken.selector);
        vault.withdrawProtocolFees(USDC_ADDR);
        _assertSolvent(vault);
    }

    function test_withdrawProtocolFees_followsRegistryTreasury() public {
        _seedTwoHolders();
        vault.accrueFees(100e18, 0);
        vault.collectFees();
        address t2 = makeAddr("t2");
        registry.setTreasury(t2);
        assertEq(vault.protocolTreasury(), t2);
        vault.withdrawProtocolFees(INFER_ADDR);
        assertEq(infer.balanceOf(t2), 1e18);
    }

    // ═══ leftovers ═══════════════════════════════════════════════════════

    function test_leftoversFeedNextBatch() public {
        _contribute(alice, imd, 10_000e18);
        _convert();
        // Nothing owed in IMD/INFER beyond fees; a leftover is free and goes into the next add.
        (, uint256 dist, uint256 claimed, uint256 prot) = vault.feeStats(IMD_ADDR);
        uint256 freeImd = imd.balanceOf(address(vault)) - (dist - claimed + prot);
        uint256 freeInfer = infer.balanceOf(address(vault));
        assertLt(freeImd + freeInfer, 100e18, "small leftover");
        _contribute(bob, imd, 10_000e18);
        _convert();
        assertLt(imd.balanceOf(address(vault)) + infer.balanceOf(address(vault)), 100e18);
        _assertSolvent(vault);
    }

    // ═══ init and config ═════════════════════════════════════════════════

    function _cloneImpl() internal returns (TestableUniAlignmentVault v) {
        v = TestableUniAlignmentVault(payable(LibClone.clone(address(new TestableUniAlignmentVault()))));
    }

    function _init(TestableUniAlignmentVault v, PoolKey memory k, uint256 target) internal {
        v.initialize(
            address(this),
            IPoolManager(POOL_MANAGER),
            address(router),
            IMiyaRegistry(address(registry)),
            IVaultConfig(address(factory)),
            INFER_ADDR,
            IMD_ADDR,
            k,
            target
        );
    }

    function test_init_onceOnly() public {
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        _init(vault, key, 0);
    }

    function test_init_rejectsHookWithSwapPermissions() public {
        PoolKey memory k = key;
        k.hooks = IHooks(address(uint160(0x1000000000000000000000000000000000000080))); // beforeSwap
        TestableUniAlignmentVault v = _cloneImpl();
        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        _init(v, k, 0);
        k.hooks = IHooks(address(uint160(0x1000000000000000000000000000000000000800))); // beforeAddLiquidity
        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        _init(v, k, 0);
    }

    function test_init_rejectsWrongPairOrDynamicFee() public {
        TestableUniAlignmentVault v = _cloneImpl();
        PoolKey memory k = key;
        k.currency1 = Currency.wrap(USDC_ADDR);
        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        _init(v, k, 0);
        k = key;
        k.fee = 0x800000;
        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        _init(v, k, 0);
        k = key;
        (k.currency0, k.currency1) = (k.currency1, k.currency0);
        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        _init(v, k, 0);
    }

    function test_init_hooklessKeyAccepted() public {
        TestableUniAlignmentVault v = _cloneImpl();
        PoolKey memory k = key;
        k.hooks = IHooks(address(0));
        _init(v, k, 0);
        assertEq(address(v.alignmentPoolKey().hooks), address(0));
    }

    function test_init_targetChecks() public {
        TestableUniAlignmentVault v = _cloneImpl();
        vm.expectRevert(UniAlignmentVault.TargetNotActive.selector);
        _init(v, key, 7);
        address[] memory t = new address[](1);
        t[0] = USDC_ADDR;
        uint256 id = registry.addTarget("other", t);
        vm.expectRevert(UniAlignmentVault.TokenNotInTarget.selector);
        _init(v, key, id);
    }

    function test_info() public view {
        assertTrue(vault.supportsCapability(keccak256("MULTI_ASSET")));
        assertTrue(vault.supportsCapability(keccak256("YIELD_GENERATION")));
        assertTrue(vault.supportsCapability(keccak256("BENEFACTOR_DELEGATION")));
        assertFalse(vault.supportsCapability(keccak256("SHARE_TRANSFER")));
        assertEq(vault.vaultType(), "UniswapV4LP");
        assertEq(vault.tickLower(), -887220);
        assertEq(vault.tickUpper(), 887220);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vault.unlockCallback("");
    }
}
