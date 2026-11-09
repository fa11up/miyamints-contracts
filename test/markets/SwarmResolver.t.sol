// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";
import { SwarmResolver } from "../../src/markets/SwarmResolver.sol";
import { IPredictionRegistry } from "../../src/markets/interfaces/IMarkets.sol";

contract SwarmResolverTest is MarketsBase {
    ParimutuelMarket m;
    bytes question;
    bytes startQ;
    uint64 kickoff;

    uint64 constant FROM = 26_000_000;
    uint64 constant TO = 26_000_300;

    function setUp() public override {
        super.setUp();
        // markets created in this suite are second-tier disputed by the real dispute-tier SwarmResolver
        vm.prank(owner);
        registry.setModules(
            address(door), address(gate), address(desk), address(disputes), address(swarmDispute), address(council)
        );
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 1 days);
        m = _createWith(tWinner, _gameSlots(), lockAt, lockAt + 3 hours, 0, address(swarm));
        (question, startQ) = factory.buildPrefixes(tWinner, _gameSlots());
        kickoff = lockAt;
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 100e18);
        vm.warp(lockAt + 3 hours);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _att(
        SwarmResolver r,
        bytes memory prefix,
        uint256 answer,
        uint16 panel,
        uint16 quorum,
        uint16 agreed,
        bytes32 requestId
    ) internal view returns (SwarmResolver.Attestation memory a) {
        a.requestId = requestId;
        a.chainId = 1;
        a.answerType = MarketTypes.ANSWER_UINT256;
        a.answer = abi.encode(answer);
        a.figure = answer;
        a.fromBlock = FROM;
        a.toBlock = TO;
        a.blockHash = keccak256("block");
        a.panelJobId = keccak256("panel");
        a.panelSize = panel;
        a.quorum = quorum;
        a.agreed = agreed;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 days);
        a.questionHash = r.expectedQuestionHash(prefix, FROM, TO);
    }

    function _signed(SwarmResolver r, SwarmResolver.Attestation memory a, bytes memory prefix, uint256 key)
        internal
        view
        returns (SwarmResolver.Signed memory s)
    {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, r.digest(a));
        s = SwarmResolver.Signed({ a: a, sig: abi.encodePacked(rr, ss, v), prefix: prefix });
    }

    function _answer(uint256 code, uint16 panel, uint16 quorum, uint16 agreed)
        internal
        view
        returns (SwarmResolver.Signed memory)
    {
        return _signed(
            swarm, _att(swarm, question, code, panel, quorum, agreed, keccak256("req-answer")), question, ORACLE_KEY
        );
    }

    function _start(uint256 ts) internal view returns (SwarmResolver.Signed memory) {
        return _signed(swarm, _att(swarm, startQ, ts, 25, 13, 13, keccak256("req-start")), startQ, ORACLE_KEY);
    }

    function _none() internal pure returns (SwarmResolver.Signed memory s) { }

    // ── happy path ──────────────────────────────────────────────────────────

    function test_submit_proposesWithAttestedStart() public {
        SwarmResolver.Signed memory ans1 = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st1 = _start(kickoff - 10 minutes);
        vm.prank(keeper);
        swarm.submit(address(m), ans1, st1);
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Proposed));
        assertEq(m.proposedOutcome(), 1);
        assertEq(m.attestedStart(), kickoff - 10 minutes);
        assertEq(m.cutoff(), kickoff - 10 minutes - LOCK_MARGIN);
        assertEq(m.proposer(), keeper);
        (bool answered, uint8 outcome, uint64 start) = swarm.result(address(m));
        assertTrue(answered);
        assertEq(outcome, 1);
        assertEq(start, kickoff - 10 minutes);
        assertTrue(swarm.usedRequests(keccak256("req-answer")));
    }

    function test_submit_codeMapsToVoid() public {
        swarm.submit(address(m), _answer(4, 25, 13, 13), _start(kickoff)); // 4 = postponed
        assertEq(m.proposedOutcome(), 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        m.finalize();
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
    }

    function test_question_isTemplatePlusSlots() public view {
        bytes memory expected = bytes.concat(
            WINNER_HEAD,
            "NFL, 25 Oct 2026: Away Team (away) at Home Team (home). Which side won the game, overtime included?",
            WINDOW_TAIL
        );
        assertEq(question, expected);
        assertEq(m.terms().questionHash, keccak256(expected));
        assertEq(m.terms().startQuestionHash, keccak256(startQ));
        assertEq(
            swarm.expectedQuestionHash(question, FROM, TO),
            keccak256(bytes.concat(expected, "26000000", ',"toBlock":', "26000300", "}}"))
        );
    }

    // ── absolute-count quorum ───────────────────────────────────────────────

    /// @notice A live attestation once came back agreed 12 < quorum 13 and was still signed. Signed is not enough.
    function test_agreedBelowQuorum_rejectedEvenWhenSigned() public {
        SwarmResolver.Signed memory s = _answer(1, 25, 13, 12);
        assertEq(swarm.signerOf(s.a, s.sig), oracleSigner, "genuinely signed");
        SwarmResolver.Signed memory ans2 = s;
        SwarmResolver.Signed memory st2 = _start(kickoff);
        vm.expectRevert(SwarmResolver.NotEnoughAgreement.selector);
        swarm.submit(address(m), ans2, st2);
    }

    function test_agreedAboveQuorumIsFine() public {
        swarm.submit(address(m), _answer(1, 25, 13, 20), _start(kickoff));
        assertEq(m.proposedOutcome(), 1);
    }

    function test_requestedQuorumBelowFloor_rejected() public {
        SwarmResolver.Signed memory ans3 = _answer(1, 25, 12, 12);
        SwarmResolver.Signed memory st3 = _start(kickoff);
        vm.expectRevert(SwarmResolver.QuorumTooLow.selector);
        swarm.submit(address(m), ans3, st3);
    }

    function test_panelBelowFloor_rejected() public {
        SwarmResolver.Signed memory ans4 = _answer(1, 24, 13, 13);
        SwarmResolver.Signed memory st4 = _start(kickoff);
        vm.expectRevert(SwarmResolver.PanelTooSmall.selector);
        swarm.submit(address(m), ans4, st4);
    }

    function test_agreedAbovePanel_rejected() public {
        SwarmResolver.Signed memory ans5 = _answer(1, 25, 13, 26);
        SwarmResolver.Signed memory st5 = _start(kickoff);
        vm.expectRevert(SwarmResolver.NotEnoughAgreement.selector);
        swarm.submit(address(m), ans5, st5);
    }

    // ── binding ─────────────────────────────────────────────────────────────

    function test_wrongSigner_rejected() public {
        SwarmResolver.Signed memory s =
            _signed(swarm, _att(swarm, question, 1, 25, 13, 13, keccak256("x")), question, 0xBEEF);
        SwarmResolver.Signed memory ans6 = s;
        SwarmResolver.Signed memory st6 = _start(kickoff);
        vm.expectRevert(SwarmResolver.InvalidSignature.selector);
        swarm.submit(address(m), ans6, st6);
    }

    function test_signatureForAnotherResolver_rejected() public {
        SwarmResolver other = new SwarmResolver(
            IPredictionRegistry(address(registry)), oracleSigner, SwarmResolver.Tier.Primary, 25, 13
        );
        SwarmResolver.Signed memory s =
            _signed(other, _att(other, question, 1, 25, 13, 13, keccak256("x")), question, ORACLE_KEY);
        SwarmResolver.Signed memory ans7 = s;
        SwarmResolver.Signed memory st7 = _start(kickoff);
        vm.expectRevert(SwarmResolver.InvalidSignature.selector);
        swarm.submit(address(m), ans7, st7);
    }

    function test_signatureForAnotherChain_rejected() public {
        SwarmResolver.Signed memory s = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st = _start(kickoff);
        vm.chainId(4663);
        vm.expectRevert(SwarmResolver.InvalidSignature.selector);
        swarm.submit(address(m), s, st);
    }

    function test_otherQuestion_rejected() public {
        bytes[] memory slots = _gameSlots();
        slots[1] = "Another Team";
        (bytes memory otherQ,) = factory.buildPrefixes(tWinner, slots);
        SwarmResolver.Signed memory s =
            _signed(swarm, _att(swarm, otherQ, 1, 25, 13, 13, keccak256("x")), otherQ, ORACLE_KEY);
        SwarmResolver.Signed memory ans8 = s;
        SwarmResolver.Signed memory st8 = _start(kickoff);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmResolver.WrongQuestion.selector, keccak256(question), keccak256(otherQ))
        );
        swarm.submit(address(m), ans8, st8);
    }

    function test_attestedHashMustMatchSplicedWindow() public {
        SwarmResolver.Attestation memory a = _att(swarm, question, 1, 25, 13, 13, keccak256("x"));
        a.toBlock = TO + 1; // window no longer matches the signed questionHash
        SwarmResolver.Signed memory s = _signed(swarm, a, question, ORACLE_KEY);
        SwarmResolver.Signed memory ans9 = s;
        SwarmResolver.Signed memory st9 = _start(kickoff);
        vm.expectRevert();
        swarm.submit(address(m), ans9, st9);
    }

    function test_wrongDataChainAndAnswerType_rejected() public {
        SwarmResolver.Attestation memory a = _att(swarm, question, 1, 25, 13, 13, keccak256("x"));
        a.chainId = 11155111;
        SwarmResolver.Signed memory ans10 = _signed(swarm, a, question, ORACLE_KEY);
        SwarmResolver.Signed memory st10 = _start(kickoff);
        vm.expectRevert(SwarmResolver.WrongDataChain.selector);
        swarm.submit(address(m), ans10, st10);

        a.chainId = 1;
        a.answerType = MarketTypes.ANSWER_BOOL;
        SwarmResolver.Signed memory ans11 = _signed(swarm, a, question, ORACLE_KEY);
        SwarmResolver.Signed memory st11 = _start(kickoff);
        vm.expectRevert(SwarmResolver.WrongAnswerType.selector);
        swarm.submit(address(m), ans11, st11);
    }

    function test_issuedBeforeEvent_rejected() public {
        SwarmResolver.Attestation memory a = _att(swarm, question, 1, 25, 13, 13, keccak256("x"));
        a.issuedAt = m.terms().resolveAfter - 1;
        SwarmResolver.Signed memory ans12 = _signed(swarm, a, question, ORACLE_KEY);
        SwarmResolver.Signed memory st12 = _start(kickoff);
        vm.expectRevert(SwarmResolver.IssuedBeforeEvent.selector);
        swarm.submit(address(m), ans12, st12);
    }

    function test_expired_rejected() public {
        SwarmResolver.Signed memory s = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st = _start(kickoff);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.expectRevert(SwarmResolver.ExpiredAttestation.selector);
        swarm.submit(address(m), s, st);
    }

    function test_futureIssued_rejected() public {
        SwarmResolver.Attestation memory a = _att(swarm, question, 1, 25, 13, 13, keccak256("x"));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 1);
        SwarmResolver.Signed memory ans13 = _signed(swarm, a, question, ORACLE_KEY);
        SwarmResolver.Signed memory st13 = _start(kickoff);
        vm.expectRevert(SwarmResolver.InvalidTimestamp.selector);
        swarm.submit(address(m), ans13, st13);
    }

    function test_replayedRequest_rejected() public {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 1 days);
        ParimutuelMarket m2 = _createWith(tWinner, _gameSlots(), lockAt, lockAt + 3 hours, 0, address(swarm));
        SwarmResolver.Signed memory s = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st = _start(kickoff);
        swarm.submit(address(m), s, st);
        vm.warp(lockAt + 3 hours);
        // same question text, same signed answer, different market: the request id is spent
        vm.expectRevert(SwarmResolver.ExpiredAttestation.selector);
        swarm.submit(address(m2), s, st);
        SwarmResolver.Signed memory fresh = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory ans14 = fresh;
        SwarmResolver.Signed memory st14 = _start(kickoff);
        vm.expectRevert(SwarmResolver.ReplayedAttestation.selector);
        swarm.submit(address(m2), ans14, st14);
    }

    function test_secondSubmit_rejected() public {
        swarm.submit(address(m), _answer(1, 25, 13, 13), _start(kickoff));
        SwarmResolver.Signed memory ans15 = _answer(2, 25, 13, 13);
        SwarmResolver.Signed memory st15 = _start(kickoff);
        vm.expectRevert(SwarmResolver.AlreadyAnswered.selector);
        swarm.submit(address(m), ans15, st15);
    }

    function test_sourceClockMarket_needsStartAttestation() public {
        bytes32 startHash = keccak256(startQ);
        SwarmResolver.Signed memory ans16 = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st16 = _none();
        vm.expectRevert(abi.encodeWithSelector(SwarmResolver.WrongQuestion.selector, startHash, keccak256("")));
        swarm.submit(address(m), ans16, st16);
    }

    function test_startMustBeTheStartQuestion() public {
        // the main answer offered as the start answer
        SwarmResolver.Signed memory wrong =
            _signed(swarm, _att(swarm, question, kickoff, 25, 13, 13, keccak256("y")), question, ORACLE_KEY);
        SwarmResolver.Signed memory ans17 = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st17 = wrong;
        vm.expectRevert();
        swarm.submit(address(m), ans17, st17);
    }

    function test_unknownCode_rejected() public {
        SwarmResolver.Signed memory ans18 = _answer(9, 25, 13, 13);
        SwarmResolver.Signed memory st18 = _start(kickoff);
        vm.expectRevert(ParimutuelMarket.UnknownCode.selector);
        swarm.submit(address(m), ans18, st18);
    }

    function test_unknownMarket_rejected() public {
        SwarmResolver.Signed memory ans19 = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st19 = _start(kickoff);
        vm.expectRevert(SwarmResolver.UnknownMarket.selector);
        swarm.submit(alice, ans19, st19);
    }

    function test_resolverNotTheMarketsResolver_refusedByMarket() public {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 1 days);
        ParimutuelMarket viaMock = _create(tWinner, _gameSlots(), lockAt, lockAt + 3 hours, 0);
        vm.warp(lockAt + 3 hours);
        SwarmResolver.Signed memory ans20 = _answer(1, 25, 13, 13);
        SwarmResolver.Signed memory st20 = _start(kickoff);
        vm.expectRevert(ParimutuelMarket.NotResolver.selector);
        swarm.submit(address(viaMock), ans20, st20);
    }

    // ── other answer modes ──────────────────────────────────────────────────

    function test_boolMarket_noStartQuestion() public {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 3 days);
        ParimutuelMarket mb = _createWith(tMilestone, _milestoneSlots(), lockAt, lockAt + 1 days, 0, address(swarm));
        (bytes memory q,) = factory.buildPrefixes(tMilestone, _milestoneSlots());
        vm.warp(lockAt + 1 days);
        SwarmResolver.Attestation memory a = _att(swarm, q, 1, 25, 13, 13, keccak256("bool"));
        a.answerType = MarketTypes.ANSWER_BOOL;
        SwarmResolver.Signed memory s = _signed(swarm, a, q, ORACLE_KEY);

        SwarmResolver.Signed memory ans21 = s;
        SwarmResolver.Signed memory st21 = _start(kickoff);
        vm.expectRevert(SwarmResolver.UnexpectedStart.selector);
        swarm.submit(address(mb), ans21, st21);

        swarm.submit(address(mb), s, _none());
        assertEq(mb.proposedOutcome(), 1);
        assertEq(mb.cutoff(), lockAt);
    }

    function test_thresholdMarket() public {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 1 days);
        ParimutuelMarket mt = _createWith(tTotal, _gameSlots(), lockAt, lockAt + 3 hours, 44, address(swarm));
        (bytes memory q, bytes memory sq) = factory.buildPrefixes(tTotal, _gameSlots());
        vm.warp(lockAt + 3 hours);
        SwarmResolver.Signed memory s = _signed(swarm, _att(swarm, q, 44, 25, 13, 13, keccak256("tot")), q, ORACLE_KEY);
        SwarmResolver.Signed memory st =
            _signed(swarm, _att(swarm, sq, lockAt, 25, 13, 13, keccak256("tot-start")), sq, ORACLE_KEY);
        swarm.submit(address(mt), s, st);
        assertEq(mt.proposedOutcome(), 2); // 44 is not over 44
    }

    // ── dispute tier ────────────────────────────────────────────────────────

    function _disputeIt() internal {
        swarm.submit(address(m), _answer(1, 25, 13, 13), _start(kickoff));
        uint256 bond = disputes.bondFor(address(m));
        imd.mint(carol, bond);
        vm.startPrank(carol);
        imd.approve(address(disputes), bond);
        disputes.dispute(address(m));
        vm.stopPrank();
    }

    function _panelAnswer(uint256 code, uint16 panel, uint16 quorum, uint16 agreed)
        internal
        view
        returns (SwarmResolver.Signed memory)
    {
        return _signed(
            swarmDispute,
            _att(swarmDispute, question, code, panel, quorum, agreed, keccak256("req-panel")),
            question,
            ORACLE_KEY
        );
    }

    function test_disputeTier_agreementUpholds() public {
        _disputeIt();
        swarmDispute.submit(address(m), _panelAnswer(1, 100, 67, 70), _none());
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Final));
        assertEq(m.finalOutcome(), 1);
    }

    function test_disputeTier_disagreementEscalates() public {
        _disputeIt();
        swarmDispute.submit(address(m), _panelAnswer(2, 100, 67, 67), _none());
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Escalated));
    }

    function test_disputeTier_enforcesLargerPanel() public {
        _disputeIt();
        SwarmResolver.Signed memory ans22 = _panelAnswer(1, 25, 13, 13);
        SwarmResolver.Signed memory st22 = _none();
        vm.expectRevert(SwarmResolver.PanelTooSmall.selector);
        swarmDispute.submit(address(m), ans22, st22);
        SwarmResolver.Signed memory ans23 = _panelAnswer(1, 100, 67, 66);
        SwarmResolver.Signed memory st23 = _none();
        vm.expectRevert(SwarmResolver.NotEnoughAgreement.selector);
        swarmDispute.submit(address(m), ans23, st23);
    }

    function test_disputeTier_primaryAnswerCannotBeReused() public {
        SwarmResolver.Signed memory primary = _answer(1, 100, 67, 67);
        swarm.submit(address(m), primary, _start(kickoff));
        uint256 bond = disputes.bondFor(address(m));
        imd.mint(carol, bond);
        vm.startPrank(carol);
        imd.approve(address(disputes), bond);
        disputes.dispute(address(m));
        vm.stopPrank();
        // the primary signature names the primary resolver, not the dispute resolver
        SwarmResolver.Signed memory ans24 = primary;
        SwarmResolver.Signed memory st24 = _none();
        vm.expectRevert(SwarmResolver.InvalidSignature.selector);
        swarmDispute.submit(address(m), ans24, st24);
    }

    function test_disputeTier_withoutDisputeRefused() public {
        swarm.submit(address(m), _answer(1, 25, 13, 13), _start(kickoff));
        SwarmResolver.Signed memory ans25 = _panelAnswer(1, 100, 67, 67);
        SwarmResolver.Signed memory st25 = _none();
        vm.expectRevert();
        swarmDispute.submit(address(m), ans25, st25);
    }

    // ── constructor ─────────────────────────────────────────────────────────

    function test_constructor_validation() public {
        IPredictionRegistry r = IPredictionRegistry(address(registry));
        vm.expectRevert(SwarmResolver.InvalidConfiguration.selector);
        new SwarmResolver(r, address(0), SwarmResolver.Tier.Primary, 25, 13);
        vm.expectRevert(SwarmResolver.InvalidConfiguration.selector);
        new SwarmResolver(r, oracleSigner, SwarmResolver.Tier.Primary, 4, 3);
        vm.expectRevert(SwarmResolver.InvalidConfiguration.selector);
        new SwarmResolver(r, oracleSigner, SwarmResolver.Tier.Primary, 25, 26);
        vm.expectRevert(SwarmResolver.InvalidConfiguration.selector);
        new SwarmResolver(r, oracleSigner, SwarmResolver.Tier.Primary, 25, 0);
    }
}

