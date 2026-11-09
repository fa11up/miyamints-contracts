// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";
import { DisputeModule } from "../../src/markets/DisputeModule.sol";
import { CouncilResolver } from "../../src/markets/CouncilResolver.sol";

contract DisputeCouncilTest is MarketsBase {
    ParimutuelMarket m;
    address disputer = makeAddr("disputer");

    function setUp() public override {
        super.setUp();
        m = _winnerMarket();
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        vm.warp(m.terms().resolveAfter);
        _propose(m, 1, m.terms().lockAt);
    }

    function _dispute() internal returns (uint256 bond) {
        bond = disputes.bondFor(address(m));
        imd.mint(disputer, bond);
        vm.startPrank(disputer);
        imd.approve(address(disputes), bond);
        disputes.dispute(address(m));
        vm.stopPrank();
    }

    function _panel(uint8 outcome) internal {
        mockDisputeResolver.panel(address(disputes), address(m), outcome);
    }

    // ── bond ────────────────────────────────────────────────────────────────

    function test_bond_isMinimumForSmallPools() public view {
        // 2% of 300 = 6 < 50
        assertEq(disputes.bondFor(address(m)), 50e18);
    }

    function test_bond_scalesWithPool() public {
        ParimutuelMarket big = _winnerMarket();
        for (uint256 i; i < 20; ++i) {
            _stake(big, makeAddr(string.concat("p", vm.toString(i))), uint8(1 + (i % 2)), 250e18);
        }
        // 2% of 5,000 = 100 > 50
        assertEq(disputes.bondFor(address(big)), 100e18);
    }

    // ── opening ─────────────────────────────────────────────────────────────

    function test_dispute_movesMarketAndHoldsBond() public {
        uint256 bond = _dispute();
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Disputed));
        assertEq(imd.balanceOf(address(disputes)), bond);
        (address who, uint128 b, uint8 proposed,,,) = disputes.disputes(address(m));
        assertEq(who, disputer);
        assertEq(b, bond);
        assertEq(proposed, 1);
    }

    function test_dispute_revertsAfterWindow() public {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        imd.mint(disputer, 50e18);
        vm.startPrank(disputer);
        imd.approve(address(disputes), 50e18);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        disputes.dispute(address(m));
        vm.stopPrank();
    }

    function test_dispute_onlyOnce() public {
        _dispute();
        vm.expectRevert(DisputeModule.AlreadyDisputed.selector);
        disputes.dispute(address(m));
    }

    function test_dispute_unknownMarket() public {
        vm.expectRevert(DisputeModule.UnknownMarket.selector);
        disputes.dispute(alice);
    }

    function test_markDisputed_onlyModule() public {
        vm.expectRevert(ParimutuelMarket.NotDisputeModule.selector);
        m.markDisputed();
        vm.expectRevert(ParimutuelMarket.NotDisputeModule.selector);
        m.upholdProposal();
        vm.expectRevert(ParimutuelMarket.NotDisputeModule.selector);
        m.escalate();
    }

    function test_finalize_blockedWhileDisputed() public {
        _dispute();
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.finalize();
    }

    // ── second panel ────────────────────────────────────────────────────────

    function test_panelAgrees_upholdsAndDisputerLosesBond() public {
        uint256 bond = _dispute();
        _panel(1);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Final));
        assertEq(m.finalOutcome(), 1);
        uint256 treasuryBefore = imd.balanceOf(treasury);
        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(keeper), bond / 2);
        assertEq(imd.balanceOf(treasury) - treasuryBefore, bond - bond / 2);
        assertEq(imd.balanceOf(disputer), 0);
        vm.expectRevert(DisputeModule.AlreadySettled.selector);
        disputes.settleBond(address(m));
    }

    function test_panelDisagrees_escalatesThenCouncilSidesWithDisputer() public {
        uint256 bond = _dispute();
        _panel(2);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Escalated));
        vm.expectRevert(DisputeModule.NotResolved.selector);
        disputes.settleBond(address(m));

        _councilVote(m, 2, 3);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Final));
        assertEq(m.finalOutcome(), 2);
        (bool answered, uint8 outcome,) = council.result(address(m));
        assertTrue(answered);
        assertEq(outcome, 2);

        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(disputer), bond);
        assertGt(_claim(m, bob), 200e18);
    }

    function test_panelDisagrees_councilUpholdsProposal() public {
        uint256 bond = _dispute();
        _panel(0);
        _councilVote(m, 1, 3);
        assertEq(m.finalOutcome(), 1);
        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(keeper), bond / 2);
        assertEq(imd.balanceOf(disputer), 0);
    }

    function test_panel_onlyDisputeResolver() public {
        _dispute();
        vm.expectRevert(DisputeModule.NotDisputeResolver.selector);
        disputes.onPanelResult(address(m), 1);
    }

    function test_panel_noDispute() public {
        vm.expectRevert(DisputeModule.NoDispute.selector);
        _panel(1);
    }

    function test_panel_afterDeadlineRefused_thenEscalate() public {
        _dispute();
        vm.expectRevert(DisputeModule.PanelStillOpen.selector);
        disputes.escalate(address(m));
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        vm.expectRevert(DisputeModule.PanelClosed.selector);
        _panel(1);
        disputes.escalate(address(m));
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Escalated));
        vm.expectRevert(DisputeModule.PanelClosed.selector);
        disputes.escalate(address(m));
    }

    // ── a decision for a side nobody counted on voids, and the bond still follows the decision ────────

    function _marketWithStakesOnlyOnTwo(uint8 proposed) internal {
        m = _winnerMarket();
        _stake(m, bob, 2, 200e18);
        vm.warp(m.terms().resolveAfter);
        _propose(m, proposed, m.terms().lockAt);
    }

    function test_panelUpholdsEmptySide_voidsAndDisputerStillLosesBond() public {
        _marketWithStakesOnlyOnTwo(1);
        uint256 bond = _dispute();
        _panel(1);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertEq(m.finalOutcome(), 0);
        assertEq(m.decidedOutcome(), 1);
        assertEq(_refund(m, bob), 200e18);

        uint256 treasuryBefore = imd.balanceOf(treasury);
        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(disputer), 0);
        assertEq(imd.balanceOf(keeper), bond / 2);
        assertEq(imd.balanceOf(treasury) - treasuryBefore, bond - bond / 2);
    }

    function test_councilOverturnsVoidProposalForEmptySide_disputerKeepsBond() public {
        _marketWithStakesOnlyOnTwo(0);
        uint256 bond = _dispute();
        _panel(1);
        _councilVote(m, 1, 3);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertEq(m.finalOutcome(), 0);
        assertEq(m.decidedOutcome(), 1);
        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(disputer), bond);
    }

    // ── council ─────────────────────────────────────────────────────────────

    function test_council_voidRefundsEveryoneAndDisputer() public {
        uint256 bond = _dispute();
        _panel(2);
        _councilVote(m, 0, 3);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertEq(_refund(m, alice), 100e18);
        assertEq(_refund(m, bob), 200e18);
        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(disputer), bond);
    }

    function test_council_belowThresholdDoesNothing() public {
        _dispute();
        _panel(2);
        _councilVote(m, 2, 2);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Escalated));
        assertEq(council.votesFor(address(m), 2), 2);
    }

    function test_council_memberCanChangeVote() public {
        _dispute();
        _panel(2);
        vm.prank(councilMembers[0]);
        council.vote(address(m), 1);
        vm.prank(councilMembers[0]);
        council.vote(address(m), 2);
        assertEq(council.votesFor(address(m), 1), 0);
        assertEq(council.votesFor(address(m), 2), 1);
        vm.prank(councilMembers[0]);
        vm.expectRevert(CouncilResolver.AlreadyVoted.selector);
        council.vote(address(m), 2);
    }

    function test_council_refusesNonMembersAndBadOutcomes() public {
        vm.prank(alice);
        vm.expectRevert(CouncilResolver.NotMember.selector);
        council.vote(address(m), 1);

        vm.prank(councilMembers[0]);
        vm.expectRevert(CouncilResolver.NotEscalated.selector);
        council.vote(address(m), 1);

        _dispute();
        _panel(2);
        vm.prank(councilMembers[0]);
        vm.expectRevert(CouncilResolver.InvalidOutcome.selector);
        council.vote(address(m), 3);
    }

    function test_council_cannotResolveDirectlyOrLate() public {
        _dispute();
        _panel(2);
        vm.expectRevert(ParimutuelMarket.NotCouncil.selector);
        m.councilResolve(1);

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(address(council));
        vm.expectRevert(ParimutuelMarket.TooLate.selector);
        m.councilResolve(1);
    }

    function test_council_silenceVoidsAfterSevenDays() public {
        uint256 bond = _dispute();
        _panel(2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(ParimutuelMarket.WrongState.selector);
        m.voidUnresolved();
        vm.warp(vm.getBlockTimestamp() + 1);
        m.voidUnresolved();
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
        assertTrue(m.timedOut());
        disputes.settleBond(address(m));
        assertEq(imd.balanceOf(disputer), bond);
        // a late council vote changes nothing
        vm.prank(councilMembers[0]);
        vm.expectRevert(CouncilResolver.NotEscalated.selector);
        council.vote(address(m), 1);
    }

    function test_councilConstructor_validation() public {
        address[] memory five = councilMembers;
        vm.expectRevert(CouncilResolver.InvalidConfiguration.selector);
        new CouncilResolver(five, 2); // not a majority
        vm.expectRevert(CouncilResolver.InvalidConfiguration.selector);
        new CouncilResolver(five, 6);
        address[] memory dup = new address[](3);
        dup[0] = alice;
        dup[1] = alice;
        dup[2] = bob;
        vm.expectRevert(CouncilResolver.InvalidConfiguration.selector);
        new CouncilResolver(dup, 2);
        CouncilResolver ok = new CouncilResolver(five, 3);
        assertEq(ok.members().length, 5);
        assertEq(ok.threshold(), 3);
    }

    function test_voteSlash_needsThreshold() public {
        vm.prank(councilMembers[0]);
        council.voteSlash(address(m));
        vm.prank(councilMembers[1]);
        council.voteSlash(address(m));
        assertFalse(m.creatorSlashed());
        vm.prank(councilMembers[1]);
        vm.expectRevert(CouncilResolver.AlreadyVoted.selector);
        council.voteSlash(address(m));
        vm.prank(councilMembers[2]);
        council.voteSlash(address(m));
        assertTrue(m.creatorSlashed());
    }
}
