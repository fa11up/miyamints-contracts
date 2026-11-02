// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PasswordTierGatingModule} from "../../src/gating/PasswordTierGatingModule.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract PasswordTierGatingModuleTest is Test {
    PasswordTierGatingModule module;
    MiyaRegistry registry;
    address instance1 = address(0xAAAA);
    address instance2 = address(0xBBBB);
    address user1 = address(0x1111);

    function setUp() public {
        // This test contract plays the registered factory.
        registry = new MiyaRegistry(address(this), address(0xFEE), 100, 1000);
        registry.setFactory(address(this), true);
        module = new PasswordTierGatingModule(address(registry));
    }

    function _volumeCapConfig() internal pure returns (PasswordTierGatingModule.TierConfig memory) {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("tier1password");
        hashes[1] = keccak256("tier2password");
        uint256[] memory caps = new uint256[](2);
        caps[0] = 100e18;
        caps[1] = 500e18;
        return PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });
    }

    // --- configureFor ---

    function test_configureFor_setsConfig() public {
        vm.prank(address(this)); // simulates factory calling on behalf of instance1
        module.configureFor(instance1, _volumeCapConfig());
        assertTrue(module.configured(instance1));
    }

    function test_configureFor_revertsIfUnauthorizedCaller() public {
        address attacker = address(0xDEAD);
        // attacker is not a registered factory in the MiyaRegistry
        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        module.configureFor(instance1, _volumeCapConfig());
    }

    function test_configureFor_revertsAfterFactoryUnregistered() public {
        registry.setFactory(address(this), false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        module.configureFor(instance1, _volumeCapConfig());
    }

    function test_configureFor_ownerCanReconfigure() public {
        // Initial config by factory (test contract — registered in MiyaRegistry)
        module.configureFor(instance1, _volumeCapConfig());
        assertTrue(module.configured(instance1));

        // Re-config must come from the instance owner; instance1 is address(0xAAAA) which
        // has no deployed code, so we use vm.mockCall to make owner() return address(this).
        vm.mockCall(instance1, abi.encodeWithSignature("owner()"), abi.encode(address(this)));
        module.configureFor(instance1, _volumeCapConfig());
        assertTrue(module.configured(instance1));
    }

    function test_configureFor_revertsIfNonOwnerReconfigures() public {
        module.configureFor(instance1, _volumeCapConfig());

        vm.mockCall(instance1, abi.encodeWithSignature("owner()"), abi.encode(address(this)));
        address notOwner = address(0xBEEF);
        vm.prank(notOwner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        module.configureFor(instance1, _volumeCapConfig());
    }

    function test_configureFor_isolatedPerInstance() public {
        module.configureFor(instance1, _volumeCapConfig());
        assertFalse(module.configured(instance2));
    }

    // --- canMint / onMint (VOLUME_CAP) ---

    function test_canMint_openTier_noPassword() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.prank(instance1);
        // open tier (no password) = unlimited
        (bool allowed,) = module.canMint(user1, 1e18, abi.encode(bytes32(0), uint256(0)));
        assertTrue(allowed);
    }

    function test_canMint_correctPassword_withinCap() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.prank(instance1);
        (bool allowed,) = module.canMint(user1, 50e18, abi.encode(keccak256("tier1password"), uint256(0)));
        assertTrue(allowed);
    }

    function test_canMint_wrongPassword_reverts() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.prank(instance1);
        vm.expectRevert(PasswordTierGatingModule.InvalidPassword.selector);
        module.canMint(user1, 1e18, abi.encode(keccak256("wrongpassword"), uint256(0)));
    }

    function test_onMint_tracksVolume() public {
        module.configureFor(instance1, _volumeCapConfig());
        vm.startPrank(instance1);
        module.canMint(user1, 50e18, abi.encode(keccak256("tier1password"), uint256(0)));
        module.onMint(user1, 50e18);
        // second buy: 50+60=110 > cap of 100 → should revert
        vm.expectRevert(PasswordTierGatingModule.VolumeCapExceeded.selector);
        module.canMint(user1, 60e18, abi.encode(keccak256("tier1password"), uint256(0)));
        vm.stopPrank();
    }

    function test_volumeState_isolatedPerInstance() public {
        module.configureFor(instance1, _volumeCapConfig());
        module.configureFor(instance2, _volumeCapConfig());
        vm.prank(instance1);
        module.onMint(user1, 90e18);
        // instance2's user1 should be unaffected
        vm.prank(instance2);
        (bool allowed2,) = module.canMint(user1, 90e18, abi.encode(keccak256("tier1password"), uint256(0)));
        assertTrue(allowed2);
    }

    // ── TIME_BASED enforcement ────────────────────────────────────────────────

    function _setupTimeBasedInstance(address instance) internal {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("tier1pass");  // tier 1: unlocks after 1 hour
        hashes[1] = keccak256("tier2pass");  // tier 2: unlocks after 24 hours

        uint256[] memory unlockTimes = new uint256[](2);
        unlockTimes[0] = 1 hours;
        unlockTimes[1] = 24 hours;

        PasswordTierGatingModule.TierConfig memory config = PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.TIME_BASED,
            passwordHashes: hashes,
            volumeCaps: new uint256[](0),
            tierUnlockTimes: unlockTimes
        });

        // Called from test contract — the test contract is a registered factory.
        module.configureFor(instance, config);
    }

    function test_timeBased_tier0_alwaysOpen() public {
        address inst = address(0x1111);
        _setupTimeBasedInstance(inst);

        // openTime = now, tier 0 (no password) — always mintable
        uint256 openTime = block.timestamp;
        bytes memory data = abi.encode(bytes32(0), openTime);

        vm.prank(inst);
        (bool a1,) = module.canMint(address(0xAAAA1), 1, data);
        assertTrue(a1);
    }

    function test_timeBased_tier1_lockedBeforeUnlock() public {
        address inst = address(0x1111);
        _setupTimeBasedInstance(inst);

        uint256 openTime = block.timestamp;
        bytes32 tier1Hash = keccak256("tier1pass");
        bytes memory data = abi.encode(tier1Hash, openTime);

        // 30 minutes after open — tier 1 requires 1 hour
        vm.warp(block.timestamp + 30 minutes);

        vm.prank(inst);
        vm.expectRevert(PasswordTierGatingModule.TierTimeLocked.selector);
        module.canMint(address(0xAAAA1), 1, data);
    }

    function test_timeBased_tier1_openAfterUnlock() public {
        address inst = address(0x1111);
        _setupTimeBasedInstance(inst);

        uint256 openTime = block.timestamp;
        bytes32 tier1Hash = keccak256("tier1pass");
        bytes memory data = abi.encode(tier1Hash, openTime);

        // 2 hours after open — tier 1 requires only 1 hour
        vm.warp(block.timestamp + 2 hours);

        vm.prank(inst);
        (bool a2,) = module.canMint(address(0xAAAA1), 1, data);
        assertTrue(a2);
    }

    function test_timeBased_tier2_lockedEvenAfterTier1Unlock() public {
        address inst = address(0x1111);
        _setupTimeBasedInstance(inst);

        uint256 openTime = block.timestamp;
        bytes32 tier2Hash = keccak256("tier2pass");
        bytes memory data = abi.encode(tier2Hash, openTime);

        // 2 hours after open — tier 2 requires 24 hours
        vm.warp(block.timestamp + 2 hours);

        vm.prank(inst);
        vm.expectRevert(PasswordTierGatingModule.TierTimeLocked.selector);
        module.canMint(address(0xAAAA1), 1, data);
    }

    function test_timeBased_tier2_openAfterFullUnlock() public {
        address inst = address(0x1111);
        _setupTimeBasedInstance(inst);

        uint256 openTime = block.timestamp;
        bytes32 tier2Hash = keccak256("tier2pass");
        bytes memory data = abi.encode(tier2Hash, openTime);

        // 25 hours after open
        vm.warp(block.timestamp + 25 hours);

        vm.prank(inst);
        (bool a3,) = module.canMint(address(0xAAAA1), 1, data);
        assertTrue(a3);
    }

    function test_timeBased_invalidPassword_reverts() public {
        address inst = address(0x1111);
        _setupTimeBasedInstance(inst);

        uint256 openTime = block.timestamp;
        bytes32 wrongHash = keccak256("wrongpass");
        bytes memory data = abi.encode(wrongHash, openTime);

        vm.warp(block.timestamp + 25 hours);

        vm.prank(inst);
        vm.expectRevert(PasswordTierGatingModule.InvalidPassword.selector);
        module.canMint(address(0xAAAA1), 1, data);
    }

    // ── VOLUME_CAP backward compatibility with new encoding ───────────────────

    function test_volumeCap_withOpenTimeInData_stillEnforcesCap() public {
        address inst = address(0x2222);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("vippass");
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10;

        PasswordTierGatingModule.TierConfig memory config = PasswordTierGatingModule.TierConfig({
            tierType: PasswordTierGatingModule.TierType.VOLUME_CAP,
            passwordHashes: hashes,
            volumeCaps: caps,
            tierUnlockTimes: new uint256[](0)
        });

        // Called from test contract — the test contract is a registered factory.
        module.configureFor(inst, config);

        bytes32 tier1Hash = keccak256("vippass");
        bytes memory data = abi.encode(tier1Hash, uint256(block.timestamp));

        // First mint within cap passes
        vm.prank(inst);
        (bool a4,) = module.canMint(address(0xAAAA1), 5, data);
        assertTrue(a4);

        // Record mint
        vm.prank(inst);
        module.onMint(address(0xAAAA1), 5);

        // Second mint that would exceed cap reverts
        vm.prank(inst);
        vm.expectRevert(PasswordTierGatingModule.VolumeCapExceeded.selector);
        module.canMint(address(0xAAAA1), 6, data);
    }
}
