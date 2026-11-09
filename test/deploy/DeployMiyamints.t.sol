// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployMiyamints } from "../../script/DeployMiyamints.s.sol";
import { MiyaRegistry } from "../../src/registry/MiyaRegistry.sol";
import { UniAlignmentVault } from "../../src/vaults/uni/UniAlignmentVault.sol";
import { UniAlignmentVaultFactory } from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import { SwapCall, IzRouter } from "../../src/vaults/uni/IVaultConfig.sol";
import { ERC721DropFactory } from "../../src/factories/erc721drop/ERC721DropFactory.sol";
import { ERC721DropInstance } from "../../src/factories/erc721drop/ERC721DropInstance.sol";
import { ERC721AuctionFactory } from "../../src/factories/erc721/ERC721AuctionFactory.sol";
import { ERC721AuctionInstance } from "../../src/factories/erc721/ERC721AuctionInstance.sol";
import { ERC1155Factory } from "../../src/factories/erc1155/ERC1155Factory.sol";
import { ERC1155Instance } from "../../src/factories/erc1155/ERC1155Instance.sol";
import { TokenPrice } from "../../src/factories/interfaces/TokenPrice.sol";
import { IAlignmentVault } from "../../src/interfaces/IAlignmentVault.sol";
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

/// @notice Runs script/DeployMiyamints.s.sol against an Ethereum mainnet fork (real CreateX, Uniswap v4
///         PoolManager, zRouter, the INFER/IMD pool, imdUSD Treasury), then proves the deployed system end to end: an ERC721
///         drop + mint + split, an auction, a music ERC1155 collection + addEdition + mint (the app's exact calls),
///         a MiyaPool deposit, and the default vault converting real ETH into INFER/IMD v4 liquidity (keeper only).
///         RPC: MAINNET_RPC_URL (default https://ethereum-rpc.publicnode.com); FORK_BLOCK pins a block.
///         Skipped (not failed) when the RPC is unreachable or SKIP_FORK_TESTS=true.
contract DeployMiyamintsForkTest is Test {
    function _ethPrice(uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(address(0), price);
    }

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

        // The deploy needs the real INFER/IMD alignment pool (script/config/1.json `alignmentPool`); it is live on mainnet.
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
        phases[0] = ERC721DropInstance.Phase(uint64(block.timestamp), 0, 0, bytes32(0), 0, _ethPrice(0.01 ether));
        ERC721DropInstance.InitParams memory p;
        p.name = "fork drop";
        p.symbol = "FORK";
        p.maxSupply = 100;
        p.unrevealedURI = "ar://unrevealed.json";
        p.acceptedTokens = new address[](1); // ETH
        p.phases = phases;
        vm.prank(artist);
        drop = ERC721DropInstance(payable(ERC721DropFactory(d.dropFactory).createDrop(p, d.defaultVault, 2000)));
    }

    function test_fork_erc721Drop_mintSplitAndPool() public onFork {
        ERC721DropInstance drop = _drop();
        assertEq(MiyaRegistry(d.registry).factoryOf(address(drop)), d.dropFactory);

        vm.prank(buyer);
        drop.mint{ value: 0.1 ether }(0, 10, new bytes32[](0), address(0), 0);
        assertEq(drop.ownerOf(1), buyer);

        uint256 t0 = TREASURY.balance;
        uint256 a0 = artist.balance;
        drop.distribute(address(0));
        vm.prank(artist);
        drop.withdraw(address(0));
        assertEq(TREASURY.balance - t0, 0.001 ether, "1% to imdUSD treasury");
        assertEq(IAlignmentVault(payable(d.defaultVault)).pendingOf(address(drop), address(0)), 0.02 ether, "20% to vault");
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

    /// @dev The create call is encoded by AuctionCallBuilder: encoding the 11-field params inline here overflows the
    ///      via-IR stack in this large test contract.
    function _auction() internal returns (ERC721AuctionInstance a) {
        bytes32 salt = bytes32(abi.encodePacked(d.auctionFactory, bytes1(0x00), bytes11(uint88(1))));
        bytes memory data = new AuctionCallBuilder().createCall(salt, artist, d.defaultVault);
        vm.prank(artist);
        (bool ok, bytes memory ret) = d.auctionFactory.call(data);
        assertTrue(ok, "createInstance");
        address inst = abi.decode(ret, (address));
        assertEq(inst, ERC721AuctionFactory(d.auctionFactory).computeInstanceAddress(salt, artist));
        a = ERC721AuctionInstance(payable(inst));
    }

    function test_fork_auction_createBidSettle() public onFork {
        ERC721AuctionInstance a = _auction();

        vm.prank(artist);
        a.queuePiece{ value: 0.01 ether }("ar://piece", 0.01 ether);
        uint24 tokenId = a.nextTokenId() - 1;
        vm.prank(buyer);
        a.createBid{ value: 0.05 ether }(tokenId, 0.05 ether, "gm");
        vm.warp(a.getAuction(tokenId).endTime);
        uint256 t0 = TREASURY.balance;
        a.settleAuction(tokenId);
        assertEq(a.ownerOf(tokenId), buyer);
        assertGt(TREASURY.balance, t0);
    }

    // ── music: exactly the app's calls (app/src/music/drop.ts, pages/DropMusic) ──

    function _music() internal returns (ERC1155Instance music) {
        ERC1155Factory f = ERC1155Factory(d.erc1155Factory);
        // app makeSalt(): factory ‖ 0x00 ‖ 11 random bytes
        bytes32 salt = bytes32(abi.encodePacked(address(f), bytes1(0x00), bytes11(keccak256("random"))));
        ERC1155Factory.CreateParams memory p;
        p.name = "fork tape";
        p.metadataURI = "ar://collection.json";
        p.creator = artist;
        p.vault = d.defaultVault; // VITE_MUSIC_VAULT_1
        p.alignmentBps = 1000;
        p.freeMint = FreeMintParams({ allocation: 0, scope: GatingScope.BOTH });
        p.acceptedTokens = new address[](1);
        vm.prank(artist);
        music = ERC1155Instance(payable(f.createInstance(salt, p)));
        assertEq(address(music), f.computeInstanceAddress(salt, artist));
        assertEq(MiyaRegistry(d.registry).factoryOf(address(music)), d.erc1155Factory);
    }

    function test_fork_musicDrop_createAddEditionMint() public onFork {
        ERC1155Instance music = _music();

        // editionArgs(): (title, priceWei, supply, metadataURI, model, 0, 0); open edition = UNLIMITED, supply 0
        vm.startPrank(artist);
        music.addEdition("track 1", _ethPrice(0.001 ether), 0, "ar://track1.json", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        // LIMITED_DYNAMIC proves the DynamicPricingModule is wired into new instances
        music.addEdition(
            "track 2", _ethPrice(0.001 ether), 50, "ar://track2.json", ERC1155Instance.PricingModel.LIMITED_DYNAMIC, 100, 0
        );
        vm.stopPrank();

        vm.startPrank(buyer);
        music.mint{ value: 0.003 ether }(1, 3, bytes32(0), "", address(0), 0);
        uint256 p2 = music.getCurrentPrice(2, address(0));
        music.mint{ value: p2 }(2, 1, bytes32(0), "", address(0), 0);
        vm.stopPrank();
        assertEq(music.balanceOf(buyer, 1), 3);
        assertEq(music.balanceOf(buyer, 2), 1);
        assertGt(music.getCurrentPrice(2, address(0)), p2, "dynamic price rose");

        // 1155 collections can be pooled too
        address pool = MiyaPoolFactory(d.poolFactory).createPool(address(music), MiyaPool.RedeemMode.TARGETED);
        assertTrue(pool != address(0));
    }

    // ── the default vault (v2) against the real INFER/IMD pool via the real zRouter ──
    // Full vault v2 coverage against the real pools (every route, mixed batches, claims): test/fork/UniAlignmentVaultFork.t.sol.

    address constant Z_ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    IPoolManager constant MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    /// @dev The script sets the swap targets and the ETH-claim pool from script/config/1.json.
    function _checkSwapConfig() internal view {
        UniAlignmentVaultFactory vf = UniAlignmentVaultFactory(d.vaultFactory);
        assertTrue(vf.isSwapTarget(ALLOWANCE_HOLDER), "0x AllowanceHolder");
        assertTrue(vf.isSwapTarget(Z_ROUTER), "zRouter");
        (uint24 fee, int24 ts) = vf.ethPool();
        assertEq(fee, 10000);
        assertEq(ts, 200);
    }

    function test_fork_paymentTokensAndSwapTargets() public onFork {
        MiyaRegistry r = MiyaRegistry(d.registry);
        UniAlignmentVaultFactory vf = UniAlignmentVaultFactory(d.vaultFactory);
        address[6] memory toks = [
            IMD,
            INFER,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25,
            0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf,
            0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
        ];
        for (uint256 i; i < 6; ++i) assertTrue(r.isPaymentToken(toks[i]), "allowed");
        _checkSwapConfig();
        // Per-token minimums from config, about 0.001 ETH each.
        uint256[6] memory mins = [uint256(1e18), 3500e18, 2e6, 3e18, 3000, 3000];
        for (uint256 i; i < 6; ++i) assertEq(vf.minContribution(toks[i]), mins[i], "min contribution");
        assertEq(vf.owner(), safe);
    }

    /// @dev Everything pending in ETH; the leg is zRouter calldata on the IMD/ETH pool selling all of msg.value.
    function _ethParams(UniAlignmentVault v) internal view returns (UniAlignmentVault.ConvertParams memory p) {
        p.tokens = v.openBatchTokens();
        p.amounts = new uint256[](p.tokens.length);
        p.amounts[0] = v.pendingByToken(p.tokens[0]);
        p.swaps = new SwapCall[](p.tokens.length);
        p.ethLeg = SwapCall(
            Z_ROUTER,
            IMD,
            abi.encodeCall(IzRouter.swapV4, (address(v), false, 10000, 200, address(0), IMD, 0, 0, block.timestamp)),
            1
        );
        p.minSplitOut = 1;
        p.deadline = block.timestamp;
    }

    function test_fork_defaultVault_convertsIntoRealPool() public onFork {
        _checkSwapConfig();
        ERC721DropInstance drop = _drop();
        vm.prank(buyer);
        drop.mint{ value: 1 ether }(0, 100, new bytes32[](0), address(0), 0);
        drop.distribute(address(0));

        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        assertEq(v.pendingByToken(address(0)), 0.2 ether);
        UniAlignmentVault.ConvertParams memory p = _ethParams(v);
        vm.prank(buyer);
        vm.expectRevert(UniAlignmentVault.NotKeeper.selector);
        v.convertAndAddLiquidity(p);

        vm.prank(keeper);
        uint256 shares = v.convertAndAddLiquidity(p);
        assertGt(shares, 0);
        assertEq(v.pendingByToken(address(0)), 0);
        assertGt(v.benefactorShares(address(drop)), 0, "drop holds vault shares");
    }

    function test_fork_oneWeiInRouterDoesNotBlockConversion() public onFork {
        _checkSwapConfig();
        vm.deal(address(this), 1 ether);
        (bool ok,) = Z_ROUTER.call{ value: 1 }("");
        assertTrue(ok, "router accepts ETH");
        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (ok,) = address(v).call{ value: 1 ether }("");
        assertTrue(ok);
        UniAlignmentVault.ConvertParams memory p = _ethParams(v);
        vm.prank(keeper);
        v.convertAndAddLiquidity(p);
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

/// @dev Encodes the auction factory's createInstance call for DeployMiyamintsForkTest (see its _auction).
contract AuctionCallBuilder {
    function createCall(bytes32 salt, address creator, address vault) external pure returns (bytes memory) {
        ERC721AuctionFactory.CreateParams memory p;
        p.name = "fork 1/1s";
        p.metadataURI = "ar://meta";
        p.creator = creator;
        p.vault = vault;
        p.alignmentBps = 1000;
        p.symbol = "ONE";
        p.lines = 1;
        p.baseDuration = 1 hours;
        p.timeBuffer = 5 minutes;
        p.bidIncrement = 0.001 ether;
        p.currency = address(0);
        return abi.encodeCall(ERC721AuctionFactory.createInstance, (salt, p));
    }
}
