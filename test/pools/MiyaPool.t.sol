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

/// @dev A collection that refuses transfers to a blocked address.
contract Blocking721 is Mock721 {
    address public blocked;

    function setBlocked(address who) external {
        blocked = who;
    }

    function _beforeTokenTransfer(address, address to, uint256) internal view override {
        require(to == address(0) || to != blocked, "blocked");
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

    // ── audit round 1 ────────────────────────────────────────────────────────

    function test_factory_rejectsCollectionThatClaimsEverything() public {
        ClaimsEverything c = new ClaimsEverything();
        vm.expectRevert(MiyaPoolFactory.UnsupportedCollection.selector);
        factory.createPool(address(c), MiyaPool.RedeemMode.RANDOM);
    }

    function test_factory_rejectsCollectionFailingTheErc165Probe() public {
        Claims721AndInvalidId c = new Claims721AndInvalidId();
        vm.expectRevert(MiyaPoolFactory.UnsupportedCollection.selector);
        factory.createPool(address(c), MiyaPool.RedeemMode.RANDOM);
    }

    function test_safeMintIntoPoolReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        SafeMint721 m = new SafeMint721();
        MiyaPool p2 = MiyaPool(factory.createPool(address(m), MiyaPool.RedeemMode.TARGETED));
        vm.expectRevert(MiyaPool.InvalidRecipient.selector);
        m.safeMint(address(p2), 7);
        assertEq(pool.totalSupply(), 0);
    }

    function test_secondHookForHeldIdCannotMintUnbackedTokens() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1), _none(), alice);
        // The collection itself calling the hook again, as an admin transfer helper could.
        vm.prank(address(nft));
        vm.expectRevert(abi.encodeWithSelector(MiyaPool.AlreadyHeld.selector, 1));
        pool.onERC721Received(address(nft), bob, 1, "");
        assertEq(pool.totalSupply(), UNIT);
    }

    function test_poolCannotBeTheRecipient() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.startPrank(alice);
        pool.deposit(_ids(1), _none(), alice);
        vm.expectRevert(MiyaPool.InvalidRecipient.selector);
        pool.redeem(_ids(1), _none(), address(pool));
        vm.stopPrank();

        MiyaPool random = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.startPrank(alice);
        random.deposit(_ids(2), _none(), alice);
        vm.expectRevert(MiyaPool.InvalidRecipient.selector);
        random.commitRedeem(1, address(random));
        vm.stopPrank();
    }

    function test_heldIdsClampsHugeCount() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.TARGETED);
        vm.prank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);
        assertEq(pool.heldIds(1, type(uint256).max).length, 2);
    }

    /// A recipient that burns gas through a collection's transfer callback must not block the queue.
    function test_gasBurningRecipientCannotBlockQueue() public {
        Notify721 n = new Notify721();
        for (uint256 id = 1; id <= 6; ++id) n.mint(alice, id);
        MiyaPool pool = MiyaPool(factory.createPool(address(n), MiyaPool.RedeemMode.RANDOM));
        uint256[] memory ids = new uint256[](6);
        for (uint256 i; i < 6; ++i) ids[i] = i + 1;
        vm.startPrank(alice);
        n.setApprovalForAll(address(pool), true);
        pool.deposit(ids, _none(), alice);
        pool.transfer(bob, UNIT);
        uint256 c0 = pool.commitRedeem(5, address(new GasBurner()));
        vm.stopPrank();
        vm.prank(bob);
        uint256 c1 = pool.commitRedeem(1, bob);
        vm.roll(block.number + 2);

        pool.revealRedeem{ gas: 10_000_000 }(c0);
        assertEq(pool.nextRevealId(), c1, "queue moved past the burner");
        pool.revealRedeem(c1);
        assertEq(n.balanceOf(bob), 1);
    }

    /// Reveals are strictly ordered, so the largest commit must fit in one mainnet transaction (EIP-7825) at worst.
    function test_largestRevealToGasBurnerFitsMainnetGasCap() public {
        RefusingNotify721 n = new RefusingNotify721();
        uint256[] memory ids = new uint256[](50);
        for (uint256 i; i < 50; ++i) {
            ids[i] = i + 1;
            n.mint(alice, i + 1);
        }
        MiyaPool pool = MiyaPool(factory.createPool(address(n), MiyaPool.RedeemMode.RANDOM));
        vm.startPrank(alice);
        n.setApprovalForAll(address(pool), true);
        pool.deposit(ids, _none(), alice);
        address burner = address(new GasBurner());
        n.setNotified(burner);
        uint256 c = pool.commitRedeem(50, burner);
        vm.stopPrank();
        vm.roll(block.number + 2);

        uint256 before = gasleft();
        pool.revealRedeem{ gas: 16_777_216 }(c);
        emit log_named_uint("reveal gas", before - gasleft());
        assertEq(pool.nextRevealId(), c + 1);
        // The worst case: every transfer burned its gas and failed, so every id also wrote an escrow entry.
        for (uint256 i; i < 50; ++i) assertTrue(pool.escrowedTo(i + 1) != address(0));
    }

    function test_revealWithTooLittleGasRevertsInsteadOfEscrowing() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.startPrank(alice);
        pool.deposit(_ids(1), _none(), alice);
        uint256 c = pool.commitRedeem(1, bob);
        vm.stopPrank();
        vm.roll(block.number + 2);
        vm.expectRevert(MiyaPool.RevealGasTooLow.selector);
        pool.revealRedeem{ gas: 200_000 }(c);
        assertEq(pool.escrowedTo(1), address(0));
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

    // ── M1: nothing moves a pick once its target block is mined ─────────────

    function _mined(MiyaPool pool, uint256 commitId, bytes32 seed) internal {
        (, uint64 target,,) = pool.commits(commitId);
        if (block.number <= target) vm.roll(target + 1);
        vm.setBlockhash(target, seed);
    }

    function test_random_revealsRunInCommitOrder() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.startPrank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);
        uint256 first = pool.commitRedeem(1, alice);
        uint256 second = pool.commitRedeem(1, bob);
        vm.stopPrank();
        _mined(pool, first, keccak256("a"));
        _mined(pool, second, keccak256("b"));

        vm.expectRevert(MiyaPool.NotNextCommit.selector);
        pool.revealRedeem(second);
        pool.revealRedeem(first);
        assertEq(pool.nextRevealId(), second);
        pool.revealRedeem(second);
    }

    function test_random_depositsAfterACommitAreNeverDrawn() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.startPrank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);
        uint256 id = pool.commitRedeem(3, bob);
        pool.deposit(_ids(4, 5, 6), _none(), alice);
        vm.stopPrank();
        _mined(pool, id, keccak256("x"));
        pool.revealRedeem(id);
        for (uint256 tokenId = 1; tokenId <= 3; ++tokenId) assertEq(nft.ownerOf(tokenId), bob);
        for (uint256 tokenId = 4; tokenId <= 6; ++tokenId) assertEq(nft.ownerOf(tokenId), address(pool));
    }

    /// The M1 attack: with both outcomes public, deposit between two reveals to change what the second one gets.
    function testFuzz_random_depositBetweenRevealsCannotSteer(bytes32 seedA, bytes32 seedB) public {
        vm.assume(seedA != 0 && seedB != 0);
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.startPrank(alice);
        pool.deposit(_ids(1, 2, 3, 4), _none(), alice);
        uint256 first = pool.commitRedeem(2, makeAddr("first"));
        uint256 second = pool.commitRedeem(1, bob);
        vm.stopPrank();
        _mined(pool, first, seedA);
        _mined(pool, second, seedB);

        uint256 snap = vm.snapshotState();
        pool.revealRedeem(first);
        pool.revealRedeem(second);
        uint256 honest = _onlyTokenOf(bob);
        vm.revertToState(snap);

        vm.prank(alice);
        pool.deposit(_ids(5, 6), _none(), alice);
        pool.revealRedeem(first);
        vm.prank(alice);
        pool.deposit(_ids(7), _none(), alice);
        pool.revealRedeem(second);
        assertEq(_onlyTokenOf(bob), honest, "a deposit steered the pick");
    }

    function testFuzz_random_everyDrawIsDistinctAndEligible(bytes32 seed, uint8 extra) public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        uint256 late = bound(extra, 0, 4);
        vm.startPrank(alice);
        pool.deposit(_ids(1, 2, 3), _none(), alice);
        uint256 a = pool.commitRedeem(2, bob);
        pool.deposit(_ids(4, 5, 6), _none(), alice);
        uint256 b = pool.commitRedeem(3, bob);
        if (late > 0) pool.deposit(_ids(7), _none(), alice);
        vm.stopPrank();
        _mined(pool, a, keccak256(abi.encode(seed, 1)));
        _mined(pool, b, keccak256(abi.encode(seed, 2)));
        pool.revealRedeem(a);
        pool.revealRedeem(b);
        assertEq(nft.balanceOf(bob), 5);
        assertEq(pool.pendingUnits(), 0);
        if (late > 0) assertEq(nft.ownerOf(7), address(pool));
        _assertBacked(pool);
    }

    // ── ordered reveals must not be blockable ───────────────────────────────

    function test_random_zeroRecipientReverts() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        vm.startPrank(alice);
        pool.deposit(_ids(1), _none(), alice);
        vm.expectRevert(MiyaPool.InvalidRecipient.selector);
        pool.commitRedeem(1, address(0));
        vm.stopPrank();
    }

    function test_random_commitIsCapped() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        uint256 cap = pool.MAX_COMMIT_UNITS();
        vm.prank(alice);
        vm.expectRevert(MiyaPool.CommitTooLarge.selector);
        pool.commitRedeem(cap + 1, alice);
    }

    function test_random_largestRevealFitsInABlock() public {
        MiyaPool pool = _pool721(MiyaPool.RedeemMode.RANDOM);
        uint256 cap = pool.MAX_COMMIT_UNITS();
        for (uint256 tokenId = 100; tokenId < 100 + cap; ++tokenId) nft.mint(alice, tokenId);
        uint256[] memory ids = new uint256[](cap);
        for (uint256 i; i < cap; ++i) ids[i] = 100 + i;
        vm.startPrank(alice);
        nft.setApprovalForAll(address(pool), true);
        pool.deposit(ids, _none(), alice);
        uint256 id = pool.commitRedeem(cap, bob);
        vm.stopPrank();
        _mined(pool, id, keccak256("big"));
        uint256 start = gasleft();
        pool.revealRedeem(id);
        assertLt(start - gasleft(), 10_000_000, "reveal must stay well under the block gas limit");
    }

    function test_random_refusedTransferIsEscrowedAndDoesNotBlockTheQueue() public {
        Blocking721 blocking = new Blocking721();
        address stuck = makeAddr("stuck");
        blocking.setBlocked(stuck);
        for (uint256 tokenId = 1; tokenId <= 2; ++tokenId) blocking.mint(alice, tokenId);
        MiyaPool pool = MiyaPool(factory.createPool(address(blocking), MiyaPool.RedeemMode.RANDOM));
        vm.startPrank(alice);
        blocking.setApprovalForAll(address(pool), true);
        pool.deposit(_ids(1, 2), _none(), alice);
        uint256 first = pool.commitRedeem(1, stuck);
        uint256 second = pool.commitRedeem(1, bob);
        vm.stopPrank();
        _mined(pool, first, keccak256("a"));
        _mined(pool, second, keccak256("b"));

        pool.revealRedeem(first);
        pool.revealRedeem(second);
        assertEq(blocking.balanceOf(bob), 1, "the next commit still settled");

        uint256 escrowed = blocking.ownerOf(1) == address(pool) ? 1 : 2;
        assertEq(blocking.ownerOf(escrowed), address(pool));
        assertEq(pool.escrowedTo(escrowed), stuck);
        assertEq(pool.heldUnits(), 0);

        vm.prank(alice);
        vm.expectRevert(MiyaPool.NotEscrowed.selector);
        pool.claimEscrowed(escrowed, alice);

        address elsewhere = makeAddr("elsewhere");
        vm.prank(stuck);
        pool.claimEscrowed(escrowed, elsewhere);
        assertEq(blocking.ownerOf(escrowed), elsewhere);
        assertEq(pool.escrowedTo(escrowed), address(0));
    }
}

contract ClaimsEverything {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract SafeMint721 is Mock721 {
    function safeMint(address to, uint256 id) external {
        _safeMint(to, id);
    }
}

/// @dev A collection whose plain transferFrom notifies contract recipients and ignores failures.
contract Notify721 is Mock721 {
    function transferFrom(address from, address to, uint256 id) public payable override {
        super.transferFrom(from, to, id);
        if (to.code.length != 0) {
            try GasBurner(payable(to)).onNotify() { } catch { }
        }
    }
}

contract GasBurner {
    function onNotify() external pure {
        while (true) { }
    }
}

/// @dev Answers true for everything except ERC-1155, so only the ERC-165 probe can catch it.
contract Claims721AndInvalidId {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id != 0xd9b67a26;
    }
}

/// @dev Calls contract recipients on transferFrom and lets their failure refuse the transfer.
contract RefusingNotify721 is Mock721 {
    address public notified;

    function setNotified(address who) external {
        notified = who;
    }

    function transferFrom(address from, address to, uint256 id) public payable override {
        super.transferFrom(from, to, id);
        if (to == notified) GasBurner(to).onNotify();
    }
}
