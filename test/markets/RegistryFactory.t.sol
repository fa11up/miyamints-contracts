// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { PredictionRegistry } from "../../src/markets/PredictionRegistry.sol";
import { MarketFactory } from "../../src/markets/MarketFactory.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";

contract PredictionRegistryTest is MarketsBase {
    function test_constructor_setsState() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.token(), address(imd));
        PredictionRegistry.Config memory c = registry.config();
        assertEq(c.treasury, treasury);
        assertEq(c.resolverBudget, resolverBudget);
        assertEq(c.insurance, insurance);
        assertEq(c.lockMargin, LOCK_MARGIN);
        assertEq(registry.rakeBps(), 250);
        assertEq(registry.templateCount(), 4);
        assertEq(registry.factory(), address(factory));
    }

    function test_constructor_validation() public {
        PredictionRegistry.Config memory c = _config();
        vm.expectRevert(PredictionRegistry.InvalidAddress.selector);
        new PredictionRegistry(owner, address(0), c);
        c.treasury = address(0);
        vm.expectRevert(PredictionRegistry.InvalidAddress.selector);
        new PredictionRegistry(owner, address(imd), c);
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setRecipients(alice, alice, alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setModules(alice, alice, alice, alice, alice, alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setRake(MarketTypes.RakeSplit(0, 0, 0, 0));
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setLimits(1e18, 1e18, 1e18, 180);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setBonds(1e18, 0, 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.addTemplate(_winnerTemplate());
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setTemplateActive(0, false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setResolver(alice, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setCreator(alice, true, new address[](0));
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setFactory(alice);
        vm.stopPrank();
    }

    function test_rake_isCapped() public {
        vm.startPrank(owner);
        vm.expectRevert(PredictionRegistry.RakeTooHigh.selector);
        registry.setRake(MarketTypes.RakeSplit(200, 200, 50, 51));
        registry.setRake(MarketTypes.RakeSplit(200, 200, 50, 50));
        vm.stopPrank();
        assertEq(registry.rakeBps(), 500);
    }

    function test_limits_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(PredictionRegistry.InvalidLimits.selector);
        registry.setLimits(100e18, 1_000e18, 1e18, 179); // margin below the three-minute floor
        vm.expectRevert(PredictionRegistry.InvalidLimits.selector);
        registry.setLimits(100e18, 1_000e18, 1e18, 1 days + 1);
        vm.expectRevert(PredictionRegistry.InvalidLimits.selector);
        registry.setLimits(100e18, 1_000e18, 0, 180);
        vm.expectRevert(PredictionRegistry.InvalidLimits.selector);
        registry.setLimits(100e18, 99e18, 1e18, 180);
        vm.expectRevert(PredictionRegistry.InvalidLimits.selector);
        registry.setLimits(1e18, 1_000e18, 2e18, 180);
        registry.setLimits(100e18, 1_000e18, 1e18, 180);
        vm.stopPrank();
    }

    function test_bonds_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(PredictionRegistry.InvalidBond.selector);
        registry.setBonds(0, 200, 0);
        vm.expectRevert(PredictionRegistry.InvalidBond.selector);
        registry.setBonds(50e18, 1_001, 0);
        vm.stopPrank();
    }

    function test_template_validation() public {
        vm.startPrank(owner);
        MarketTypes.Template memory t = _winnerTemplate();
        t.parts[3] = "no window marker";
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _winnerTemplate();
        t.slotCount = 2;
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _winnerTemplate();
        t.startParts = new bytes[](2);
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _winnerTemplate();
        t.codeMap = hex"0003";
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _winnerTemplate();
        t.outcomeCount = 1;
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _winnerTemplate();
        t.disputeWindow = 59 minutes;
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _milestoneTemplate();
        t.answerType = MarketTypes.ANSWER_UINT256;
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);

        t = _totalTemplate();
        t.outcomeCount = 3;
        vm.expectRevert(PredictionRegistry.InvalidTemplate.selector);
        registry.addTemplate(t);
        vm.stopPrank();
    }

    function test_template_activeToggle() public {
        vm.prank(owner);
        registry.setTemplateActive(tWinner, false);
        assertFalse(registry.getTemplate(tWinner).active);
        vm.prank(owner);
        vm.expectRevert(PredictionRegistry.UnknownTemplate.selector);
        registry.setTemplateActive(99, true);
        vm.expectRevert(PredictionRegistry.UnknownTemplate.selector);
        registry.getTemplate(99);
    }

    function test_creator_crewBounded() public {
        address[] memory crew = new address[](33);
        for (uint256 i; i < 33; ++i) {
            crew[i] = address(uint160(i + 1));
        }
        vm.prank(owner);
        vm.expectRevert(PredictionRegistry.CrewTooLarge.selector);
        registry.setCreator(alice, true, crew);
        crew = new address[](1);
        vm.prank(owner);
        vm.expectRevert(PredictionRegistry.InvalidAddress.selector);
        registry.setCreator(alice, true, crew);
    }

    function test_marketHooks_onlyFactoryAndMarkets() public {
        vm.expectRevert(PredictionRegistry.NotFactory.selector);
        registry.registerMarket(alice, alice, bytes32(0));
        vm.expectRevert(PredictionRegistry.NotMarket.selector);
        registry.onStake(1);
        vm.expectRevert(PredictionRegistry.NotMarket.selector);
        registry.onRelease(1);
    }
}

contract MarketFactoryTest is MarketsBase {
    function _params(uint256 templateId, bytes[] memory slots)
        internal
        view
        returns (MarketFactory.CreateParams memory p)
    {
        uint64 lockAt = uint64(vm.getBlockTimestamp() + 1 days);
        p = MarketFactory.CreateParams({
            templateId: templateId,
            slots: slots,
            lockAt: lockAt,
            resolveAfter: lockAt + 3 hours,
            threshold: 0,
            resolver: address(mockResolver)
        });
    }

    function test_create_registersCloneWithOnChainHash() public {
        (bytes memory q, bytes memory s) = factory.buildPrefixes(tWinner, _gameSlots());
        vm.expectEmit(false, true, true, false);
        emit MarketFactory.MarketCreated(address(0), creator, tWinner, keccak256(q), keccak256(s), q, s);
        ParimutuelMarket m = _winnerMarket();
        assertTrue(registry.isMarket(address(m)));
        assertEq(registry.marketCount(), 1);
        assertEq(m.terms().questionHash, keccak256(q));
        assertEq(m.terms().startQuestionHash, keccak256(s));
        // exact EIP-1167 minimal proxy runtime
        assertEq(
            address(m).code,
            bytes.concat(
                hex"363d3d373d3d3d363d73", bytes20(factory.implementation()), hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        ParimutuelMarket m2 = _winnerMarket();
        assertTrue(address(m2) != address(m));
    }

    function test_create_onlyActiveCreators() public {
        MarketFactory.CreateParams memory p = _params(tWinner, _gameSlots());
        vm.prank(alice);
        vm.expectRevert(MarketFactory.NotCreator.selector);
        factory.createMarket(p);
        vm.prank(owner);
        registry.setCreator(creator, false, new address[](0));
        vm.prank(creator);
        vm.expectRevert(MarketFactory.NotCreator.selector);
        factory.createMarket(p);
    }

    function test_create_inactiveTemplate() public {
        vm.prank(owner);
        registry.setTemplateActive(tWinner, false);
        MarketFactory.CreateParams memory p = _params(tWinner, _gameSlots());
        vm.prank(creator);
        vm.expectRevert(MarketFactory.TemplateInactive.selector);
        factory.createMarket(p);
    }

    function test_create_resolverMustBeAllowed() public {
        MarketFactory.CreateParams memory p = _params(tWinner, _gameSlots());
        p.resolver = alice;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.ResolverNotAllowed.selector);
        factory.createMarket(p);
    }

    function test_create_slotRules() public {
        bytes[] memory slots = _gameSlots();
        string[6] memory bad = ['A"B', "A\\B", "line\nbreak", "", "caf\xc3\xa9", "tab\there"];
        for (uint256 i; i < bad.length; ++i) {
            slots[1] = bytes(bad[i]);
            MarketFactory.CreateParams memory p = _params(tWinner, slots);
            vm.prank(creator);
            vm.expectRevert(abi.encodeWithSelector(MarketFactory.InvalidSlot.selector, 1));
            factory.createMarket(p);
        }
        slots[1] = new bytes(257);
        for (uint256 i; i < 257; ++i) {
            slots[1][i] = "a";
        }
        MarketFactory.CreateParams memory p2 = _params(tWinner, slots);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MarketFactory.InvalidSlot.selector, 1));
        factory.createMarket(p2);

        bytes[] memory two = new bytes[](2);
        two[0] = "a";
        two[1] = "b";
        MarketFactory.CreateParams memory p3 = _params(tWinner, two);
        vm.prank(creator);
        vm.expectRevert(MarketFactory.WrongSlotCount.selector);
        factory.createMarket(p3);
    }

    function test_create_timeRules() public {
        MarketFactory.CreateParams memory p = _params(tWinner, _gameSlots());
        p.lockAt = uint64(vm.getBlockTimestamp());
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidTimes.selector);
        factory.createMarket(p);

        p = _params(tWinner, _gameSlots());
        p.lockAt = uint64(vm.getBlockTimestamp() + 366 days);
        p.resolveAfter = p.lockAt + 1;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidTimes.selector);
        factory.createMarket(p);

        p = _params(tWinner, _gameSlots());
        p.resolveAfter = p.lockAt - 1;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidTimes.selector);
        factory.createMarket(p);

        // milestone markets lock at least 24 h before the deadline
        p = _params(tMilestone, _milestoneSlots());
        p.resolveAfter = p.lockAt + 24 hours - 1;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidTimes.selector);
        factory.createMarket(p);
        p.resolveAfter = p.lockAt + 24 hours;
        vm.prank(creator);
        factory.createMarket(p);

        // a market can't put off its result, and so its void path, past the cap
        p = _params(tWinner, _gameSlots());
        p.resolveAfter = p.lockAt + factory.MAX_RESOLVE_GAP() + 1;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidTimes.selector);
        factory.createMarket(p);
        p.resolveAfter = type(uint64).max;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidTimes.selector);
        factory.createMarket(p);
        p.resolveAfter = p.lockAt + factory.MAX_RESOLVE_GAP();
        vm.prank(creator);
        ParimutuelMarket m = ParimutuelMarket(factory.createMarket(p));
        vm.warp(uint256(p.resolveAfter) + m.PROPOSE_GRACE() + 1);
        m.voidUnresolved();
        assertEq(uint8(m.state()), uint8(MarketTypes.State.Void));
    }

    function test_create_thresholdOnlyForThresholdTemplates() public {
        MarketFactory.CreateParams memory p = _params(tWinner, _gameSlots());
        p.threshold = 44;
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidThreshold.selector);
        factory.createMarket(p);
    }

    function test_create_refusesUntilModulesWired() public {
        vm.prank(owner);
        registry.setModules(address(door), address(gate), address(desk), address(0), address(0), address(council));
        MarketFactory.CreateParams memory p = _params(tWinner, _gameSlots());
        vm.prank(creator);
        vm.expectRevert(MarketFactory.ModulesNotSet.selector);
        factory.createMarket(p);
    }

    function test_create_denyListFromRegisteredCrew() public {
        ParimutuelMarket m = _winnerMarket();
        assertTrue(m.isDenied(creator));
        assertTrue(m.isDenied(crewMod));
        assertTrue(m.isDenied(crewEditor));
    }

    function test_buildPrefixes_milestoneHasNoStart() public view {
        (bytes memory q, bytes memory s) = factory.buildPrefixes(tMilestone, _milestoneSlots());
        assertEq(s.length, 0);
        assertEq(
            q,
            bytes.concat(
                '{"answerType":"bool","chainId":1,"definitions":{"scope":"Count as shown by the platform public page and one independent tracker."},"question":"Does the Kick channel example_channel have at least 250000 followers at 2026-12-20 00:00 UTC?',
                '","v":1,"window":{"fromBlock":'
            )
        );
    }
}
