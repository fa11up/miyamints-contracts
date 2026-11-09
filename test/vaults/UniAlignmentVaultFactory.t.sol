// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {UniAlignmentVaultFactory} from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import {IMiyaRegistry} from "../../src/registry/interfaces/IMiyaRegistry.sol";
import {MiyaRegistry} from "../../src/registry/MiyaRegistry.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {ClaimMode} from "../../src/interfaces/IAlignmentVault.sol";
import {IzRouter} from "../../src/vaults/uni/IVaultConfig.sol";

contract UniAlignmentVaultFactoryTest is VaultTestBase {
    event SwapTargetSet(address indexed target, bool allowed);
    event EthPoolSet(uint24 fee, int24 tickSpacing);
    event VaultDeployed(address indexed vault, uint256 indexed alignmentTargetId);

    function _salt(bytes11 tag) internal view returns (bytes32) {
        return bytes32(abi.encodePacked(address(factory), bytes1(0x00), tag));
    }

    // ── deployVault ─────────────────────────────────────────────────────────

    function test_deployVault_configuresAndRegisters() public {
        bytes32 salt = _salt(bytes11("v1"));
        address predicted = factory.computeVaultAddress(salt);
        UniAlignmentVault v = UniAlignmentVault(payable(factory.deployVault(salt, 0)));
        assertEq(address(v), predicted);
        assertTrue(registry.isVault(address(v)));
        assertEq(v.owner(), address(factory));
        assertEq(address(v.poolManager()), POOL_MANAGER);
        assertEq(v.zRouter(), address(router));
        assertEq(address(v.registry()), address(registry));
        assertEq(address(v.config()), address(factory));
        assertEq(v.infer(), INFER_ADDR);
        assertEq(v.imd(), IMD_ADDR);
        assertEq(v.alignmentTargetId(), 0);
        PoolKey memory k = v.alignmentPoolKey();
        assertEq(Currency.unwrap(k.currency0), INFER_ADDR);
        assertEq(Currency.unwrap(k.currency1), IMD_ADDR);
        assertEq(k.fee, 12500);
        assertEq(k.tickSpacing, 60);
        assertEq(address(k.hooks), HOOK);
        assertEq(v.protocolTreasury(), treasury);
    }

    function test_deployVault_onlyOwner() public {
        bytes32 salt = _salt(bytes11("v1"));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.deployVault(salt, 0);
    }

    function test_deployVault_saltMustBeBoundToFactory() public {
        vm.expectRevert(UniAlignmentVaultFactory.InvalidVaultSalt.selector);
        factory.deployVault(bytes32(uint256(1)), 0);
        bytes32 bad = bytes32(abi.encodePacked(address(factory), bytes1(0x01), bytes11("x")));
        vm.expectRevert(UniAlignmentVaultFactory.InvalidVaultSalt.selector);
        factory.computeVaultAddress(bad);
    }

    function test_deployVault_needsRegistration() public {
        registry.setVaultFactory(address(factory), false);
        bytes32 salt = _salt(bytes11("v1"));
        vm.expectRevert(MiyaRegistry.NotVaultFactory.selector);
        factory.deployVault(salt, 0);
    }

    function test_deployVault_badPoolKeyReverts() public {
        PoolKey memory k = key;
        k.hooks = IHooks(address(0x1000000000000000000000000000000000000040)); // afterSwap
        UniAlignmentVaultFactory f = new UniAlignmentVaultFactory(
            IMiyaRegistry(address(registry)), IPoolManager(POOL_MANAGER), address(router), INFER_ADDR, IMD_ADDR, k
        );
        registry.setVaultFactory(address(f), true);
        bytes32 salt = bytes32(abi.encodePacked(address(f), bytes1(0x00), bytes11("v")));
        vm.expectRevert(UniAlignmentVault.InvalidPoolKey.selector);
        f.deployVault(salt, 0);
    }

    function test_implementation_cannotBeInitialized() public {
        UniAlignmentVault impl = UniAlignmentVault(payable(factory.vaultImplementation()));
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        impl.disableInitializer();
    }

    function test_vaults_shareTheConfig() public {
        UniAlignmentVault v1 = UniAlignmentVault(payable(factory.deployVault(_salt(bytes11("a")), 0)));
        UniAlignmentVault v2 = UniAlignmentVault(payable(factory.deployVault(_salt(bytes11("b")), 0)));
        assertEq(address(v1.config()), address(v2.config()));
        assertTrue(factory.isSwapTarget(address(router)));
    }

    // ── swap targets ────────────────────────────────────────────────────────

    function test_setSwapTarget_allowAndRemove() public {
        address agg = address(new MiyaRegistry(address(this), treasury, 0, 0)); // any contract
        assertFalse(factory.isSwapTarget(agg));
        vm.expectEmit(true, false, false, true, address(factory));
        emit SwapTargetSet(agg, true);
        factory.setSwapTarget(agg, true);
        assertTrue(factory.isSwapTarget(agg));
        vm.expectEmit(true, false, false, true, address(factory));
        emit SwapTargetSet(agg, false);
        factory.setSwapTarget(agg, false);
        assertFalse(factory.isSwapTarget(agg));
    }

    function test_setSwapTarget_onlyOwner() public {
        vm.prank(keeper); // the keeper can't add targets
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setSwapTarget(address(router), true);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setSwapTarget(address(router), false);
    }

    function test_setSwapTarget_refusesEoasAndVaultInternals() public {
        address[6] memory bad = [alice, address(0), INFER_ADDR, IMD_ADDR, address(registry), address(factory)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(UniAlignmentVaultFactory.InvalidAddress.selector);
            factory.setSwapTarget(bad[i], true);
        }
        // The PoolManager, once it has code.
        vm.etch(POOL_MANAGER, hex"00");
        vm.expectRevert(UniAlignmentVaultFactory.InvalidAddress.selector);
        factory.setSwapTarget(POOL_MANAGER, true);
        // Removing is always possible (an EOA was never allowed, so this is a no-op).
        factory.setSwapTarget(alice, false);
    }

    // ── ETH-claim pool ──────────────────────────────────────────────────────

    function test_ethPool_defaultAndSet() public {
        (uint24 fee, int24 ts) = factory.ethPool();
        assertEq(fee, 10000);
        assertEq(ts, 200);
        vm.expectEmit(false, false, false, true, address(factory));
        emit EthPoolSet(3000, 60);
        factory.setEthPool(3000, 60);
        (fee, ts) = factory.ethPool();
        assertEq(fee, 3000);
        assertEq(ts, 60);
        vm.expectRevert(UniAlignmentVaultFactory.InvalidPool.selector);
        factory.setEthPool(0x800000, 60); // dynamic fee
        vm.expectRevert(UniAlignmentVaultFactory.InvalidPool.selector);
        factory.setEthPool(3000, 0);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setEthPool(500, 10);
    }

    function test_ethPool_usedByEthClaims() public {
        _contributeEth(alice, 1 ether);
        _convert();
        vault.accrueFees(0, 100e18);
        vault.collectFees();
        factory.setEthPool(3000, 60);
        (uint256 inferOwed, uint256 imdOwed,) = vault.claimable(alice);
        assertEq(inferOwed, 0);
        // The claim sells its IMD through zRouter.swapV4 on the factory's pool, read live.
        vm.expectCall(
            address(router),
            abi.encodeCall(IzRouter.swapV4, (address(vault), false, 3000, 60, IMD_ADDR, ETH, imdOwed, 0, block.timestamp))
        );
        vm.prank(alice);
        (,, uint256 ethOut) = vault.claimFees(ClaimMode.ETH, 1);
        assertEq(alice.balance, ethOut);
        assertEq(ethOut, imdOwed * R_IMD_ETH / 1e18);
    }

    function test_minContribution_ownerSet() public {
        assertEq(factory.minContribution(USDC_ADDR), 0);
        vm.expectEmit(true, false, false, true, address(factory));
        emit UniAlignmentVaultFactory.MinContributionSet(USDC_ADDR, 3e6);
        factory.setMinContribution(USDC_ADDR, 3e6);
        assertEq(factory.minContribution(USDC_ADDR), 3e6);
    }

    function test_constructor_zeroAddresses() public {
        vm.expectRevert(UniAlignmentVaultFactory.InvalidAddress.selector);
        new UniAlignmentVaultFactory(
            IMiyaRegistry(address(0)), IPoolManager(POOL_MANAGER), address(router), INFER_ADDR, IMD_ADDR, key
        );
        vm.expectRevert(UniAlignmentVaultFactory.InvalidAddress.selector);
        new UniAlignmentVaultFactory(
            IMiyaRegistry(address(registry)), IPoolManager(POOL_MANAGER), address(0), INFER_ADDR, IMD_ADDR, key
        );
    }
}
