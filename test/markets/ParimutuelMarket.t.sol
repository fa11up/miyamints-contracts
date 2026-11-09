// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";
import { PredictionRegistry } from "../../src/markets/PredictionRegistry.sol";
import { EligibilityGate } from "../../src/markets/EligibilityGate.sol";

contract ParimutuelMarketTest is MarketsBase {
    ParimutuelMarket m;

    function setUp() public override {
        super.setUp();
        m = _winnerMarket();
    }

    // ── initialization ──────────────────────────────────────────────────────

    function test_initialize_snapshotsTerms() public view {
        MarketTypes.Terms memory t = m.terms();
        assertEq(t.token, address(imd));
        assertEq(t.registry, address(registry));
        assertEq(t.creator, creator);
        assertEq(t.door, address(door));
        assertEq(t.eligibility, address(gate));
        assertEq(t.resolver, address(mockResolver));
        assertEq(t.disputeModule, address(disputes));
        assertEq(t.council, address(council));
        assertEq(t.treasury, treasury);
        assertEq(t.rake.treasuryBps, 100);
        assertEq(t.rake.creatorBps, 75);
        assertEq(t.rake.resolverBps, 50);
        assertEq(t.rake.insuranceBps, 25);
        assertEq(t.perWalletCap, WALLET_CAP);
        assertEq(t.perMarketCap, MARKET_CAP);
        assertEq(t.lockMargin, LOCK_MARGIN);
        assertEq(t.disputeWindow, 2 hours);
        assertEq(t.outcomeCount, 2);
        assertTrue(t.startQuestionHash != bytes32(0));
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Open));
    }

    function test_initialize_cannotRunTwice() public {
        MarketTypes.Terms memory t = m.terms();
        vm.expectRevert(ParimutuelMarket.AlreadyInitialized.selector);
        m.initialize(t, new address[](0));
    }

    function test_implementation_isLocked() public {
        ParimutuelMarket impl = ParimutuelMarket(factory.implementation());
        MarketTypes.Terms memory t = m.terms();
        vm.expectRevert(ParimutuelMarket.AlreadyInitialized.selector);
        impl.initialize(t, new address[](0));
    }

    function test_registryChanges_doNotReachExistingMarket() public {
        vm.startPrank(owner);
        registry.setRake(
            MarketTypes.RakeSplit({ treasuryBps: 300, creatorBps: 100, resolverBps: 50, insuranceBps: 50 })
        );
        registry.setLimits(1_000e18, 50_000e18, 2e18, 600);
        registry.setRecipients(makeAddr("t2"), makeAddr("r2"), makeAddr("i2"));
        vm.stopPrank();

        MarketTypes.Terms memory old = m.terms();
        assertEq(old.rake.treasuryBps, 100);
        assertEq(old.perWalletCap, WALLET_CAP);
        assertEq(old.lockMargin, LOCK_MARGIN);
        assertEq(old.treasury, treasury);

        MarketTypes.Terms memory fresh = _winnerMarket().terms();
        assertEq(fresh.rake.treasuryBps, 300);
        assertEq(fresh.perWalletCap, 1_000e18);
        assertEq(fresh.lockMargin, 600);
        assertEq(fresh.treasury, makeAddr("t2"));
    }

    // ── staking ─────────────────────────────────────────────────────────────

    function test_stake_recordsPools() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, alice, 2, 20e18);
        _stake(m, bob, 2, 50e18);
        assertEq(m.totalStaked(), 170e18);
        assertEq(m.outcomePool(1), 100e18);
        assertEq(m.outcomePool(2), 70e18);
        assertEq(m.stakeOf(alice, 1), 100e18);
        assertEq(m.stakeOf(alice, 2), 20e18);
        assertEq(m.stakedBy(alice), 120e18);
        assertEq(imd.balanceOf(address(m)), 170e18);
        assertEq(registry.openInterest(), 170e18);
        assertEq(m.openInterest(), 170e18);
    }

    function test_stake_revertsAfterLock() public {
        vm.warp(m.terms().lockAt);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Locked));
        imd.mint(alice, 10e18);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.startPrank(alice);
        imd.approve(address(m), 10e18);
        vm.expectRevert(ParimutuelMarket.NotOpen.selector);
        m.stake(1, 10e18, p, sig);
        vm.stopPrank();
    }

    function test_stake_revertsOnInvalidOutcome() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.startPrank(alice);
        vm.expectRevert(ParimutuelMarket.InvalidOutcome.selector);
        m.stake(0, 10e18, p, sig);
        vm.expectRevert(ParimutuelMarket.InvalidOutcome.selector);
        m.stake(3, 10e18, p, sig);
        vm.stopPrank();
    }

    function test_stake_revertsBelowMinimum() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.BelowMinStake.selector);
        m.stake(1, MIN_STAKE - 1, p, sig);
    }

    function test_stake_walletCapAcrossOutcomes() public {
        _stake(m, alice, 1, 200e18);
        _stake(m, alice, 2, 50e18); // exactly at the cap
        imd.mint(alice, 1e18);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.startPrank(alice);
        imd.approve(address(m), 1e18);
        vm.expectRevert(ParimutuelMarket.WalletCapExceeded.selector);
        m.stake(1, 1e18, p, sig);
        vm.stopPrank();
    }

    function test_stake_marketCap() public {
        for (uint256 i; i < 40; ++i) {
            _stake(m, makeAddr(string.concat("w", vm.toString(i))), 1, 250e18);
        }
        assertEq(m.totalStaked(), MARKET_CAP);
        address late = makeAddr("late");
        imd.mint(late, 1e18);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(late);
        vm.startPrank(late);
        imd.approve(address(m), 1e18);
        vm.expectRevert(ParimutuelMarket.MarketCapExceeded.selector);
        m.stake(1, 1e18, p, sig);
        vm.stopPrank();
    }

    function test_stake_denyListBlocksCreatorAndCrew() public {
        assertTrue(m.isDenied(creator));
        assertTrue(m.isDenied(crewMod));
        assertTrue(m.isDenied(crewEditor));
        assertFalse(m.isDenied(alice));
        address[3] memory banned = [creator, crewMod, crewEditor];
        for (uint256 i; i < 3; ++i) {
            imd.mint(banned[i], 10e18);
            (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(banned[i]);
            vm.startPrank(banned[i]);
            imd.approve(address(m), 10e18);
            vm.expectRevert(ParimutuelMarket.Denied.selector);
            m.stake(1, 10e18, p, sig);
            vm.stopPrank();
        }
    }

    function test_stake_denyListIsSnapshot() public {
        // Crew added after creation reaches only new markets.
        address newCrew = makeAddr("newCrew");
        address[] memory crew = new address[](1);
        crew[0] = newCrew;
        vm.prank(owner);
        registry.setCreator(creator, true, crew);
        assertFalse(m.isDenied(newCrew));
        assertTrue(_winnerMarket().isDenied(newCrew));
    }

    function test_stake_requiresValidPass() public {
        imd.mint(alice, 10e18);
        (MarketTypes.EligibilityPass memory p,) = _pass(alice);
        bytes memory forged = _signPass(p, 0xBAD);
        vm.startPrank(alice);
        imd.approve(address(m), 10e18);
        vm.expectRevert(EligibilityGate.InvalidSignature.selector);
        m.stake(1, 10e18, p, forged);
        vm.stopPrank();
    }

    function test_stakeFor_onlyDoor() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.prank(bob);
        vm.expectRevert(ParimutuelMarket.NotDoor.selector);
        m.stakeFor(alice, 1, 10e18, p, sig);
    }

    // ── proposing ───────────────────────────────────────────────────────────

    function test_propose_onlyResolver() public {
        vm.warp(m.terms().resolveAfter);
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.NotResolver.selector);
        m.propose(1, uint64(vm.getBlockTimestamp()), alice);
    }

    function test_propose_revertsWhileOpen() public {
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        mockResolver.propose(address(m), 1, uint64(vm.getBlockTimestamp()));
    }

    function test_propose_revertsBeforeResolveAfter() public {
        uint64 lockAt = m.terms().lockAt;
        vm.warp(lockAt);
        vm.expectRevert(ParimutuelMarket.TooEarly.selector);
        mockResolver.propose(address(m), 1, lockAt);
    }

    function test_propose_revertsAfterGrace() public {
        uint64 lockAt = m.terms().lockAt;
        vm.warp(uint256(m.terms().resolveAfter) + 7 days + 1);
        vm.expectRevert(ParimutuelMarket.TooLate.selector);
        mockResolver.propose(address(m), 1, lockAt);
    }

    function test_propose_revertsOnInvalidOutcome() public {
        uint64 lockAt = m.terms().lockAt;
        vm.warp(m.terms().resolveAfter);
        vm.expectRevert(ParimutuelMarket.InvalidOutcome.selector);
        mockResolver.propose(address(m), 3, lockAt);
    }

    function test_propose_sourceClockNeedsStart() public {
        vm.warp(m.terms().resolveAfter);
        vm.expectRevert(ParimutuelMarket.MissingStart.selector);
        mockResolver.propose(address(m), 1, 0);
    }

    function test_propose_movesToProposed() public {
        vm.warp(m.terms().resolveAfter);
        _propose(m, 2, m.terms().lockAt);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Proposed));
        assertEq(m.proposedOutcome(), 2);
        assertEq(m.proposer(), keeper);
        assertEq(m.attestedStart(), m.terms().lockAt);
        assertEq(m.cutoff(), m.terms().lockAt - LOCK_MARGIN);
        assertEq(m.disputeDeadline(), vm.getBlockTimestamp() + 2 hours);
        uint64 lockAt = m.terms().lockAt;
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        mockResolver.propose(address(m), 1, lockAt);
    }

    function test_finalize_revertsInsideDisputeWindow() public {
        vm.warp(m.terms().resolveAfter);
        _propose(m, 1, m.terms().lockAt);
        vm.warp(vm.getBlockTimestamp() + 2 hours - 1);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.finalize();
    }

    // ── settlement ──────────────────────────────────────────────────────────

    function test_finalize_paysWinnersAndRake() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 1, 50e18);
        _stake(m, carol, 2, 200e18);
        _resolve(m, 1, m.terms().lockAt);

        assertEq(uint8(m.state()), uint8(MarketTypes.State.Final));
        // losing side 200: rake 2.5% = 5 (treasury 2, creator 1.5, resolver 1, insurance 0.5)
        assertEq(imd.balanceOf(treasury), 2e18);
        assertEq(imd.balanceOf(resolverBudget), 1e18);
        assertEq(imd.balanceOf(insurance), 0.5e18);
        assertEq(m.creatorEscrow(), 1.5e18);
        assertEq(m.distributable(), 195e18);

        assertEq(m.claimable(alice), 230e18);
        assertEq(m.claimable(bob), 115e18);
        assertEq(m.claimable(carol), 0);
        assertEq(_claim(m, alice), 230e18);
        assertEq(_claim(m, bob), 115e18);
        assertEq(imd.balanceOf(address(m)), 1.5e18); // only the creator's escrow is left
        assertEq(registry.openInterest(), 1.5e18);
    }

    function test_finalize_onlyWinnersMeansNoRake() public {
        _stake(m, alice, 1, 100e18);
        _resolve(m, 1, m.terms().lockAt);
        assertEq(_claim(m, alice), 100e18);
        assertEq(imd.balanceOf(treasury), 0);
    }

    function test_finalize_voidCodeRefundsEveryone() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 40e18);
        _resolve(m, 0, m.terms().lockAt);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertEq(m.claimable(alice), 0);
        assertEq(_refund(m, alice), 100e18);
        assertEq(_refund(m, bob), 40e18);
        assertEq(imd.balanceOf(treasury), 0);
        assertEq(registry.openInterest(), 0);
    }

    function test_finalize_noCountedWinnerVoids() public {
        _stake(m, alice, 2, 100e18);
        _resolve(m, 1, m.terms().lockAt);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertEq(m.finalOutcome(), 0);
        assertEq(m.decidedOutcome(), 1);
        assertEq(_refund(m, alice), 100e18);
    }

    function test_lateStakes_refundedNotCounted() public {
        uint64 lockAt = m.terms().lockAt;
        uint64 start = lockAt - 1 hours; // the event actually started an hour before the scheduled lock
        _stake(m, alice, 1, 100e18);
        vm.warp(start - LOCK_MARGIN); // exactly at the cutoff: counted
        _stake(m, carol, 2, 100e18);
        vm.warp(start - LOCK_MARGIN + 1); // one second later: late
        _stake(m, bob, 2, 50e18);
        vm.warp(start + 10 minutes); // after the real start: late
        _stake(m, dave, 1, 80e18);

        _resolve(m, 1, start);
        assertEq(m.cutoff(), start - LOCK_MARGIN);
        assertEq(m.countedPool(), 200e18);
        assertEq(m.winningPool(), 100e18);
        // losing counted side is carol's 100 only
        assertEq(m.claimable(alice), 197.5e18);
        assertEq(m.claimable(dave), 0);
        assertEq(m.refundable(bob), 50e18);
        assertEq(m.refundable(dave), 80e18);
        assertEq(m.refundable(alice), 0);
        assertEq(_refund(m, bob), 50e18);
        assertEq(_refund(m, dave), 80e18);
        assertEq(_claim(m, alice), 197.5e18);
        vm.prank(carol);
        vm.expectRevert(ParimutuelMarket.NothingToPay.selector);
        m.refund();
    }

    function test_lockWithoutStartQuestion_countsEverything() public {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 3 days);
        ParimutuelMarket ms = _create(tMilestone, _milestoneSlots(), lockAt, lockAt + 24 hours, 0);
        assertEq(ms.terms().startQuestionHash, bytes32(0));
        _stake(ms, alice, 1, 10e18);
        vm.warp(lockAt - 1);
        _stake(ms, bob, 2, 10e18);
        _resolve(ms, 2, 0);
        assertEq(ms.cutoff(), lockAt);
        assertEq(ms.countedPool(), 20e18);
        assertEq(ms.refundable(bob), 0);
        assertGt(ms.claimable(bob), 19e18);
    }

    function test_claim_cannotRepeatOrPayLosers() public {
        _stake(m, alice, 1, 10e18);
        _stake(m, bob, 2, 10e18);
        _resolve(m, 1, m.terms().lockAt);
        _claim(m, alice);
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.NothingToPay.selector);
        m.claim();
        vm.prank(bob);
        vm.expectRevert(ParimutuelMarket.NothingToPay.selector);
        m.claim();
    }

    function test_claim_revertsBeforeFinal() public {
        _stake(m, alice, 1, 10e18);
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.NothingToPay.selector);
        m.claim();
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.NothingToPay.selector);
        m.refund();
    }

    function test_claimAndRefund_areUngated() public {
        _stake(m, alice, 1, 10e18);
        _stake(m, bob, 2, 10e18);
        // KYC revoked for alice after she staked, and the signer rotated: claims still pay.
        vm.startPrank(owner);
        gate.revoke(alice);
        gate.setSigner(makeAddr("newSigner"));
        vm.stopPrank();
        _resolve(m, 1, m.terms().lockAt);
        assertGt(_claim(m, alice), 10e18);
    }

    // ── timeouts ────────────────────────────────────────────────────────────

    function test_voidUnresolved_noProposal() public {
        _stake(m, alice, 1, 10e18);
        vm.warp(uint256(m.terms().resolveAfter) + 7 days);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.voidUnresolved();
        vm.warp(vm.getBlockTimestamp() + 1);
        m.voidUnresolved();
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertTrue(m.timedOut());
        assertEq(_refund(m, alice), 10e18);
    }

    function test_voidUnresolved_revertsWhenProposed() public {
        vm.warp(m.terms().resolveAfter);
        _propose(m, 1, m.terms().lockAt);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.voidUnresolved();
    }

    // ── creator escrow ──────────────────────────────────────────────────────

    function test_creatorFee_vestsSevenDays() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        _resolve(m, 1, m.terms().lockAt);
        assertEq(m.creatorEscrow(), 1.5e18);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(ParimutuelMarket.CreatorVesting.selector);
        m.payCreator();
        vm.warp(vm.getBlockTimestamp() + 1);
        m.payCreator();
        assertEq(imd.balanceOf(creator), 1.5e18);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.payCreator();
    }

    function test_creatorBond_pulledAndReturned() public {
        vm.prank(owner);
        registry.setBonds(50e18, 200, 25e18);
        imd.mint(creator, 25e18);
        vm.prank(creator);
        imd.approve(address(factory), 25e18);
        ParimutuelMarket mb = _winnerMarket();
        assertEq(mb.bondHeld(), 25e18);
        assertEq(imd.balanceOf(address(mb)), 25e18);
        assertEq(registry.openInterest(), 0);
        _stake(mb, alice, 1, 100e18);
        _stake(mb, bob, 2, 100e18);
        _resolve(mb, 1, mb.terms().lockAt);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        mb.payCreator();
        assertEq(imd.balanceOf(creator), 25e18 + 0.75e18);
    }

    function test_slashCreator_onlyCouncilBeforeVest() public {
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.NotCouncil.selector);
        m.slashCreator();

        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        _resolve(m, 1, m.terms().lockAt);
        for (uint256 i; i < 3; ++i) {
            vm.prank(councilMembers[i]);
            council.voteSlash(address(m));
        }
        assertTrue(m.creatorSlashed());
        assertEq(imd.balanceOf(insurance), 0.5e18 + 1.5e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.payCreator();
    }

    function test_slashCreator_afterVestReverts() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        _resolve(m, 1, m.terms().lockAt);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(address(council));
        vm.expectRevert(ParimutuelMarket.TooLate.selector);
        m.slashCreator();
    }

    function test_slashCreator_beforeResolutionRoutesFeeToInsurance() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        vm.prank(address(council));
        m.slashCreator();
        _resolve(m, 1, m.terms().lockAt);
        assertEq(m.creatorEscrow(), 0);
        assertEq(imd.balanceOf(insurance), 0.5e18 + 1.5e18);
    }

    // ── sweep ───────────────────────────────────────────────────────────────

    function test_sweep_afterOneYear() public {
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        _resolve(m, 1, m.terms().lockAt);
        vm.expectRevert(ParimutuelMarket.TooEarly.selector);
        m.sweep();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 before = imd.balanceOf(treasury);
        m.sweep();
        // alice never claimed: her 295 and the unclaimed creator escrow 1.5 go to the treasury
        assertEq(imd.balanceOf(treasury) - before, 296.5e18);
        assertEq(imd.balanceOf(address(m)), 0);
        assertEq(registry.openInterest(), 0);
        vm.prank(alice);
        vm.expectRevert(ParimutuelMarket.AlreadySwept.selector);
        m.claim();
        vm.expectRevert(ParimutuelMarket.AlreadySwept.selector);
        m.sweep();
    }

    function test_sweep_revertsWhileUnresolved() public {
        vm.warp(vm.getBlockTimestamp() + 400 days);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.sweep();
    }

    // ── answer mapping ──────────────────────────────────────────────────────

    function test_outcomeForAnswer_modes() public {
        assertEq(m.outcomeForAnswer(1), 1);
        assertEq(m.outcomeForAnswer(2), 2);
        assertEq(m.outcomeForAnswer(3), 0);
        assertEq(m.outcomeForAnswer(5), 0);
        vm.expectRevert(ParimutuelMarket.UnknownCode.selector);
        m.outcomeForAnswer(6);

        uint64 lockAt = uint64(vm.getBlockTimestamp() + 3 days);
        ParimutuelMarket mb = _create(tMilestone, _milestoneSlots(), lockAt, lockAt + 1 days, 0);
        assertEq(mb.outcomeForAnswer(1), 1);
        assertEq(mb.outcomeForAnswer(0), 2);
        vm.expectRevert(ParimutuelMarket.UnknownCode.selector);
        mb.outcomeForAnswer(2);

        ParimutuelMarket mt = _create(tTotal, _gameSlots(), lockAt, lockAt + 3 hours, 44);
        assertEq(mt.outcomeForAnswer(45), 1);
        assertEq(mt.outcomeForAnswer(44), 2);

        ParimutuelMarket m3 = _create(t3Way, _gameSlots(), lockAt, lockAt + 3 hours, 0);
        assertEq(m3.outcomeForAnswer(3), 2); // draw is the middle outcome
        assertEq(m3.outcomeForAnswer(2), 3);
    }
}
