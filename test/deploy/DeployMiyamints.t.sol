// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { UniswapVaultPriceValidator } from "../../src/peripherals/UniswapVaultPriceValidator.sol";
import { Test } from "forge-std/Test.sol";
import { DeployMiyamints } from "../../script/DeployMiyamints.s.sol";
import { MiyaRegistry } from "../../src/registry/MiyaRegistry.sol";
import { UniAlignmentVault } from "../../src/vaults/uni/UniAlignmentVault.sol";
import { UniAlignmentVaultFactory } from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import { ERC721DropFactory } from "../../src/factories/erc721drop/ERC721DropFactory.sol";
import { ERC721DropInstance } from "../../src/factories/erc721drop/ERC721DropInstance.sol";
import { ERC721AuctionFactory } from "../../src/factories/erc721/ERC721AuctionFactory.sol";
import { ERC721AuctionInstance } from "../../src/factories/erc721/ERC721AuctionInstance.sol";
import { ERC1155Factory } from "../../src/factories/erc1155/ERC1155Factory.sol";
import { ERC1155Instance } from "../../src/factories/erc1155/ERC1155Instance.sol";
import { MiyaPoolFactory } from "../../src/pools/MiyaPoolFactory.sol";
import { MiyaPool } from "../../src/pools/MiyaPool.sol";
import { FreeMintParams } from "../../src/interfaces/IFactoryTypes.sol";
import { GatingScope } from "../../src/gating/IGatingModule.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev Seeds the hookless ETH/INFER pool the launch needs, as the real launch will before deploying.
contract InferPoolSeeder is IUnlockCallback {
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address immutable infer;

    constructor(address infer_) {
        infer = infer_;
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(infer), 10000, 200, IHooks(address(0)));
    }

    /// @dev About 2.7M INFER per ETH, close to the 0x price on 2026-11-04.
    function seed() external payable {
        MANAGER.initialize(_key(), uint160(1643) << 96);
        MANAGER.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        int24 lower = TickMath.minUsableTick(200);
        int24 upper = TickMath.maxUsableTick(200);
        (BalanceDelta delta,) =
            MANAGER.modifyLiquidity(_key(), IPoolManager.ModifyLiquidityParams(lower, upper, 8_000e18, 0), "");
        MANAGER.settle{ value: uint256(int256(-delta.amount0())) }();
        MANAGER.sync(Currency.wrap(infer));
        (bool ok,) = infer.call(
            abi.encodeWithSignature("transfer(address,uint256)", address(MANAGER), uint256(int256(-delta.amount1())))
        );
        require(ok, "infer transfer");
        MANAGER.settle();
        return "";
    }

    receive() external payable { }
}

