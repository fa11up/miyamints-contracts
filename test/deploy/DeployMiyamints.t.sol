// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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

/// @notice Runs script/DeployMiyamints.s.sol against an Ethereum mainnet fork (real CreateX, Uniswap v4
///         PoolManager, zRouter, CULT pool, imdUSD Treasury), then proves the deployed system end to end: an ERC721
///         drop + mint + split, an auction, a music ERC1155 collection + addEdition + mint (the app's exact calls),
///         a MiyaPool deposit, and the default vault converting real ETH into CULT/ETH v4 liquidity.
///         RPC: MAINNET_RPC_URL (default https://ethereum-rpc.publicnode.com); FORK_BLOCK pins a block.
///         Skipped (not failed) when the RPC is unreachable or SKIP_FORK_TESTS=true.
contract DeployMiyamintsForkTest is Test {
    address constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address constant CULT = 0x0000000000c5dc95539589fbD24BE07c6C14eCa4;

    DeployMiyamints.Deployment d;
    bool forked;

    address deployer = makeAddr("deployer");
    address safe = makeAddr("safe");
    address artist = makeAddr("artist");
    address buyer = makeAddr("buyer");

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
            return;
        }

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
        assertEq(d.alignmentToken, CULT);
        assertTrue(r.isVault(d.defaultVault));
        assertEq(UniAlignmentVault(payable(d.defaultVault)).protocolTreasury(), TREASURY);
        assertEq(d.gatingModule, address(0));
    }

    // ── ERC721 drop: create, mint, split, pool ──────────────────────────────

    function _drop() internal returns (ERC721DropInstance drop) {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0] = ERC721DropInstance.Phase(uint64(block.timestamp), 0, 0.01 ether, 0, bytes32(0));
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
        assertEq(inst, f.computeInstanceAddress(salt));
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
        assertEq(address(music), f.computeInstanceAddress(salt));
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

    // ── the default vault against the real CULT/ETH v4 pool via the real zRouter ──

    function test_fork_defaultVault_convertsIntoRealPool() public onFork {
        ERC721DropInstance drop = _drop();
        vm.prank(buyer);
        drop.mint{ value: 1 ether }(0, 100, new bytes32[](0));
        drop.withdraw();

        UniAlignmentVault v = UniAlignmentVault(payable(d.defaultVault));
        assertEq(v.totalPendingETH(), 0.2 ether);
        vm.prank(makeAddr("keeper"));
        uint256 lpValue = v.convertAndAddLiquidity(1);
        assertGt(lpValue, 0);
        assertEq(v.totalPendingETH(), 0);
        assertGt(v.benefactorShares(address(drop)), 0, "drop holds vault shares");
    }
}
