// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { PredictionRegistry } from "../../src/markets/PredictionRegistry.sol";
import { MarketFactory } from "../../src/markets/MarketFactory.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";
import { EligibilityGate } from "../../src/markets/EligibilityGate.sol";
import { UsdcDoor } from "../../src/markets/UsdcDoor.sol";
import { ExitDesk } from "../../src/markets/ExitDesk.sol";
import { DisputeModule } from "../../src/markets/DisputeModule.sol";
import { SwarmResolver } from "../../src/markets/SwarmResolver.sol";
import { CouncilResolver } from "../../src/markets/CouncilResolver.sol";
import { IPredictionRegistry, IUsdcSwapper, IPegPriceFeed } from "../../src/markets/interfaces/IMarkets.sol";
import { MockImdUSD, MockUSDC } from "./mocks/MarketMockTokens.sol";
import { MockUsdcSwapper, MockPegPriceFeed, MockMarketResolver } from "./mocks/MarketMockOracles.sol";

/// @notice Shared deployment and helpers for the market tests. The system is wired exactly as the deploy script
///         wires it, with a mock resolver allow-listed beside the real SwarmResolver so state-machine tests can
///         drive proposals without signing attestations.
abstract contract MarketsBase is Test {
    uint256 internal constant KYC_KEY = 0xA11CE;
    uint256 internal constant ORACLE_KEY = 0x0D1E5;

    uint256 internal constant WALLET_CAP = 250e18;
    uint256 internal constant MARKET_CAP = 10_000e18;
    uint256 internal constant MIN_STAKE = 1e18;
    uint32 internal constant LOCK_MARGIN = 180;

    address internal owner = makeAddr("multisig");
    address internal treasury = makeAddr("treasury");
    address internal resolverBudget = makeAddr("resolverBudget");
    address internal insurance = makeAddr("insurance");
    address internal creator = makeAddr("creator");
    address internal crewMod = makeAddr("crewMod");
    address internal crewEditor = makeAddr("crewEditor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");

    address[] internal councilMembers;
    address internal kycSigner;
    address internal oracleSigner;

    MockImdUSD internal imd;
    MockUSDC internal usdc;
    MockUsdcSwapper internal swapper;
    MockPegPriceFeed internal feed;

    PredictionRegistry internal registry;
    MarketFactory internal factory;
    EligibilityGate internal gate;
    UsdcDoor internal door;
    ExitDesk internal desk;
    DisputeModule internal disputes;
    SwarmResolver internal swarm;
    SwarmResolver internal swarmDispute;
    CouncilResolver internal council;
    MockMarketResolver internal mockResolver;
    MockMarketResolver internal mockDisputeResolver;

    uint256 internal tWinner; // coded, 2 outcomes, source-clock lock
    uint256 internal t3Way; // coded, 3 outcomes, source-clock lock
    uint256 internal tMilestone; // bool, no start question, 24 h lock gap
    uint256 internal tTotal; // threshold, source-clock lock

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        kycSigner = vm.addr(KYC_KEY);
        oracleSigner = vm.addr(ORACLE_KEY);
        for (uint256 i; i < 5; ++i) {
            councilMembers.push(makeAddr(string.concat("council", vm.toString(i))));
        }

        imd = new MockImdUSD();
        usdc = new MockUSDC();
        swapper = new MockUsdcSwapper(usdc, imd);
        feed = new MockPegPriceFeed();

        registry = new PredictionRegistry(owner, address(imd), _config());
        gate = new EligibilityGate(owner, kycSigner);
        door = new UsdcDoor(IPredictionRegistry(address(registry)), address(usdc), address(imd), swapper);
        desk = new ExitDesk(
            owner, IPredictionRegistry(address(registry)), address(usdc), address(imd), door, feed, 1 hours
        );
        disputes = new DisputeModule(IPredictionRegistry(address(registry)));
        swarm = new SwarmResolver(
            IPredictionRegistry(address(registry)), oracleSigner, SwarmResolver.Tier.Primary, 25, 13
        );
        swarmDispute = new SwarmResolver(
            IPredictionRegistry(address(registry)), oracleSigner, SwarmResolver.Tier.Dispute, 100, 67
        );
        council = new CouncilResolver(councilMembers, 3);
        mockResolver = new MockMarketResolver();
        mockDisputeResolver = new MockMarketResolver();
        factory = new MarketFactory(registry);

        address[] memory crew = new address[](2);
        crew[0] = crewMod;
        crew[1] = crewEditor;

        vm.startPrank(owner);
        registry.setModules(
            address(door),
            address(gate),
            address(desk),
            address(disputes),
            address(mockDisputeResolver),
            address(council)
        );
        registry.setFactory(address(factory));
        registry.setResolver(address(swarm), true);
        registry.setResolver(address(mockResolver), true);
        registry.setCreator(creator, true, crew);
        tWinner = registry.addTemplate(_winnerTemplate());
        t3Way = registry.addTemplate(_threeWayTemplate());
        tMilestone = registry.addTemplate(_milestoneTemplate());
        tTotal = registry.addTemplate(_totalTemplate());
        vm.stopPrank();

        // Fund the exit desk generously so the open-interest rule does not bind unless a test wants it to.
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(desk), type(uint256).max);
        desk.fund(1_000_000e6);
    }

    // ── configuration ───────────────────────────────────────────────────────

    function _config() internal view returns (PredictionRegistry.Config memory c) {
        c.treasury = treasury;
        c.resolverBudget = resolverBudget;
        c.insurance = insurance;
        c.rake = MarketTypes.RakeSplit({ treasuryBps: 100, creatorBps: 75, resolverBps: 50, insuranceBps: 25 });
        c.perWalletCap = uint128(WALLET_CAP);
        c.perMarketCap = uint128(MARKET_CAP);
        c.minStake = uint128(MIN_STAKE);
        c.minBond = 50e18;
        c.bondBps = 200;
        c.creatorBond = 0;
        c.lockMargin = LOCK_MARGIN;
    }

    bytes internal constant WINNER_HEAD =
        '{"answerType":"uint256","chainId":1,"definitions":{"codes":"Answer with one code: 1 = the home team won, 2 = the away team won, 3 = draw, 4 = postponed and not completed within 48 hours of the scheduled start, 5 = abandoned with no official result.","scope":"Final result including overtime, as officially recorded by the league."},"question":"';
    bytes internal constant START_HEAD =
        '{"answerType":"uint256","chainId":1,"definitions":{"scope":"The official start time recorded by the league, in unix seconds."},"question":"';
    bytes internal constant WINDOW_TAIL = '","v":1,"window":{"fromBlock":';

    function _gameParts(bytes memory head, bytes memory ask) internal pure returns (bytes[] memory p) {
        p = new bytes[](4);
        p[0] = head;
        p[1] = ": ";
        p[2] = " (away) at ";
        p[3] = bytes.concat(" (home). ", ask, WINDOW_TAIL);
    }

    function _winnerTemplate() internal pure returns (MarketTypes.Template memory t) {
        t.name = "game.winner.2way";
        t.parts = _gameParts(WINNER_HEAD, "Which side won the game, overtime included?");
        t.startParts = _gameParts(START_HEAD, "At what time did the game officially start, in unix seconds?");
        t.slotCount = 3;
        t.outcomeCount = 2;
        t.answerMode = MarketTypes.AnswerMode.Coded;
        t.answerType = MarketTypes.ANSWER_UINT256;
        // codes 0..5 -> outcome: 1 home -> 1, 2 away -> 2, draw/postponed/abandoned -> VOID
        t.codeMap = hex"000102000000";
        t.dataChainId = 1;
        t.disputeWindow = 2 hours;
        t.minLockGap = 0;
    }

    function _threeWayTemplate() internal pure returns (MarketTypes.Template memory t) {
        t = _winnerTemplate();
        t.name = "game.result.3way";
        t.parts = _gameParts(WINNER_HEAD, "What was the result after full time?");
        t.outcomeCount = 3;
        // 1 home -> 1, 2 away -> 3, 3 draw -> 2, postponed/abandoned -> VOID (outcome order home, draw, away)
        t.codeMap = hex"000103020000";
    }

    function _milestoneTemplate() internal pure returns (MarketTypes.Template memory t) {
        t.name = "creator.milestone";
        t.parts = new bytes[](4);
        t.parts[0] =
            '{"answerType":"bool","chainId":1,"definitions":{"scope":"Count as shown by the platform public page and one independent tracker."},"question":"Does the Kick channel ';
        t.parts[1] = " have at least ";
        t.parts[2] = " followers at ";
        t.parts[3] = bytes.concat("?", WINDOW_TAIL);
        t.slotCount = 3;
        t.outcomeCount = 2;
        t.answerMode = MarketTypes.AnswerMode.Bool;
        t.answerType = MarketTypes.ANSWER_BOOL;
        t.dataChainId = 1;
        t.disputeWindow = 24 hours;
        t.minLockGap = 24 hours;
    }

    function _totalTemplate() internal pure returns (MarketTypes.Template memory t) {
        t = _winnerTemplate();
        t.name = "game.total";
        t.parts = _gameParts(
            '{"answerType":"uint256","chainId":1,"definitions":{"scope":"Sum of both official final scores, overtime included."},"question":"',
            "How many points did the two teams score in total?"
        );
        t.answerMode = MarketTypes.AnswerMode.Threshold;
        t.codeMap = "";
    }

    function _gameSlots() internal pure returns (bytes[] memory s) {
        s = new bytes[](3);
        s[0] = "NFL, 25 Oct 2026";
        s[1] = "Away Team";
        s[2] = "Home Team";
    }

    function _milestoneSlots() internal pure returns (bytes[] memory s) {
        s = new bytes[](3);
        s[0] = "example_channel";
        s[1] = "250000";
        s[2] = "2026-12-20 00:00 UTC";
    }

    // ── market helpers ──────────────────────────────────────────────────────

    function _create(uint256 templateId, bytes[] memory slots, uint64 lockAt, uint64 resolveAfter, uint256 threshold)
        internal
        returns (ParimutuelMarket m)
    {
        return _createWith(templateId, slots, lockAt, resolveAfter, threshold, address(mockResolver));
    }

    function _createWith(
        uint256 templateId,
        bytes[] memory slots,
        uint64 lockAt,
        uint64 resolveAfter,
        uint256 threshold,
        address resolver
    ) internal returns (ParimutuelMarket m) {
        MarketFactory.CreateParams memory p = MarketFactory.CreateParams({
            templateId: templateId,
            slots: slots,
            lockAt: lockAt,
            resolveAfter: resolveAfter,
            threshold: threshold,
            resolver: resolver
        });
        vm.prank(creator);
        m = ParimutuelMarket(factory.createMarket(p));
    }

    /// @dev A 2-way game market: locks in 1 day, resolvable 3 hours after lock.
    function _winnerMarket() internal returns (ParimutuelMarket) {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 1 days);
        return _create(tWinner, _gameSlots(), lockAt, lockAt + 3 hours, 0);
    }

    function _pass(address wallet) internal view returns (MarketTypes.EligibilityPass memory p, bytes memory sig) {
        p = MarketTypes.EligibilityPass({
            wallet: wallet,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 hours)
        });
        sig = _signPass(p, KYC_KEY);
    }

    function _signPass(MarketTypes.EligibilityPass memory p, uint256 key) internal view returns (bytes memory) {
        bytes32 d = gate.passDigest(p);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, d);
        return abi.encodePacked(r, s, v);
    }

    function _stake(ParimutuelMarket m, address user, uint8 outcome, uint256 amount) internal {
        imd.mint(user, amount);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(user);
        vm.startPrank(user);
        imd.approve(address(m), amount);
        m.stake(outcome, amount, p, sig);
        vm.stopPrank();
    }

    function _propose(ParimutuelMarket m, uint8 outcome, uint64 attestedStart) internal {
        vm.prank(keeper);
        mockResolver.propose(address(m), outcome, attestedStart);
    }

    /// @dev Warp to resolveAfter, propose, warp past the dispute window, finalize.
    function _resolve(ParimutuelMarket m, uint8 outcome, uint64 attestedStart) internal {
        MarketTypes.Terms memory t = m.terms();
        if (vm.getBlockTimestamp() < t.resolveAfter) vm.warp(t.resolveAfter);
        _propose(m, outcome, attestedStart);
        vm.warp(vm.getBlockTimestamp() + t.disputeWindow);
        m.finalize();
    }

    function _claim(ParimutuelMarket m, address user) internal returns (uint256) {
        vm.prank(user);
        return m.claim();
    }

    function _refund(ParimutuelMarket m, address user) internal returns (uint256) {
        vm.prank(user);
        return m.refund();
    }

    function _councilVote(ParimutuelMarket m, uint8 outcome, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(councilMembers[i]);
            council.vote(address(m), outcome);
        }
    }
}