/// @notice Runs script/DeployMiyamints.s.sol against an Ethereum mainnet fork (real CreateX, Uniswap v4
///         PoolManager, zRouter, a seeded ETH/INFER pool, imdUSD Treasury), then proves the deployed system end to end: an ERC721
///         drop + mint + split, an auction, a music ERC1155 collection + addEdition + mint (the app's exact calls),
///         a MiyaPool deposit, and the default vault converting real ETH into ETH/INFER v4 liquidity (keeper only).
///         RPC: MAINNET_RPC_URL (default https://ethereum-rpc.publicnode.com); FORK_BLOCK pins a block.
///         Skipped (not failed) when the RPC is unreachable or SKIP_FORK_TESTS=true.
contract DeployMiyamintsForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address constant INFER = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;

    DeployMiyamints.Deployment d;
    bool forked;

    address deployer = makeAddr("deployer");
    address safe = makeAddr("safe");
    address artist = makeAddr("artist");
    address buyer = makeAddr("buyer");
    address keeper = makeAddr("keeper");

    function setUp() public {
        if (vm.envOr("SKIP_FORK_TESTS", false)) return;
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blockNo = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNo == 0) {
            try vm.createSelectFork(rpc) { forked = true; } catch { }
        } else {
            try vm.createSelectFork(rpc, blockNo) { forked = true; } catch { }
        }
        if (!forked || block.chainid != 1) {
            forked = false;
            // Without this, a machine with no RPC skips every test here and still reports green.
            require(!vm.envOr("REQUIRE_FORK_TESTS", false), "fork tests required but no mainnet fork");
            return;
        }

        // Once the real pool is seeded these tests run against it.
        PoolKey memory poolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(INFER), 10000, 200, IHooks(address(0)));
        (uint160 existing,,,) = StateLibrary.getSlot0(MANAGER, poolKey.toId());
        if (existing == 0) {
            InferPoolSeeder seeder = new InferPoolSeeder(INFER);
            deal(INFER, address(seeder), 100_000_000e18);
            vm.deal(address(this), 100 ether);
            seeder.seed{ value: 100 ether }();
        }
        vm.etch(safe, hex"00"); // the script requires OWNER to have code

        vm.setEnv("KEEPER", vm.toString(keeper));
        vm.deal(deployer, 10 ether);
        DeployMiyamints script = new DeployMiyamints();
        d = script.runAs(deployer, safe);

        vm.deal(artist, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    // ── wiring ──────────────────────────────────────────────────────────────

    function test_fork_wiringAndOwnership() public onFork {
        MiyaRegistry r = MiyaRegistry(d.registry);
        assertEq(r.owner(), safe, "registry handed to the Safe");
        assertEq(r.treasury(), TREASURY);
        assertEq(r.protocolFeeBps(), 100);
        assertEq(r.minAlignmentBps(), 1000);
        assertEq(UniAlignmentVaultFactory(d.vaultFactory).owner(), safe);
        assertEq(ERC1155Factory(d.erc1155Factory).owner(), safe);
        assertEq(ERC721AuctionFactory(d.auctionFactory).owner(), safe);
        assertEq(d.alignmentToken, INFER);
        assertEq(r.conversionKeeper(), keeper);
        assertTrue(r.isVault(d.defaultVault));
        assertEq(UniAlignmentVault(payable(d.defaultVault)).protocolTreasury(), TREASURY);
        assertEq(d.gatingModule, address(0));
    }

    // ── ERC721 drop: create, mint, split, pool ──────────────────────────────

    function _drop() internal returns (ERC721DropInstance drop) {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0] = ERC721DropInstance.Phase(uint64(block.timestamp), 0, 0.01 ether, 0, bytes32(0), 0);
        ERC721DropInstance.InitParams memory p;
        p.name = "fork drop";
        p.symbol = "FORK";
        p.maxSupply = 100;
        p.unrevealedURI = "ar://unrevealed.json";
        p.phases = phases;
        vm.prank(artist);
        drop = ERC721DropInstance(payable(ERC721DropFactory(d.dropFactory).createDrop(p, d.defaultVault, 2000)));
    }

    function test_fork_erc721Drop_mintSplitAndPool() public onFork {
        ERC721DropInstance drop = _drop();
        assertEq(MiyaRegistry(d.registry).factoryOf(address(drop)), d.dropFactory);

        vm.prank(buyer);
        drop.mint{ value: 0.1 ether }(0, 10, new bytes32[](0));
        assertEq(drop.ownerOf(1), buyer);

        uint256 t0 = TREASURY.balance;
        uint256 a0 = artist.balance;
        drop.withdraw();
        assertEq(TREASURY.balance - t0, 0.001 ether, "1% to imdUSD treasury");
        assertEq(UniAlignmentVault(payable(d.defaultVault)).pendingETH(address(drop)), 0.02 ether, "20% to vault");
        assertEq(artist.balance - a0, 0.079 ether, "artist remainder");

        // MiyaPool for the drop: deposit one NFT, get 1e18 pool tokens.
        MiyaPool pool =
            MiyaPool(MiyaPoolFactory(d.poolFactory).createPool(address(drop), MiyaPool.RedeemMode.TARGETED));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.startPrank(buyer);
        drop.setApprovalForAll(address(pool), true);
        pool.deposit(ids, new uint256[](0), buyer);
        vm.stopPrank();
        assertEq(pool.balanceOf(buyer), 1e18);
        assertEq(drop.ownerOf(1), address(pool));
    }

    // ── auction ─────────────────────────────────────────────────────────────

    function test_fork_auction_createBidSettle() public onFork {
        ERC721AuctionFactory f = ERC721AuctionFactory(d.auctionFactory);
        bytes32 salt = bytes32(abi.encodePacked(address(f), bytes1(0x00), bytes11(uint88(1))));
        ERC721AuctionFactory.CreateParams memory p = ERC721AuctionFactory.CreateParams({
            name: "fork 1/1s",
            metadataURI: "ar://meta",
            creator: artist,
            vault: d.defaultVault,
            alignmentBps: 1000,
            symbol: "ONE",
            lines: 1,
            baseDuration: 1 hours,
            timeBuffer: 5 minutes,
            bidIncrement: 0.001 ether
        });
        vm.prank(artist);
        address inst = f.createInstance(salt, p);
        assertEq(inst, f.computeInstanceAddress(salt, artist));
        ERC721AuctionInstance a = ERC721AuctionInstance(payable(inst));

        vm.prank(artist);
        a.queuePiece{ value: 0.01 ether }("ar://piece");
        uint24 tokenId = a.nextTokenId() - 1;
        vm.prank(buyer);
        a.createBid{ value: 0.05 ether }(tokenId, "gm");
        vm.warp(a.getAuction(tokenId).endTime);
        uint256 t0 = TREASURY.balance;
        a.settleAuction(tokenId);
        assertEq(a.ownerOf(tokenId), buyer);
        assertGt(TREASURY.balance, t0);
    }

    // ── music: exactly the app's calls (app/src/music/drop.ts, pages/DropMusic) ──

    function test_fork_musicDrop_createAddEditionMint() public onFork {
        ERC1155Factory f = ERC1155Factory(d.erc1155Factory);
        // app makeSalt(): factory ‖ 0x00 ‖ 11 random bytes
        bytes32 salt = bytes32(abi.encodePacked(address(f), bytes1(0x00), bytes11(keccak256("random"))));
        ERC1155Factory.CreateParams memory p = ERC1155Factory.CreateParams({
            name: "fork tape",
            metadataURI: "ar://collection.json",
            creator: artist,
            vault: d.defaultVault, // VITE_MUSIC_VAULT_1
            alignmentBps: 1000,
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({ allocation: 0, scope: GatingScope.BOTH })
        });
        vm.prank(artist);
        ERC1155Instance music = ERC1155Instance(payable(f.createInstance(salt, p)));
        assertEq(address(music), f.computeInstanceAddress(salt, artist));
        assertEq(MiyaRegistry(d.registry).factoryOf(address(music)), d.erc1155Factory);

        // editionArgs(): (title, priceWei, supply, metadataURI, model, 0, 0); open edition = UNLIMITED, supply 0
        vm.startPrank(artist);
        music.addEdition("track 1", 0.001 ether, 0, "ar://track1.json", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        // LIMITED_DYNAMIC proves the DynamicPricingModule is wired into new instances
        music.addEdition(
            "track 2", 0.001 ether, 50, "ar://track2.json", ERC1155Instance.PricingModel.LIMITED_DYNAMIC, 100, 0
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        music.mint{ value: 0.003 ether }(1, 3, bytes32(0), "", 0);
        uint256 p2 = music.getCurrentPrice(2);
        music.mint{ value: p2 }(2, 1, bytes32(0), "", 0);
        vm.stopPrank();
        assertEq(music.balanceOf(buyer, 1), 3);
        assertEq(music.balanceOf(buyer, 2), 1);
        assertGt(music.getCurrentPrice(2), p2, "dynamic price rose");

        // 1155 collections can be pooled too
        address pool = MiyaPoolFactory(d.poolFactory).createPool(address(music), MiyaPool.RedeemMode.TARGETED);
        assertTrue(pool != address(0));
    }

    // ── the default vault against the seeded ETH/INFER v4 pool via the real zRouter ──

    function test_fork_defaultVault_convertsIntoRealPool() public onFork {
        ERC721DropInstance drop = _drop();
        vm.prank(buyer);
        drop.mint{ value: 1 ether }(0, 100, new bytes32[](0));
        drop.withdraw();

        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        assertEq(v.totalPendingETH(), 0.2 ether);
        vm.prank(buyer);
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        v.convertAndAddLiquidity(1, 1);

        vm.prank(keeper);
        uint256 lpValue = v.convertAndAddLiquidity(1, 1);
        assertGt(lpValue, 0);
        assertEq(v.totalPendingETH(), 0);
        assertGt(v.benefactorShares(address(drop)), 0, "drop holds vault shares");
    }

    // ── audit round 1: conversions after the first ───────────────────────────

    address constant Z_ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @dev Contribute and convert as the keeper.
    function _contributeAndConvert(uint256 amount) internal returns (UniAlignmentVault v) {
        v = UniAlignmentVault(payable(d.defaultVault));
        vm.deal(buyer, amount);
        vm.prank(buyer);
        (bool ok,) = address(v).call{ value: amount }("");
        assertTrue(ok);
        vm.prank(keeper);
        v.convertAndAddLiquidity(1, 1);
    }

    /// @dev ETH in the vault that no share, fee balance or pending batch accounts for.
    function _unaccountedEth(UniAlignmentVault v) internal view returns (uint256) {
        uint256 owed = v.totalPendingETH() + v.accumulatedFees() - v.totalFeesClaimed() + v.accumulatedProtocolFees();
        return address(v).balance - owed;
    }

    /// @dev Value of the tokens the vault holds beyond pending fee tokens, in ETH at the pool's current price.
    function _unusedTokenValue(UniAlignmentVault v) internal view returns (uint256) {
        uint256 tokens = ERC20Balance(INFER).balanceOf(address(v)) - v.pendingFeeTokens();
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(INFER), 10000, 200, IHooks(address(0)));
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(MANAGER, key.toId());
        return FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(tokens, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// Leftovers stay a small share of every batch, from the first conversion on: small batches, and one far bigger
    /// than the pool, whose swap has to allow for moving the price a long way.
    function _assertLeftoversStaySmall(uint256 batch, uint256 rounds) internal {
        UniAlignmentVault v;
        for (uint256 i; i < rounds; ++i) {
            v = _contributeAndConvert(batch);
            assertLt(_unaccountedEth(v), batch / 25, "ETH left over");
            assertLt(_unusedTokenValue(v), batch / 25, "tokens left over");
        }
    }

    function test_fork_leftoversStaySmall_smallBatches() public onFork {
        _assertLeftoversStaySmall(0.1 ether, 40);
    }

    function test_fork_leftoversStaySmall_largeBatches() public onFork {
        _assertLeftoversStaySmall(10 ether, 12);
    }

    /// A contributor after a huge batch gets about the shares their own ETH buys, not a windfall from its leftovers.
    function test_fork_noWindfallAfterALargeBatch() public onFork {
        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        vm.deal(buyer, 11 ether);
        vm.prank(buyer);
        (bool ok,) = address(v).call{ value: 10 ether }("");
        assertTrue(ok);
        vm.prank(keeper);
        v.convertAndAddLiquidity(1, 1);

        address next = makeAddr("next");
        vm.deal(next, 1 ether);
        vm.prank(next);
        (ok,) = address(v).call{ value: 1 ether }("");
        assertTrue(ok);
        vm.prank(keeper);
        v.convertAndAddLiquidity(1, 1);
        // Their 1 ETH is about 1/15 of the pool's ETH side after A's batch; 2x shares would be well past this.
        assertLt(v.benefactorShares(next) * 100 / v.totalShares(), 12);
    }

    function test_fork_proportionIsAboutHalfForFullRange() public onFork {
        UniAlignmentVault v = _contributeAndConvert(1 ether);
        uint256 p = UniswapVaultPriceValidator(address(v.priceValidator())).calculateSwapProportion(
            INFER, v.lastTickLower(), v.lastTickUpper(), address(MANAGER), keccak256(abi.encode(address(0), INFER, uint24(10000), int24(200), address(0)))
        );
        emit log_named_uint("proportion", p);
        assertApproxEqRel(p, 5e17, 1e16);
    }

    /// Fee tokens and claims through the real router: trades both ways earn the position both fees.
    function test_fork_feeTokensConvertAndClaimsPay() public onFork {
        UniAlignmentVault v = _contributeAndConvert(5 ether);
        address trader = makeAddr("trader");
        vm.deal(trader, 20 ether);
        vm.startPrank(trader);
        (, uint256 bought) = IzRouterSwap(Z_ROUTER).swapV4{ value: 5 ether }(
            trader, false, 10000, 200, address(0), INFER, 5 ether, 1, type(uint256).max
        );
        ERC20Approve(INFER).approve(Z_ROUTER, bought);
        IzRouterSwap(Z_ROUTER).swapV4(trader, false, 10000, 200, INFER, address(0), bought, 1, type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        v.convertFeeTokens(1);
        assertEq(v.pendingFeeTokens(), 0);
        assertGt(v.getUnclaimedFees(buyer), 0);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        uint256 paid = v.claimFees();
        assertEq(buyer.balance - before, paid);
        assertGt(paid, 0.01 ether, "earned on both sides of 5 ETH traded");
    }

    function test_fork_oneWeiInRouterDoesNotBlockConversion() public onFork {
        vm.deal(address(this), 1 ether);
        (bool ok,) = Z_ROUTER.call{ value: 1 }("");
        assertTrue(ok, "router accepts ETH");
        _contributeAndConvert(1 ether);
    }
}

interface ERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

interface IzRouterSwap {
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

interface ERC20Approve {
    function approve(address, uint256) external returns (bool);
}