/// @notice Replays a real attestation signed by the production oracle service key, proving the struct hash and
///         EIP-712 domain match the live service byte for byte. The request was bought for a consumer contract on
///         Sepolia, so the resolver is deployed AT that consumer address on that chain id, the only place the
///         original signature verifies. (Public data: it is the same fixture the open-source oracle co-op hub
///         tests replay.)
contract SwarmResolverLiveSignatureTest is MarketsBase {
    address constant SERVICE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant LIVE_CONSUMER = 0x5bbFA44200AcE481388B0B69355F7Bd1FeAb0462;
    uint256 constant SEPOLIA = 11155111;
    bytes constant SIG =
        hex"8303bd1ea1bc22a4f4b32ac95dedb591d0facdc07e23fdbbe2ef3da4194bf8cf7d94b98d49ffe924b326b6980811fdb403a8ee7ca766ff9bd24cbfe8d8b85da21c";

    function _live() internal pure returns (SwarmResolver.Attestation memory) {
        return SwarmResolver.Attestation({
            requestId: 0xe2c85027f00e4b988d7c713694509b6e00000000000000000000000000000000,
            chainId: 1,
            questionHash: 0xc87aa8a9fa49ca4885e3c3048e9159cd00578e7ad37188b1fce70199c510c16e,
            answerType: 3,
            answer: hex"000000000000000000000000000000000000000000000000000d3ff87714bef1",
            figure: 3729511079526129,
            fromBlock: 26120928,
            toBlock: 26121526,
            blockHash: 0x661f90063244eaa60ab43a4b65a46dd1a58b2a6e03526f0f4c80c1ca04988429,
            panelJobId: 0x85d6177a7f9b4b938c1a76fc35f733b500000000000000000000000000000000,
            panelSize: 60,
            quorum: 20,
            agreed: 20,
            issuedAt: 1791147640,
            expiresAt: 1791234040
        });
    }

    function _resolverAt(address where) internal returns (SwarmResolver) {
        vm.chainId(SEPOLIA);
        deployCodeTo(
            "SwarmResolver.sol:SwarmResolver",
            abi.encode(address(registry), SERVICE_SIGNER, SwarmResolver.Tier.Primary, 25, 13),
            where
        );
        return SwarmResolver(where);
    }

    function test_liveProductionSignature_recoversServiceSigner() public {
        SwarmResolver r = _resolverAt(LIVE_CONSUMER);
        assertEq(r.signerOf(_live(), SIG), SERVICE_SIGNER);
    }

    function test_liveSignature_isBoundToItsConsumer() public {
        SwarmResolver r = _resolverAt(address(0xC0FFEE));
        assertTrue(r.signerOf(_live(), SIG) != SERVICE_SIGNER);
    }

    function test_liveSignature_isBoundToItsChain() public {
        SwarmResolver r = _resolverAt(LIVE_CONSUMER);
        vm.chainId(1);
        assertTrue(r.signerOf(_live(), SIG) != SERVICE_SIGNER);
    }

    /// @notice The live panel signed agreed == quorum, so the absolute-count rule (agreed >= quorum) accepts the
    ///         real thing while still refusing the agreed < quorum case.
    function test_liveAgreementMeetsQuorum() public pure {
        SwarmResolver.Attestation memory a = _live();
        assertGe(a.agreed, a.quorum);
    }
}
