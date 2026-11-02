// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MiyaPool } from "../../src/pools/MiyaPool.sol";
import { MiyaPoolFactory } from "../../src/pools/MiyaPoolFactory.sol";
import { Mock721, Mock1155 } from "../pools/MiyaPool.t.sol";

contract MiyaPoolHandler is Test {
    uint256 constant UNIT = 1e18;

    Mock721 public nft;
    Mock1155 public editions;
    MiyaPool public targeted;
    MiyaPool public random;
    MiyaPool public pool1155;

    address[] public actors;
    uint256 public nextId = 1;
    uint256[] public openCommits;

    constructor(MiyaPoolFactory factory) {
        nft = new Mock721();
        editions = new Mock1155();
        targeted = MiyaPool(factory.createPool(address(nft), MiyaPool.RedeemMode.TARGETED));
        random = MiyaPool(factory.createPool(address(nft), MiyaPool.RedeemMode.RANDOM));
        pool1155 = MiyaPool(factory.createPool(address(editions), MiyaPool.RedeemMode.TARGETED));
        for (uint256 i; i < 3; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(a);
            vm.startPrank(a);
            nft.setApprovalForAll(address(targeted), true);
            nft.setApprovalForAll(address(random), true);
            editions.setApprovalForAll(address(pool1155), true);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _one(uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = v;
    }

    function deposit721(uint256 actorSeed, bool intoRandom) external {
        address a = _actor(actorSeed);
        uint256 id = nextId++;
        nft.mint(a, id);
        vm.prank(a);
        (intoRandom ? random : targeted).deposit(_one(id), new uint256[](0), a);
    }

    function redeemTargeted(uint256 actorSeed, uint256 pick) external {
        uint256 n = targeted.heldIdsCount();
        address a = _actor(actorSeed);
        if (n == 0 || targeted.balanceOf(a) < UNIT) return;
        uint256 id = targeted.heldIds(pick % n, 1)[0];
        vm.prank(a);
        targeted.redeem(_one(id), new uint256[](0), a);
    }

    function commitRandom(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 free = random.heldUnits() - random.pendingUnits();
        uint256 affordable = random.balanceOf(a) / UNIT;
        if (free < affordable) affordable = free;
        if (affordable == 0) return;
        amount = bound(amount, 1, affordable);
        vm.prank(a);
        openCommits.push(random.commitRedeem(amount, a));
    }

    function revealRandom(uint256 pick, uint256 blocks) external {
        if (openCommits.length == 0) return;
        uint256 i = pick % openCommits.length;
        uint256 id = openCommits[i];
        (, uint64 target,,) = random.commits(id);
        vm.roll(block.number + bound(blocks, 0, 300));
        if (block.number <= target) vm.roll(target + 1);
        if (block.number - target <= 256) vm.setBlockhash(target, keccak256(abi.encode(pick, target)));
        random.revealRedeem(id);
        (,, uint32 amountLeft,) = random.commits(id);
        if (amountLeft == 0) {
            openCommits[i] = openCommits[openCommits.length - 1];
            openCommits.pop();
        }
    }

    function deposit1155(uint256 actorSeed, uint256 id, uint256 amount) external {
        address a = _actor(actorSeed);
        id = bound(id, 1, 5);
        amount = bound(amount, 1, 10);
        editions.mint(a, id, amount);
        vm.prank(a);
        pool1155.deposit(_one(id), _one(amount), a);
    }

    function redeem1155(uint256 actorSeed, uint256 pick, uint256 amount) external {
        uint256 n = pool1155.heldIdsCount();
        address a = _actor(actorSeed);
        if (n == 0) return;
        uint256 id = pool1155.heldIds(pick % n, 1)[0];
        uint256 max = pool1155.unitsOf(id);
        uint256 affordable = pool1155.balanceOf(a) / UNIT;
        if (affordable < max) max = affordable;
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        pool1155.redeem(_one(id), _one(amount), a);
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 which, uint256 amount) external {
        MiyaPool p = which % 3 == 0 ? targeted : which % 3 == 1 ? random : pool1155;
        address from = _actor(fromSeed);
        amount = bound(amount, 0, p.balanceOf(from));
        vm.prank(from);
        p.transfer(_actor(toSeed), amount);
    }
}

contract MiyaPoolInvariantTest is Test {
    uint256 constant UNIT = 1e18;
    MiyaPoolHandler handler;

    function setUp() public {
        handler = new MiyaPoolHandler(new MiyaPoolFactory());
        targetContract(address(handler));
    }

    function _check(MiyaPool p) internal view {
        assertEq(p.totalSupply() + UNIT * p.pendingUnits(), UNIT * p.heldUnits(), "supply != backing");
        assertLe(p.pendingUnits(), p.heldUnits(), "pending exceeds held");
    }

    function invariant_tokensExactlyBacked() public view {
        _check(handler.targeted());
        _check(handler.random());
        _check(handler.pool1155());
    }

    function invariant_trackedEqualsCustody() public view {
        assertEq(handler.nft().balanceOf(address(handler.targeted())), handler.targeted().heldUnits());
        assertEq(handler.nft().balanceOf(address(handler.random())), handler.random().heldUnits());
    }
}
