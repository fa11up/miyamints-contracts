// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {SwapCall} from "../../src/vaults/uni/IVaultConfig.sol";
import {ClaimMode} from "../../src/interfaces/IAlignmentVault.sol";
import {MockToken, MockAggregator, SeizableToken, StickyAllowanceToken} from "./mocks/VaultMocks.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice The guards on the keeper's aggregator calls (VaultSwaps): each one has a call that fails on it. The keeper
///         chooses the calldata; MockAggregator is an allowlisted target that misbehaves in one way at a time (a 0x
///         Settler, or a compromised router, stand-in).
contract UniAlignmentVaultSwapsTest is VaultTestBase {
    MockAggregator agg;
    SeizableToken seize;
    StickyAllowanceToken sticky;

    function setUp() public override {
        super.setUp();
        agg = new MockAggregator();
        vm.deal(address(agg), 1e30);
        agg.setRate(ETH, IMD_ADDR, R_ETH_IMD);
        agg.setRate(USDC_ADDR, ETH, R_USDC_ETH);
        agg.setRate(WBTC_ADDR, ETH, R_BTC_ETH);
        agg.setRate(IMDUSD_ADDR, IMD_ADDR, R_IMDUSD_IMD);
        agg.setRate(USDC_ADDR, IMD_ADDR, R_USDC_ETH * R_ETH_IMD / 1e18);
        seize = new SeizableToken();
        sticky = new StickyAllowanceToken();
        agg.setRate(address(seize), ETH, 1e15);
        agg.setRate(address(sticky), ETH, 1e15);
        router.setRate(address(seize), ETH, 1e15);
        registry.setPaymentToken(address(seize), true);
        registry.setPaymentToken(address(sticky), true);
        factory.setSwapTarget(address(agg), true);
    }

    /// @dev A swap of exactly `amount` of `token` to `out` through the aggregator, floor `minOut`.
    function _agg(address token, uint256 amount, address out, uint256 minOut) internal view returns (SwapCall memory) {
        return SwapCall(address(agg), out, abi.encodeCall(MockAggregator.swap, (token, amount, out)), minOut);
    }

    function _one(address token, uint256 amount, SwapCall memory s)
        internal
        view
        returns (UniAlignmentVault.ConvertParams memory p)
    {
        p = _paramsFor(_one(token), _amts(amount));
        p.swaps[0] = s;
    }

    function _expectRevert(UniAlignmentVault.ConvertParams memory p, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        vault.convertAndAddLiquidity(p);
    }

    function _expectRevert(UniAlignmentVault.ConvertParams memory p, bytes4 sel) internal {
        _expectRevert(p, abi.encodeWithSelector(sel));
    }

    function _run(UniAlignmentVault.ConvertParams memory p) internal returns (uint256) {
        vm.prank(keeper);
        return vault.convertAndAddLiquidity(p);
    }

    // ── the happy path through an aggregator ────────────────────────────────

    function test_aggregator_erc20ToEth_andLeg() public {
        _contribute(alice, usdc, 3000e6);
        _contributeEth(bob, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        p.swaps[0] = _agg(USDC_ADDR, 3000e6, ETH, 0.99 ether);
        p.ethLeg = _agg(ETH, 0, IMD_ADDR, 19_987e18);
        // The leg is sent exactly the batch's ETH: bob's 1 ETH less the 0.0012 reward, plus the USDC's ETH out (1 ETH
        // less a wei at the mock's rate).
        vm.expectCall(address(agg), 1.9988 ether - 1, abi.encodeCall(MockAggregator.swap, (ETH, 0, IMD_ADDR)));
        // The USDC swap: an approval of exactly the amount, reset to 0 after.
        vm.expectCall(USDC_ADDR, abi.encodeCall(MockToken.approve, (address(agg), 3000e6)));
        vm.expectCall(USDC_ADDR, abi.encodeCall(MockToken.approve, (address(agg), 0)));
        uint256 shares = _run(p);
        assertApproxEqAbs(vault.benefactorShares(alice) + vault.benefactorShares(bob), shares, 2);
        assertApproxEqRel(vault.benefactorShares(alice) * 1e18 / vault.benefactorShares(bob), uint256(1e36) / 0.9988e18, 1e9);
        assertEq(usdc.allowance(address(vault), address(agg)), 0);
        _assertSolvent(vault);
    }

    function test_aggregator_erc20ToImd_valuedByItsOwnOut() public {
        // USDC straight to IMD (e.g. a 0x route): valued by its own IMD out, no ETH leg needed.
        _contribute(alice, usdc, 3000e6);
        _contribute(bob, imd, 10_000e18);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        p.swaps[0] = _agg(USDC_ADDR, 3000e6, IMD_ADDR, 9_999e18);
        p.ethLeg = SwapCall(address(0), address(0), "", 0); // no ETH reaches it: ignored
        _run(p);
        assertApproxEqRel(vault.benefactorShares(alice), vault.benefactorShares(bob), 1e9, "10,000 IMD each");
        _assertSolvent(vault);
    }

    function test_mixedTargets_zRouterAndAggregatorInOneBatch() public {
        _contribute(alice, usdc, 3000e6);
        _contribute(bob, wbtc, uint256(1e8) / 30);
        _contribute(carol, imdUsd, 3334e18);
        UniAlignmentVault.ConvertParams memory p = _params(vault); // zRouter calldata for all
        p.swaps[0] = _agg(USDC_ADDR, 3000e6, ETH, 1); // USDC via the aggregator instead
        _run(p);
        assertApproxEqRel(vault.benefactorShares(alice), vault.benefactorShares(bob), 1e14);
        assertApproxEqRel(vault.benefactorShares(carol), vault.benefactorShares(alice), 1e15);
        _assertSolvent(vault);
    }

    // ── floors ──────────────────────────────────────────────────────────────

    function test_guard_zeroFloorRefused() public {
        _contribute(alice, usdc, 3000e6);
        _contributeEth(bob, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        p.swaps[0].minOut = 0;
        _expectRevert(p, UniAlignmentVault.ZeroFloor.selector);
        p = _params(vault);
        p.ethLeg.minOut = 0;
        _expectRevert(p, UniAlignmentVault.ZeroFloor.selector);
    }

    function test_guard_underDeliveryRefused() public {
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.UnderDeliver);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 0.99 ether)), UniAlignmentVault.InsufficientOutput.selector);
        // Its floor met, the half-delivery would pass: the floor is the protection (keeper trust), as documented.
        _run(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 0.49 ether)));
    }

    function test_guard_outputSentElsewhereRefused() public {
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.SendElsewhere);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)), UniAlignmentVault.InsufficientOutput.selector);
        _contribute(bob, imdUsd, 1000e18);
        _expectRevert(
            _one(IMDUSD_ADDR, 1000e18, _agg(IMDUSD_ADDR, 1000e18, IMD_ADDR, 1)), UniAlignmentVault.InsufficientOutput.selector
        );
    }

    // ── the input: exactly the amount, no more, no less ─────────────────────

    function test_guard_pullLessRefused() public {
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.PullLess);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)), UniAlignmentVault.InputMismatch.selector);
    }

    function test_guard_refundOfUnspentInputRefused() public {
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.RefundInput);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)), UniAlignmentVault.InputMismatch.selector);
    }

    function test_guard_overPullRefused() public {
        // A target that takes more than it was approved for (here via the token's admin seize) is caught by the
        // balance check even though the approval was exact.
        _contribute(alice, seize, 2e18);
        agg.setMode(MockAggregator.Mode.OverPull);
        _expectRevert(
            _one(address(seize), 1e18, _agg(address(seize), 1e18, ETH, 1)), UniAlignmentVault.InputMismatch.selector
        );
    }

    function test_guard_pullBeyondApprovalFails() public {
        // The approval is exactly the amount: pulling one more unit fails in the token itself.
        _contribute(alice, usdc, 6000e6); // the vault holds more than the swap's amount
        agg.setMode(MockAggregator.Mode.PullMore);
        vm.prank(keeper);
        vm.expectRevert(); // MockToken allowance underflow
        vault.convertAndAddLiquidity(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)));
    }

    function test_guard_approvalResetAfterTheCall() public {
        // A token whose transferFrom leaves the allowance in place: the vault still ends with none.
        _contribute(alice, sticky, 1e18);
        _run(_one(address(sticky), 1e18, _agg(address(sticky), 1e18, ETH, 1)));
        assertEq(sticky.allowance(address(vault), address(agg)), 0, "approval reset");
        assertEq(sticky.balanceOf(address(vault)), 0);
    }

    function test_guard_cannotTouchOtherPendingTokens() public {
        // SEIZE stays pending for bob; the USDC swap's target takes 1 unit of it: the batch reverts (solvency).
        _contribute(bob, seize, 1e18);
        _contribute(alice, usdc, 3000e6);
        agg.setOther(address(seize));
        agg.setMode(MockAggregator.Mode.SeizeOther);
        _expectRevert(
            _one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)),
            abi.encodeWithSelector(UniAlignmentVault.Insolvent.selector, address(seize))
        );
    }

    // ── targets and outputs ─────────────────────────────────────────────────

    function test_guard_targetMustBeAllowlisted() public {
        _contribute(alice, usdc, 3000e6);
        MockAggregator rogue = new MockAggregator();
        rogue.setRate(USDC_ADDR, ETH, R_USDC_ETH);
        vm.deal(address(rogue), 10 ether);
        SwapCall memory s = SwapCall(address(rogue), ETH, abi.encodeCall(MockAggregator.swap, (USDC_ADDR, 3000e6, ETH)), 1);
        _expectRevert(
            _one(USDC_ADDR, 3000e6, s), abi.encodeWithSelector(UniAlignmentVault.SwapTargetNotAllowed.selector, address(rogue))
        );
        // A token as a target (e.g. calldata "transfer(keeper, all)") is never allowlisted.
        s = SwapCall(USDC_ADDR, ETH, abi.encodeCall(MockToken.transfer, (keeper, 3000e6)), 1);
        _expectRevert(
            _one(USDC_ADDR, 3000e6, s), abi.encodeWithSelector(UniAlignmentVault.SwapTargetNotAllowed.selector, USDC_ADDR)
        );
        // The leg too.
        _contributeEth(bob, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _paramsFor(_one(ETH), _amts(1 ether));
        p.ethLeg.target = address(rogue);
        _expectRevert(p, abi.encodeWithSelector(UniAlignmentVault.SwapTargetNotAllowed.selector, address(rogue)));
    }

    function test_guard_outputMustBeEthOrImd_legMustBeImd() public {
        _contribute(alice, usdc, 3000e6);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, WBTC_ADDR, 1)), UniAlignmentVault.BadSwapOutput.selector);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, INFER_ADDR, 1)), UniAlignmentVault.BadSwapOutput.selector);
        _contributeEth(bob, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _paramsFor(_one(ETH), _amts(1 ether));
        p.ethLeg.tokenOut = ETH;
        _expectRevert(p, UniAlignmentVault.BadSwapOutput.selector);
    }

    function test_guard_targetRevertBubbles() public {
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.Revert);
        _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)), bytes("MockAggregator: no route"));
    }

    // ── reentrancy ──────────────────────────────────────────────────────────

    function test_guard_reentryRefused() public {
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.Reenter);
        bytes[3] memory calls = [
            abi.encodeCall(UniAlignmentVault.collectFees, ()),
            abi.encodeCall(UniAlignmentVault.claimFees, (ClaimMode.TOKENS, 0)),
            abi.encodeCall(UniAlignmentVault.receiveContribution, (Currency.wrap(USDC_ADDR), 1e6, address(agg)))
        ];
        for (uint256 i; i < 3; ++i) {
            agg.setReenterCall(calls[i]);
            _expectRevert(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)), ReentrancyGuard.Reentrancy.selector);
        }
        // A nested conversion: the keeper check passes for nobody but the keeper, and the guard stops it anyway.
        registry.setConversionKeeper(address(agg));
        agg.setReenterCall(abi.encodeCall(UniAlignmentVault.convertAndAddLiquidity, (_params(vault))));
        vm.prank(address(agg));
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        vault.convertAndAddLiquidity(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1)));
    }

    function test_guard_ethSentDuringASwapIsNotAContribution() public {
        // ETH the target sends the vault mid-swap lands in receive() while the swap runs: never booked as anyone's
        // contribution. On an ETH-out swap it counts as that swap's output (measured by balance).
        _contribute(alice, usdc, 3000e6);
        agg.setMode(MockAggregator.Mode.ReturnEth);
        agg.setExtraEth(0.5 ether);
        vm.recordLogs();
        _run(_one(USDC_ADDR, 3000e6, _agg(USDC_ADDR, 3000e6, ETH, 1.49 ether)));
        assertEq(vault.pendingOf(address(agg), ETH), 0);
        assertEq(vault.pendingByToken(ETH), 0);
        (, uint256 imdValue) = _value(USDC_ADDR);
        assertApproxEqAbs(imdValue, 15_000e18, 1e5, "1 ETH out + 0.5 ETH sent along, both through the leg");
        _assertSolvent(vault);
    }

    // ── ETH handed back by the leg ──────────────────────────────────────────

    function test_ethLeg_refundIsDustForHoldersNotLegInput() public {
        _contributeEth(alice, 1 ether);
        _convert(); // alice holds every share
        _contribute(bob, usdc, 3000e6);
        _contributeEth(carol, 1 ether);
        UniAlignmentVault.ConvertParams memory p = _params(vault);
        // The leg's target hands 0.3 ETH back (an unspent-input refund, or a router's stray balance).
        p.ethLeg = _agg(ETH, 0, IMD_ADDR, 1);
        agg.setMode(MockAggregator.Mode.ReturnEth);
        agg.setExtraEth(0.3 ether);
        vm.recordLogs();
        _run(p);
        // The leg sold the batch's 1.9988 ETH; what came back went to the holders before the batch, not to its
        // tokens, and was not counted as ETH in.
        (uint256 ethIn, uint256 imdOut) = _leg();
        assertEq(ethIn, 1.9988 ether - 1); // USDC's 1 ETH out is a wei short at the mock's rate
        assertApproxEqAbs(imdOut, 19_988e18, 1e5);
        (,, uint256 ethA) = vault.claimable(alice);
        (,, uint256 ethB) = vault.claimable(bob);
        (,, uint256 ethC) = vault.claimable(carol);
        assertApproxEqAbs(ethA, 0.3 ether, 1);
        assertEq(ethB + ethC, 0);
        _assertSolvent(vault);
    }

    // ── fairness: the order of tokens changes nothing ───────────────────────

    address[4] internal _toks;
    address[4] internal _who;
    uint256[4] internal _amt;

    function test_fairness_everyPermutationGivesTheSameValues() public {
        _contributeEth(alice, 1 ether);
        _contribute(bob, usdc, 6000e6);
        _contribute(carol, wbtc, 1e7);
        _contribute(dan, imdUsd, 1000e18);
        _toks = [ETH, USDC_ADDR, WBTC_ADDR, IMDUSD_ADDR];
        _who = [alice, bob, carol, dan];
        for (uint256 i; i < 4; ++i) _amt[i] = vault.pendingByToken(_toks[i]);

        (uint256[4] memory refShares, uint256[4] memory refValue) = _convertPerm(0);
        for (uint256 perm = 1; perm < 24; ++perm) {
            (uint256[4] memory s, uint256[4] memory v) = _convertPerm(perm);
            for (uint256 i; i < 4; ++i) {
                assertEq(s[i], refShares[i], "same shares in every order");
                assertEq(v[i], refValue[i], "same IMD value in every order");
            }
        }
        assertGt(refShares[0], 0);
    }

    /// @dev Convert the four tokens in permutation `perm` (USDC through the aggregator, the rest through zRouter: two
    ///      targets in one batch), read each benefactor's shares and each token's value, and roll back.
    function _convertPerm(uint256 perm) internal returns (uint256[4] memory shares, uint256[4] memory values) {
        uint256 snap = vm.snapshotState();
        uint256[4] memory order = _perm(perm);
        address[] memory t = new address[](4);
        uint256[] memory a = new uint256[](4);
        for (uint256 i; i < 4; ++i) (t[i], a[i]) = (_toks[order[i]], _amt[order[i]]);
        UniAlignmentVault.ConvertParams memory p = _paramsFor(t, a);
        for (uint256 i; i < 4; ++i) {
            if (t[i] == USDC_ADDR) p.swaps[i] = _agg(USDC_ADDR, a[i], ETH, 1);
        }
        vm.recordLogs();
        _run(p);
        for (uint256 i; i < 4; ++i) {
            (, values[i]) = _value(_toks[i]);
            shares[i] = vault.benefactorShares(_who[i]);
        }
        vm.revertToState(snap);
    }

    // ── ETH claims use zRouter on the factory's pool, not the keeper's targets ──

    function test_claimEth_worksWithoutZRouterAllowlisted() public {
        _contributeEth(alice, 1 ether);
        _convert();
        vault.accrueFees(10e18, 10e18);
        vault.collectFees();
        factory.setSwapTarget(address(router), false);
        vm.prank(alice);
        (,, uint256 eo) = vault.claimFees(ClaimMode.ETH, 1);
        assertGt(eo, 0);
        _assertSolvent(vault);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    Vm.Log[] internal _logs;

    function _pull() internal {
        Vm.Log[] memory l = vm.getRecordedLogs();
        for (uint256 i; i < l.length; ++i) _logs.push(l[i]);
    }

    /// @dev The IMD value `token` realized in the last conversion (TokenConverted), from the recorded logs.
    function _value(address token) internal returns (uint256 amountIn, uint256 v) {
        _pull();
        bytes32 tc = keccak256("TokenConverted(uint256,address,uint256,uint256)");
        for (uint256 j; j < _logs.length; ++j) {
            if (_logs[j].emitter != address(vault) || _logs[j].topics[0] != tc) continue;
            if (address(uint160(uint256(_logs[j].topics[2]))) == token) {
                (amountIn, v) = abi.decode(_logs[j].data, (uint256, uint256));
            }
        }
    }

    function _leg() internal returns (uint256 ethIn, uint256 imdOut) {
        _pull();
        bytes32 el = keccak256("EthLegSwapped(uint256,uint256,uint256)");
        for (uint256 j; j < _logs.length; ++j) {
            if (_logs[j].emitter == address(vault) && _logs[j].topics[0] == el) {
                (ethIn, imdOut) = abi.decode(_logs[j].data, (uint256, uint256));
            }
        }
    }

    /// @dev The `k`-th permutation of 0..3 (Lehmer code).
    function _perm(uint256 k) internal pure returns (uint256[4] memory out) {
        uint256[4] memory pool = [uint256(0), 1, 2, 3];
        uint256 n = 4;
        uint256[4] memory f = [uint256(6), 2, 1, 1];
        for (uint256 i; i < 4; ++i) {
            uint256 idx = k / f[i];
            k %= f[i];
            out[i] = pool[idx];
            for (uint256 j = idx; j + 1 < n; ++j) pool[j] = pool[j + 1];
            --n;
        }
    }
}
