// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";

contract MiyaRegistryTest is Test {
    MiyaRegistry registry;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");
    address factory = makeAddr("factory");
    address vaultFactory = makeAddr("vaultFactory");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");

    function setUp() public {
        registry = new MiyaRegistry(owner, treasury, 100, 1000);
    }

    function _tokens(address a) internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = a;
    }

    // ── constructor ─────────────────────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.treasury(), treasury);
        assertEq(registry.protocolFeeBps(), 100);
        assertEq(registry.minAlignmentBps(), 1000);
        assertEq(registry.targetCount(), 0);
        assertEq(registry.instanceCount(), 0);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        new MiyaRegistry(owner, address(0), 100, 1000);
    }

    function test_constructor_revertsOnFeeAboveCap() public {
        vm.expectRevert(MiyaRegistry.FeeTooHigh.selector);
        new MiyaRegistry(owner, treasury, 501, 1000);
    }

    // ── owner-only setters ──────────────────────────────────────────────────

    function test_setters_onlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setTreasury(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setFees(0, 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.addTarget("x", _tokens(tokenA));
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setTargetActive(0, false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setComponent(tokenA, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setFactory(factory, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setVaultFactory(vaultFactory, true);
        vm.stopPrank();
    }

    function test_setTreasury() public {
        address t2 = makeAddr("t2");
        vm.expectEmit(false, false, false, true, address(registry));
        emit MiyaRegistry.TreasuryUpdated(t2);
        vm.prank(owner);
        registry.setTreasury(t2);
        assertEq(registry.treasury(), t2);
    }

    function test_setTreasury_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.setTreasury(address(0));
    }

    function test_setFees_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit MiyaRegistry.FeesUpdated(250, 1500);
        vm.prank(owner);
        registry.setFees(250, 1500);
        assertEq(registry.protocolFeeBps(), 250);
        assertEq(registry.minAlignmentBps(), 1500);
    }

    function test_setFees_capAt500() public {
        vm.startPrank(owner);
        registry.setFees(500, 1000);
        assertEq(registry.protocolFeeBps(), 500);
        vm.expectRevert(MiyaRegistry.FeeTooHigh.selector);
        registry.setFees(501, 1000);
        vm.stopPrank();
    }

    function testFuzz_setFees_neverAboveCap(uint16 fee) public {
        vm.prank(owner);
        if (fee > 500) {
            vm.expectRevert(MiyaRegistry.FeeTooHigh.selector);
            registry.setFees(fee, 0);
        } else {
            registry.setFees(fee, 0);
            assertEq(registry.protocolFeeBps(), fee);
        }
    }

    function test_setFees_revertsWhenMinAlignmentPlusFeeExceedsBps() public {
        vm.startPrank(owner);
        registry.setFees(100, 9900); // exactly 10_000 is fine
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.setFees(100, 9901);
        vm.stopPrank();
    }

    // ── checkAlignmentBps ───────────────────────────────────────────────────

    function test_checkAlignmentBps_minimumIs1000() public view {
        registry.checkAlignmentBps(1000);
        registry.checkAlignmentBps(2500);
    }

    function test_checkAlignmentBps_revertsBelowMinimum() public {
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(999);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(0);
    }

    function test_checkAlignmentBps_upperBound() public {
        registry.checkAlignmentBps(9900); // 100 + 9900 == 10_000
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(9901);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(type(uint16).max);
    }

    function testFuzz_checkAlignmentBps(uint16 a) public {
        bool ok = a >= 1000 && uint256(a) + 100 <= 10_000;
        if (!ok) vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(a);
    }

    function test_checkAlignmentBps_followsFeeChanges() public {
        vm.prank(owner);
        registry.setFees(500, 2000);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(1999);
        registry.checkAlignmentBps(9500);
        vm.expectRevert(MiyaRegistry.InvalidAlignment.selector);
        registry.checkAlignmentBps(9501);
    }

    // ── alignment targets ───────────────────────────────────────────────────

    function test_addTarget_storesTokensAndIsActive() public {
        address[] memory t = new address[](3);
        t[0] = tokenA;
        t[1] = tokenB;
        t[2] = tokenA; // duplicate is ignored
        vm.prank(owner);
        uint256 id = registry.addTarget("Remilia", t);

        assertEq(id, 0);
        assertEq(registry.targetCount(), 1);
        assertTrue(registry.isAlignmentTargetActive(id));
        assertTrue(registry.isTokenInTarget(id, tokenA));
        assertTrue(registry.isTokenInTarget(id, tokenB));
        assertFalse(registry.isTokenInTarget(id, stranger));
        (string memory name, bool active, address[] memory tokens) = registry.getTarget(id);
        assertEq(name, "Remilia");
        assertTrue(active);
        assertEq(tokens.length, 2);

        vm.prank(owner);
        assertEq(registry.addTarget("Second", _tokens(tokenB)), 1);
    }

    function test_addTarget_revertsOnEmptyOrZeroToken() public {
        vm.startPrank(owner);
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.addTarget("empty", new address[](0));
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.addTarget("zero", _tokens(address(0)));
        vm.stopPrank();
    }

    function test_setTargetActive_deactivateAndReactivate() public {
        vm.startPrank(owner);
        uint256 id = registry.addTarget("Remilia", _tokens(tokenA));
        vm.expectEmit(true, false, false, true, address(registry));
        emit MiyaRegistry.TargetActiveSet(id, false);
        registry.setTargetActive(id, false);
        assertFalse(registry.isAlignmentTargetActive(id));
        // tokens stay listed; only activity changes
        assertTrue(registry.isTokenInTarget(id, tokenA));
        registry.setTargetActive(id, true);
        assertTrue(registry.isAlignmentTargetActive(id));
        vm.stopPrank();
    }

    function test_targets_unknownId() public {
        assertFalse(registry.isAlignmentTargetActive(7));
        vm.prank(owner);
        vm.expectRevert(MiyaRegistry.UnknownTarget.selector);
        registry.setTargetActive(7, true);
        vm.expectRevert(MiyaRegistry.UnknownTarget.selector);
        registry.getTarget(7);
    }

    // ── components and factories ────────────────────────────────────────────

    function test_setComponent() public {
        vm.startPrank(owner);
        registry.setComponent(tokenA, true);
        assertTrue(registry.isApprovedComponent(tokenA));
        registry.setComponent(tokenA, false);
        assertFalse(registry.isApprovedComponent(tokenA));
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.setComponent(address(0), true);
        vm.stopPrank();
    }

    function test_setFactory() public {
        vm.startPrank(owner);
        registry.setFactory(factory, true);
        assertTrue(registry.isFactoryRegistered(factory));
        registry.setFactory(factory, false);
        assertFalse(registry.isFactoryRegistered(factory));
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.setFactory(address(0), true);
        vm.stopPrank();
    }

    // ── vaults ──────────────────────────────────────────────────────────────

    function test_setVaultFactory() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(registry));
        emit MiyaRegistry.VaultFactorySet(vaultFactory, true);
        registry.setVaultFactory(vaultFactory, true);
        assertTrue(registry.isVaultFactoryRegistered(vaultFactory));
        registry.setVaultFactory(vaultFactory, false);
        assertFalse(registry.isVaultFactoryRegistered(vaultFactory));
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.setVaultFactory(address(0), true);
        vm.stopPrank();
    }

    function test_registerVault_byRegisteredVaultFactory() public {
        address vault = makeAddr("vault");
        vm.prank(owner);
        registry.setVaultFactory(vaultFactory, true);

        assertFalse(registry.isVault(vault));
        vm.expectEmit(true, true, false, false, address(registry));
        emit MiyaRegistry.VaultRegistered(vault, vaultFactory);
        vm.prank(vaultFactory);
        registry.registerVault(vault);
        assertTrue(registry.isVault(vault));
    }

    function test_registerVault_revertsForNonVaultFactory() public {
        vm.prank(stranger);
        vm.expectRevert(MiyaRegistry.NotVaultFactory.selector);
        registry.registerVault(makeAddr("vault"));

        // a collection factory is not a vault factory
        vm.prank(owner);
        registry.setFactory(factory, true);
        vm.prank(factory);
        vm.expectRevert(MiyaRegistry.NotVaultFactory.selector);
        registry.registerVault(makeAddr("vault"));
    }

    function test_registerVault_revertsOnDoubleRegistrationAndZero() public {
        address vault = makeAddr("vault");
        vm.prank(owner);
        registry.setVaultFactory(vaultFactory, true);
        vm.startPrank(vaultFactory);
        registry.registerVault(vault);
        vm.expectRevert(MiyaRegistry.AlreadyRegistered.selector);
        registry.registerVault(vault);
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.registerVault(address(0));
        vm.stopPrank();
    }

    function test_registerVault_stopsAfterVaultFactoryUnregistered() public {
        vm.startPrank(owner);
        registry.setVaultFactory(vaultFactory, true);
        registry.setVaultFactory(vaultFactory, false);
        vm.stopPrank();
        vm.prank(vaultFactory);
        vm.expectRevert(MiyaRegistry.NotVaultFactory.selector);
        registry.registerVault(makeAddr("vault"));
    }

    // ── instances ───────────────────────────────────────────────────────────

    function test_registerInstance_byRegisteredFactory() public {
        address instance = makeAddr("instance");
        address vault = makeAddr("vault");
        address creator = makeAddr("creator");
        vm.prank(owner);
        registry.setFactory(factory, true);

        vm.expectEmit(true, true, true, true, address(registry));
        emit MiyaRegistry.InstanceRegistered(instance, factory, vault, creator);
        vm.prank(factory);
        registry.registerInstance(instance, vault, creator);

        assertEq(registry.vaultOf(instance), vault);
        assertEq(registry.factoryOf(instance), factory);
        assertEq(registry.instanceCount(), 1);
        assertEq(registry.instances(0), instance);
    }

    function test_registerInstance_revertsForUnregisteredFactory() public {
        vm.prank(stranger);
        vm.expectRevert(MiyaRegistry.NotFactory.selector);
        registry.registerInstance(makeAddr("instance"), makeAddr("vault"), stranger);

        // unregistering a factory stops it
        vm.startPrank(owner);
        registry.setFactory(factory, true);
        registry.setFactory(factory, false);
        vm.stopPrank();
        vm.prank(factory);
        vm.expectRevert(MiyaRegistry.NotFactory.selector);
        registry.registerInstance(makeAddr("instance"), makeAddr("vault"), stranger);
    }

    function test_registerInstance_noDoubleRegistration() public {
        address instance = makeAddr("instance");
        address factory2 = makeAddr("factory2");
        vm.startPrank(owner);
        registry.setFactory(factory, true);
        registry.setFactory(factory2, true);
        vm.stopPrank();

        vm.prank(factory);
        registry.registerInstance(instance, makeAddr("vault"), stranger);
        vm.prank(factory);
        vm.expectRevert(MiyaRegistry.AlreadyRegistered.selector);
        registry.registerInstance(instance, makeAddr("vault2"), stranger);
        // a different factory cannot hijack it either
        vm.prank(factory2);
        vm.expectRevert(MiyaRegistry.AlreadyRegistered.selector);
        registry.registerInstance(instance, makeAddr("vault2"), stranger);
        assertEq(registry.factoryOf(instance), factory);
    }

    function test_registerInstance_revertsOnZeroInstance() public {
        vm.prank(owner);
        registry.setFactory(factory, true);
        vm.prank(factory);
        vm.expectRevert(MiyaRegistry.InvalidAddress.selector);
        registry.registerInstance(address(0), makeAddr("vault"), stranger);
    }
}
