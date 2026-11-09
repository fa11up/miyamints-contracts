// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { CREATEX } from "../../src/shared/CreateXConstants.sol";
import { CREATEX_BYTECODE } from "createx-forge/script/CreateX.d.sol";
import { DeployMiyamints } from "../../script/DeployMiyamints.s.sol";
import { MiyaRegistry } from "../../src/registry/MiyaRegistry.sol";
import { UniAlignmentVault } from "../../src/vaults/uni/UniAlignmentVault.sol";
import { UniAlignmentVaultFactory } from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import { ERC1155Factory } from "../../src/factories/erc1155/ERC1155Factory.sol";
import { ERC721AuctionFactory } from "../../src/factories/erc721/ERC721AuctionFactory.sol";
import { MockExtsloadPoolManager } from "../mocks/MockExtsloadPoolManager.sol";

/// @notice Runs script/DeployMiyamints.s.sol with no RPC: chain 31337 and script/config/31337.json, whose addresses this
///         test fills with mocks (tokens via deployCodeTo, a PoolManager that answers extsload, code at the router and
///         AllowanceHolder stand-ins, CreateX etched). Checks the wiring the script does before the handoff: payment
///         allowlist, swap targets, the ETH-claim pool, per-token minimums, the keeper, and the ownership handoff.
///         The mainnet-fork version (real addresses, real pools) is test/deploy/DeployMiyamints.t.sol.
contract DeployMiyamintsOfflineTest is Test {
    address constant WETH = 0x1000000000000000000000000000000000000001;
    address constant POOL_MANAGER = 0x1000000000000000000000000000000000000002;
    address constant ZROUTER = 0x1000000000000000000000000000000000000003;
    address constant ALLOWANCE_HOLDER = 0x1000000000000000000000000000000000000004;
    address constant INFER = 0x1000000000000000000000000000000000000005;
    address constant IMD = 0x1000000000000000000000000000000000000006;
    address constant USDC = 0x1000000000000000000000000000000000000007;
    address constant TREASURY = 0x1000000000000000000000000000000000000008;

    address deployer = makeAddr("deployer");
    address safe = makeAddr("safe");
    // Same as the fork deploy test's keeper: KEEPER is process-wide, and both set it.
    address keeper = makeAddr("keeper");

    function setUp() public {
        assertEq(block.chainid, 31337);
        vm.etch(CREATEX, CREATEX_BYTECODE);
        deployCodeTo("VaultMocks.sol:MockToken", abi.encode("INFER", "INFER", uint8(18)), INFER);
        deployCodeTo("VaultMocks.sol:MockToken", abi.encode("IMD", "IMD", uint8(18)), IMD);
        deployCodeTo("VaultMocks.sol:MockToken", abi.encode("USDC", "USDC", uint8(6)), USDC);
        // A live pool everywhere: sqrtPriceX96 = 2^96 (price 1), liquidity 2^96.
        deployCodeTo("MockExtsloadPoolManager.sol:MockExtsloadPoolManager", abi.encode(bytes32(uint256(1 << 96))), POOL_MANAGER);
        vm.etch(WETH, hex"00");
        vm.etch(ZROUTER, hex"00");
        vm.etch(ALLOWANCE_HOLDER, hex"00");
        vm.setEnv("KEEPER", vm.toString(keeper));
    }

    function _deploy() internal returns (DeployMiyamints.Deployment memory) {
        return new DeployMiyamints().runAs(deployer, safe);
    }

    function test_offline_wiringAndHandoff() public {
        DeployMiyamints.Deployment memory d = _deploy();
        MiyaRegistry r = MiyaRegistry(d.registry);
        UniAlignmentVaultFactory vf = UniAlignmentVaultFactory(d.vaultFactory);

        // Ownership handed to the Safe, nothing left with the deployer.
        assertEq(r.owner(), safe, "registry");
        assertEq(vf.owner(), safe, "vault factory");
        assertEq(ERC1155Factory(d.erc1155Factory).owner(), safe, "1155 factory");
        assertEq(ERC721AuctionFactory(d.auctionFactory).owner(), safe, "auction factory");
        assertEq(Ownable(d.dynamicPricingModule).owner(), safe, "dynamic pricing");
        assertEq(UniAlignmentVault(payable(d.defaultVault)).owner(), d.vaultFactory, "vault owned by its factory");
        vm.prank(deployer);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vf.setSwapTarget(ALLOWANCE_HOLDER, false);

        // Registry: treasury, fees, keeper, payment allowlist.
        assertEq(r.treasury(), TREASURY);
        assertEq(r.conversionKeeper(), keeper);
        assertTrue(r.isPaymentToken(INFER));
        assertTrue(r.isPaymentToken(IMD));
        assertTrue(r.isPaymentToken(USDC));
        assertEq(r.paymentTokens().length, 3);
        assertTrue(r.isVaultFactoryRegistered(d.vaultFactory));
        assertTrue(r.isVault(d.defaultVault));

        // Vault factory: swap targets, ETH-claim pool, minimums, zRouter.
        assertTrue(vf.isSwapTarget(ALLOWANCE_HOLDER), "0x AllowanceHolder stand-in");
        assertTrue(vf.isSwapTarget(ZROUTER), "zRouter");
        assertFalse(vf.isSwapTarget(WETH));
        (uint24 fee, int24 ts) = vf.ethPool();
        assertEq(fee, 3000, "ethPool fee from config");
        assertEq(ts, 60, "ethPool tickSpacing from config");
        assertEq(vf.minContribution(IMD), 1e18);
        assertEq(vf.minContribution(INFER), 3500e18);
        assertEq(vf.minContribution(USDC), 2e6);
        assertEq(vf.zRouter(), ZROUTER);

        // The default vault reads that config and the alignment pool from config.
        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        assertEq(address(v.config()), d.vaultFactory);
        assertEq(address(v.registry()), d.registry);
        assertEq(v.infer(), INFER);
        assertEq(v.imd(), IMD);
        assertEq(v.zRouter(), ZROUTER);
        PoolKey memory k = v.alignmentPoolKey();
        assertEq(Currency.unwrap(k.currency0), INFER);
        assertEq(Currency.unwrap(k.currency1), IMD);
        assertEq(k.fee, 12500);
        assertEq(k.tickSpacing, 60);
        assertEq(v.protocolTreasury(), TREASURY);
    }

    function test_offline_refusesWithoutLivePools() public {
        MockExtsloadPoolManager(POOL_MANAGER).setAnswer(bytes32(0));
        DeployMiyamints s = new DeployMiyamints();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMiyamints.ConfigError.selector,
                "INFER/IMD alignment pool (alignmentPool) not initialized at fee 12500 / tickSpacing 60. ALLOW_MISSING_POOL=true to deploy anyway"
            )
        );
        s.runAs(deployer, safe);
    }

    function test_offline_refusesAPoolWithoutLiquidity() public {
        // Initialized (price bits set) but the liquidity read (low 128 bits) is 0.
        MockExtsloadPoolManager(POOL_MANAGER).setAnswer(bytes32(uint256(1) << 128));
        DeployMiyamints s = new DeployMiyamints();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMiyamints.ConfigError.selector, "INFER/IMD alignment pool (alignmentPool) has no liquidity in range"
            )
        );
        s.runAs(deployer, safe);
    }
}
