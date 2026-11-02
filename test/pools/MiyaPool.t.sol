// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "solady/tokens/ERC721.sol";
import { ERC1155 } from "solady/tokens/ERC1155.sol";
import { MiyaPool } from "../../src/pools/MiyaPool.sol";
import { MiyaPoolFactory } from "../../src/pools/MiyaPoolFactory.sol";

contract Mock721 is ERC721 {
    function name() public pure override returns (string memory) {
        return "miyamaker mini";
    }

    function symbol() public pure override returns (string memory) {
        return "MIYAMINI";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract Mock1155 is ERC1155 {
    function uri(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract NotAnNFT { }

contract MiyaPoolTest is Test {
    uint256 constant UNIT = 1e18;

    MiyaPoolFactory factory;
    Mock721 nft;
    Mock1155 editions;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        factory = new MiyaPoolFactory();
        nft = new Mock721();
        editions = new Mock1155();
        for (uint256 id = 1; id <= 10; ++id) nft.mint(alice, id);
        editions.mint(alice, 1, 5);
        editions.mint(alice, 2, 3);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _pool721(MiyaPool.RedeemMode mode) internal returns (MiyaPool pool) {
        pool = MiyaPool(factory.createPool(address(nft), mode));
        vm.prank(alice);
        nft.setApprovalForAll(address(pool), true);
    }

    function _pool1155() internal returns (MiyaPool pool) {
        pool = MiyaPool(factory.createPool(address(editions), MiyaPool.RedeemMode.TARGETED));
        vm.prank(alice);
        editions.setApprovalForAll(address(pool), true);
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _none() internal pure returns (uint256[] memory r) { }

    function _assertBacked(MiyaPool pool) internal view {
        assertEq(pool.totalSupply() + UNIT * pool.pendingUnits(), UNIT * pool.heldUnits(), "accounting");
    }

    // ── factory ──────────────────────────────────────────────────────────────

    function test_factory_createsAndPredicts() public {
        address predicted = factory.predictPool(address(nft), MiyaPool.Kind.ERC721, MiyaPool.RedeemMode.TARGETED);
        address pool = factory.createPool(address(nft), MiyaPool.RedeemMode.TARGETED);
        assertEq(pool, predicted);
        assertEq(factory.poolOf(address(nft), MiyaPool.RedeemMode.TARGETED), pool);
        assertEq(factory.allPoolsLength(), 1);
        assertEq(uint8(MiyaPool(pool).kind()), uint8(MiyaPool.Kind.ERC721));
        assertEq(MiyaPool(pool).collection(), address(nft));
    }

    function test_factory_onePoolPerCollectionAndMode() public {
        address a = factory.createPool(address(nft), MiyaPool.RedeemMode.TARGETED);
        address b = factory.createPool(address(nft), MiyaPool.RedeemMode.RANDOM);
        assertTrue(a != b);
        vm.expectRevert(abi.encodeWithSelector(MiyaPoolFactory.PoolExists.selector, a));
        factory.createPool(address(nft), MiyaPool.RedeemMode.TARGETED);
    }

    function test_factory_detects1155() public {
        address pool = factory.createPool(address(editions), MiyaPool.RedeemMode.TARGETED);
        assertEq(uint8(MiyaPool(pool).kind()), uint8(MiyaPool.Kind.ERC1155));
    }

    function test_factory_rejectsRandom1155() public {
        vm.expectRevert(MiyaPoolFactory.RandomRequiresERC721.selector);
        factory.createPool(address(editions), MiyaPool.RedeemMode.RANDOM);
    }

    function test_factory_rejectsNonNFT() public {
        address junk = address(new NotAnNFT());
        vm.expectRevert(MiyaPoolFactory.UnsupportedCollection.selector);
        factory.createPool(junk, MiyaPool.RedeemMode.TARGETED);
        vm.expectRevert(MiyaPoolFactory.UnsupportedCollection.selector);
        factory.createPool(makeAddr("eoa"), MiyaPool.RedeemMode.TARGETED);
    }

    function test_metadata() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        assertEq(pool.name(), "miya pool: miyamaker mini");
        assertEq(pool.symbol(), "mMIYAMINI");
        assertEq(pool.decimals(), 18);
    }

    // ── ERC721 deposits ──────────────────────────────────────────────────────

    function test_721_depositMintsOneUnitEach() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);
        assertEq(pool.balanceOf(alice), 3 * UNIT);
        assertEq(pool.heldUnits(), 3);
        assertTrue(pool.isHeld(2));
        assertEq(nft.ownerOf(2), address(pool));
        _assertBacked(pool);
    }

    function test_721_depositToOtherRecipient() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1), _none(), bob);
        assertEq(pool.balanceOf(bob), UNIT);
        assertEq(pool.balanceOf(alice), 0);
    }

    function test_721_directSafeTransferDeposits() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(pool), 4);
        assertEq(pool.balanceOf(alice), UNIT);
        _assertBacked(pool);
    }

    function test_721_plainTransferIsNotTracked() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        nft.transferFrom(alice, address(pool), 4);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.heldUnits(), 0);
        _assertBacked(pool);
    }

    function test_721_hookOnlyFromCollection() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.expectRevert(MiyaPool.NotCollection.selector);
        pool.onERC721Received(alice, alice, 1, "");
    }

    function test_721_hookChecksOwnership() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(address(nft));
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.TransferNotReceived.selector, 1));
        pool.onERC721Received(alice, alice, 1, "");
    }

    function test_depositEmptyReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        vm.expectRevert(MiyaPool.EmptyRequest.selector);
        pool.deposit(_none(), _none(), alice);
    }

    // ── ERC721 targeted redeems ──────────────────────────────────────────────

    function test_721_targetedRedeem() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);
        vm.prank(alice);
        pool.transfer(bob, UNIT);
        vm.prank(bob);
        pool.redeem(_ids(3), _none(), bob);
        assertEq(nft.ownerOf(3), bob);
        assertEq(pool.balanceOf(bob), 0);
        assertFalse(pool.isHeld(3));
        assertEq(pool.heldUnits(), 2);
        _assertBacked(pool);
    }

    function test_721_redeemNotHeldReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1, 2), _none(), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.NotHeld.selector, 9));
        pool.redeem(_ids(9), _none(), alice);
    }

    function test_721_redeemDuplicateReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1, 2), _none(), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.NotHeld.selector, 1));
        pool.redeem(_ids(1, 1), _none(), alice);
    }

    function test_721_redeemWithoutTokensReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1), _none(), alice);
        vm.prank(bob);
        vm.expectRevert();
        pool.redeem(_ids(1), _none(), bob);
    }

    function test_targetedRedeemBlockedInRandomPool() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.prank(alice);
        pool.deposit(_ids(1), _none(), alice);
        vm.prank(alice);
        vm.expectRevert(MiyaPool.WrongMode.selector);
        pool.redeem(_ids(1), _none(), alice);
    }

    // ── ERC1155 ──────────────────────────────────────────────────────────────

    function test_1155_depositAndPartialRedeem() public {
        MiyaPool pool = _pool1155();
        uint256[] memory amounts = _ids(4, 3);
        vm.prank(alice);
        pool.deposit(_ids(1, 2), amounts, alice);
        assertEq(pool.balanceOf(alice), 7 * UNIT);
        assertEq(pool.heldUnits(), 7);
        assertEq(pool.unitsOf(1), 4);

        vm.prank(alice);
        pool.redeem(_ids(1, 2), _ids(1, 3), bob);
        assertEq(editions.balanceOf(bob, 1), 1);
        assertEq(editions.balanceOf(bob, 2), 3);
        assertEq(pool.heldUnits(), 3);
        assertEq(pool.unitsOf(2), 0);
        assertEq(pool.heldIdsCount(), 1);
        _assertBacked(pool);
    }

    function test_1155_directTransferDeposits() public {
        MiyaPool pool = _pool1155();
        vm.prank(alice);
        editions.safeTransferFrom(alice, address(pool), 1, 2, "");
        assertEq(pool.balanceOf(alice), 2 * UNIT);
        _assertBacked(pool);
    }

    function test_1155_overRedeemReverts() public {
        MiyaPool pool = _pool1155();
        vm.prank(alice);
        pool.deposit(_ids(1), _ids(2), alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.NotHeld.selector, 1));
        pool.redeem(_ids(1), _ids(3), alice);
    }

    function test_1155_lengthMismatchReverts() public {
        MiyaPool pool = _pool1155();
        vm.prank(alice);
        vm.expectRevert(MiyaPool.LengthMismatch.selector);
        pool.deposit(_ids(1, 2), _ids(1), alice);
    }

    function test_1155_hookRejectedBy721Pool() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(address(nft));
        vm.expectRevert(MiyaPool.NotCollection.selector);
        pool.onERC1155Received(alice, alice, 1, 1, "");
    }

    // ── random redeems ───────────────────────────────────────────────────────

    function test_random_commitReveal() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.prank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);

        vm.prank(alice);
        uint256 id = pool.commitRedeem(2, bob);
        assertEq(pool.balanceOf(alice), UNIT);
        assertEq(pool.pendingUnits(), 2);
        _assertBacked(pool);

        vm.expectRevert(MiyaPool.TooEarly.selector);
        pool.revealRedeem(id);

        (, uint64 target,,) = pool.commits(id);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("seed"));
        vm.prank(makeAddr("anyone"));
        pool.revealRedeem(id);

        assertEq(nft.balanceOf(bob), 2);
        assertEq(pool.heldUnits(), 1);
        assertEq(pool.pendingUnits(), 0);
        _assertBacked(pool);

        vm.expectRevert(MiyaPool.UnknownCommit.selector);
        pool.revealRedeem(id);
    }

    function test_random_reservesHeldUnits() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.prank(alice);
        pool.deposit(_ids(1, 2), _none(), alice);
        vm.prank(alice);
        pool.commitRedeem(1, alice);
        vm.prank(alice);
        pool.commitRedeem(1, alice);
        assertEq(pool.pendingUnits(), 2);
        // all held units are reserved, so tokens minted later are the only ones that can commit
        vm.prank(alice);
        pool.deposit(_ids(3), _none(), alice);
        vm.prank(alice);
        pool.commitRedeem(1, alice);
        _assertBacked(pool);
    }

    function test_random_rearmsWhenExpired() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.prank(alice);
        pool.deposit(_ids(1, 2), _none(), alice);
        vm.prank(alice);
        uint256 id = pool.commitRedeem(1, alice);
        (, uint64 target,,) = pool.commits(id);

        vm.roll(target + 9000);
        pool.revealRedeem(id);
        (, uint64 rearmed,,) = pool.commits(id);
        assertEq(rearmed, block.number + 1);
        assertEq(nft.balanceOf(alice), 8);
        _assertBacked(pool);

        vm.roll(rearmed + 1);
        vm.setBlockhash(rearmed, keccak256("late"));
        pool.revealRedeem(id);
        assertEq(nft.balanceOf(alice), 9);
        _assertBacked(pool);
    }

    function test_random_lateDepositsDoNotShiftPick() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.prank(alice);
        pool.deposit(_ids(1, 2, 3, 4), _none(), alice);
        vm.prank(alice);
        uint256 id = pool.commitRedeem(1, bob);
        (, uint64 target,,) = pool.commits(id);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("fixed"));

        uint256 snap = vm.snapshotState();
        pool.revealRedeem(id);
        uint256 pickedWithout = _onlyTokenOf(bob);
        vm.revertToState(snap);

        vm.prank(alice);
        pool.deposit(_ids(5, 6, 7), _none(), alice);
        pool.revealRedeem(id);
        assertEq(_onlyTokenOf(bob), pickedWithout, "late deposits changed the pick");
    }

    function test_random_insufficientHeldReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.prank(alice);
        pool.deposit(_ids(1), _none(), alice);
        deal(address(pool), alice, 5 * UNIT, true);
        vm.prank(alice);
        vm.expectRevert(MiyaPool.InsufficientHeld.selector);
        pool.commitRedeem(2, alice);
    }

    function test_random_commitBlockedInTargetedPool() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1), _none(), alice);
        vm.prank(alice);
        vm.expectRevert(MiyaPool.WrongMode.selector);
        pool.commitRedeem(1, alice);
    }

    function _onlyTokenOf(address who) internal view returns (uint256) {
        for (uint256 id = 1; id <= 10; ++id) {
            if (nft.ownerOf(id) == who) return id;
        }
        revert("none");
    }

    function _ids(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }
}
