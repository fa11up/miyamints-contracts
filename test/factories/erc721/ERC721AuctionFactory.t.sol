// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MiyaPool} from "../../../src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "../../../src/pools/MiyaPoolFactory.sol";
import {ERC721AuctionFactory} from "../../../src/factories/erc721/ERC721AuctionFactory.sol";
import {ERC721AuctionInstance, SettlementGasTooLow, DepositRequired, URIRequired, BidBelowMinimum, BidTooLow, AuctionExpired, AuctionNotEnded, NoBids, HasBids, NotEscrowedWinner, RenounceDisabled} from "../../../src/factories/erc721/ERC721AuctionInstance.sol";
import {UniAlignmentVault} from "../../../src/vaults/uni/UniAlignmentVault.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {MockZRouter} from "../../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../../mocks/MockVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../../../src/interfaces/IVaultPriceValidator.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {MiyaRegistry} from "../../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract ERC721AuctionFactoryTest is Test {
    ERC721AuctionFactory public factory;
    UniAlignmentVault public vault;
    MockEXECToken public token;
    MiyaRegistry public registry;

    uint256 constant TARGET_ID = 0;
    uint16 constant ALIGNMENT_BPS = 1900; // 1% protocol / 19% vault / 80% artist

    address public owner = address(0x1);
    address public artist = address(0x2);
    address public bidder1 = address(0x3);
    address public bidder2 = address(0x4);
    address public treasury = address(0x5);

    uint256 internal _saltCounter;

    uint40 constant BASE_DURATION = 1 hours;
    uint40 constant TIME_BUFFER = 5 minutes;
    uint256 constant BID_INCREMENT = 0.01 ether;

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function _params() internal view returns (ERC721AuctionFactory.CreateParams memory) {
        return ERC721AuctionFactory.CreateParams({
            name: "Artist Collection",
            metadataURI: "ipfs://meta",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGNMENT_BPS,
            symbol: "ART",
            lines: 1,
            baseDuration: BASE_DURATION,
            timeBuffer: TIME_BUFFER,
            bidIncrement: BID_INCREMENT
        });
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        vm.startPrank(owner);

        token = new MockEXECToken(1000000e18);

        // Registry owned by `owner`; 1% protocol fee, 10% minimum alignment
        registry = new MiyaRegistry(owner, treasury, 100, 1000);
        {
            address[] memory targetTokens = new address[](1);
            targetTokens[0] = address(token);
            registry.addTarget("Test target", targetTokens);
        }

        {
            UniAlignmentVault _impl = new UniAlignmentVault();
            vault = UniAlignmentVault(payable(LibClone.clone(address(_impl))));
            vault.initialize(
                owner,
                address(0x2222222222222222222222222222222222222222),
                address(0x4444444444444444444444444444444444444444),
                address(token),
                address(new MockZRouter()),
                3000,
                60,
                IVaultPriceValidator(address(new MockVaultPriceValidator())),
                IMiyaRegistry(address(registry)),
                TARGET_ID
            );
        }

        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        factory = new ERC721AuctionFactory(IMiyaRegistry(address(registry)), address(0xBEEF));
        registry.setFactory(address(factory), true);
        registry.setVaultFactory(owner, true); // this test acts as the vault factory
        registry.registerVault(address(vault));

        vm.stopPrank();
    }

    // ┌─────────────────────────┐
    // │    Factory Tests        │
    // └─────────────────────────┘

    function test_FactoryCreation() public view {
        assertEq(factory.protocol(), owner);
    }

    function test_CreateInstance() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);

        address instance = factory.createInstance{value: 0}(_nextSalt(), _params());

        assertTrue(instance != address(0));
        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));
        assertEq(inst.name(), "Artist Collection");
        assertEq(inst.symbol(), "ART");
        assertEq(address(inst.vault()), address(vault));
        assertEq(inst.protocolTreasury(), treasury);
        assertEq(inst.lines(), 1);
        assertEq(inst.baseDuration(), BASE_DURATION);
        assertEq(inst.timeBuffer(), TIME_BUFFER);
        assertEq(inst.bidIncrement(), BID_INCREMENT);
        assertEq(inst.owner(), artist);
    }

    function test_CreateInstance_FeeGoesDirectlyToTreasury() public {
        vm.deal(artist, 1 ether);
        uint256 treasuryBefore = treasury.balance;

        vm.prank(artist);
        factory.createInstance{value: 0.01 ether}(_nextSalt(), _params());

        assertEq(treasury.balance - treasuryBefore, 0.01 ether);
        assertEq(address(factory).balance, 0);
    }

    function test_computeInstanceAddress() public view {
        bytes32 salt = bytes32(uint256(1));
        address predicted = factory.computeInstanceAddress(salt, address(this));
        assertTrue(predicted != address(0));
    }

    // ┌─────────────────────────┐
    // │   Auction Flow Tests    │
    // └─────────────────────────┘

    function _createDefaultInstance() internal returns (ERC721AuctionInstance) {
        vm.deal(artist, 100 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(_nextSalt(), _params());
        return ERC721AuctionInstance(payable(instance));
    }

    function test_QueuePiece() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.tokenId, 1);
        assertEq(auction.minBid, 0.1 ether);
        assertEq(auction.highBidder, address(0));
        assertTrue(auction.startTime > 0);
        assertFalse(auction.settled);
    }

    function test_QueuePiece_RequiresDeposit() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        vm.expectRevert(DepositRequired.selector);
        inst.queuePiece{value: 0}("ipfs://piece1");
    }

    function test_QueuePiece_RequiresURI() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        vm.expectRevert(URIRequired.selector);
        inst.queuePiece{value: 0.1 ether}("");
    }

    function test_QueuePiece_OnlyOwner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert();
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");
    }

    function test_Bidding_FirstBid() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder1);
        assertEq(auction.highBid, 0.1 ether);
    }

    function test_Bidding_BelowMinimum() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert(BidBelowMinimum.selector);
        inst.createBid{value: 0.05 ether}(1, "");
    }

    function test_Bidding_Outbid() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        uint256 bidder1BalBefore = bidder1.balance;
        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        inst.createBid{value: 0.15 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder2);
        assertEq(auction.highBid, 0.15 ether);
        assertEq(bidder1.balance, bidder1BalBefore + 0.1 ether);
    }

    function test_Bidding_IncrementTooLow() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        vm.expectRevert(BidTooLow.selector);
        inst.createBid{value: 0.105 ether}(1, "");
    }

    function test_Bidding_AntiSnipe() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        uint40 originalEnd = auction.endTime;

        vm.warp(originalEnd - 2 minutes);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        auction = inst.getAuction(1);
        assertEq(auction.endTime, uint40(block.timestamp) + TIME_BUFFER);
        assertTrue(auction.endTime > originalEnd);
    }

    function test_Bidding_ExpiredAuction() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime + 1);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert(AuctionExpired.selector);
        inst.createBid{value: 0.1 ether}(1, "");
    }

    // ┌─────────────────────────┐
    // │   Settlement Tests      │
    // └─────────────────────────┘

    function test_SettleAuction() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 1 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        uint256 artistBalBefore = artist.balance;
        uint256 vaultBalBefore = address(vault).balance;
        uint256 treasuryBalBefore = treasury.balance;

        inst.settleAuction(1);

        assertEq(inst.ownerOf(1), bidder1);

        uint256 protocolCut = 1 ether / 100;
        uint256 expectedVaultCut = (1 ether * 19) / 100;
        uint256 expectedCreatorCut = 1 ether - protocolCut - expectedVaultCut;
        uint256 expectedCreatorPay = 0.1 ether + expectedCreatorCut;
        assertEq(artist.balance - artistBalBefore, expectedCreatorPay);
        assertEq(address(vault).balance - vaultBalBefore, expectedVaultCut);
        assertEq(treasury.balance - treasuryBalBefore, protocolCut);

        auction = inst.getAuction(1);
        assertTrue(auction.settled);
    }

    function test_SettleAuction_BeforeEnd() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        vm.expectRevert(AuctionNotEnded.selector);
        inst.settleAuction(1);
    }

    function test_SettleAuction_NoBids() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.expectRevert(NoBids.selector);
        inst.settleAuction(1);
    }

    // ┌─────────────────────────┐
    // │  Unsold Reclaim Tests   │
    // └─────────────────────────┘

    function test_ReclaimUnsold() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        uint256 treasuryBalBefore = treasury.balance;

        vm.prank(artist);
        inst.reclaimUnsold(1);

        assertEq(treasury.balance - treasuryBalBefore, 0.1 ether);

        auction = inst.getAuction(1);
        assertTrue(auction.settled);
    }

    function test_ReclaimUnsold_HasBids() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.prank(artist);
        vm.expectRevert(HasBids.selector);
        inst.reclaimUnsold(1);
    }

    function test_ReclaimUnsold_OnlyOwner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.prank(bidder1);
        vm.expectRevert();
        inst.reclaimUnsold(1);
    }

    // ┌─────────────────────────┐
    // │    Lines System Tests   │
    // └─────────────────────────┘

    function test_Lines_RoundRobin() public {
        vm.deal(artist, 100 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(),
            ERC721AuctionFactory.CreateParams({
                name: "Multi Line",
                metadataURI: "ipfs://meta",
                creator: artist,
                vault: address(vault),
                alignmentBps: ALIGNMENT_BPS,
                symbol: "ML",
                lines: 3,
                baseDuration: BASE_DURATION,
                timeBuffer: TIME_BUFFER,
                bidIncrement: BID_INCREMENT
            })
        );
        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));

        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1"); // tokenId 1 -> line 0
        inst.queuePiece{value: 0.1 ether}("ipfs://2"); // tokenId 2 -> line 1
        inst.queuePiece{value: 0.1 ether}("ipfs://3"); // tokenId 3 -> line 2
        inst.queuePiece{value: 0.1 ether}("ipfs://4"); // tokenId 4 -> line 0
        inst.queuePiece{value: 0.1 ether}("ipfs://5"); // tokenId 5 -> line 1
        inst.queuePiece{value: 0.1 ether}("ipfs://6"); // tokenId 6 -> line 2
        vm.stopPrank();

        assertEq(inst.getActiveAuction(0), 1);
        assertEq(inst.getActiveAuction(1), 2);
        assertEq(inst.getActiveAuction(2), 3);
        assertEq(inst.getQueueLength(0), 2);
        assertEq(inst.getQueueLength(1), 2);
        assertEq(inst.getQueueLength(2), 2);
    }

    function test_Lines_AutoAdvance() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1");
        inst.queuePiece{value: 0.1 ether}("ipfs://2");
        vm.stopPrank();

        assertEq(inst.getActiveAuction(0), 1);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);
        inst.settleAuction(1);

        assertEq(inst.getActiveAuction(0), 2);
        auction = inst.getAuction(2);
        assertTrue(auction.startTime > 0);
    }

    // ┌─────────────────────────┐
    // │    TokenURI Tests       │
    // └─────────────────────────┘

    function test_TokenURI() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);
        inst.settleAuction(1);

        assertEq(inst.tokenURI(1), "ipfs://piece1");
    }

    // ┌─────────────────────────┐
    // │   Full Workflow Test    │
    // └─────────────────────────┘

    function test_FullWorkflow_QueueBidSettle() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1");
        inst.queuePiece{value: 0.2 ether}("ipfs://2");
        inst.queuePiece{value: 0.3 ether}("ipfs://3");
        vm.stopPrank();

        assertEq(inst.getActiveAuction(0), 1);

        vm.deal(bidder1, 10 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.5 ether}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);
        inst.settleAuction(1);

        assertEq(inst.ownerOf(1), bidder1);
        assertEq(inst.getActiveAuction(0), 2);

        auction = inst.getAuction(2);
        vm.warp(auction.endTime);
        vm.prank(artist);
        inst.reclaimUnsold(2);

        assertEq(inst.getActiveAuction(0), 3);

        vm.prank(bidder1);
        inst.createBid{value: 0.3 ether}(3, "");

        auction = inst.getAuction(3);
        vm.warp(auction.endTime);
        inst.settleAuction(3);

        assertEq(inst.ownerOf(3), bidder1);
        assertEq(inst.getActiveAuction(0), 0);
    }

    // ┌─────────────────────────┐
    // │   Messaging Tests       │
    // └─────────────────────────┘

    function test_Bidding_WithMessage() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectEmit(true, true, false, true, address(inst));
        emit ERC721AuctionInstance.BidMessage(1, bidder1, "gm love this piece");
        inst.createBid{value: 0.1 ether}(1, "gm love this piece");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder1);
        assertEq(auction.highBid, 0.1 ether);
    }

    // ┌─────────────────────────┐
    // │      Fuzz Tests         │
    // └─────────────────────────┘

    function testFuzz_BidIncrementEnforced(uint256 firstBidRaw, uint256 secondBidRaw) public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        uint256 minBid = 0.1 ether;
        vm.prank(artist);
        inst.queuePiece{value: minBid}("ipfs://fuzz1");

        uint256 firstBid = bound(firstBidRaw, minBid, 100 ether);

        vm.deal(bidder1, firstBid);
        vm.prank(bidder1);
        inst.createBid{value: firstBid}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBid, firstBid);

        uint256 threshold = firstBid + BID_INCREMENT;

        uint256 lowBid = bound(secondBidRaw, minBid, threshold - 1);
        vm.deal(bidder2, lowBid);
        vm.prank(bidder2);
        vm.expectRevert(BidTooLow.selector);
        inst.createBid{value: lowBid}(1, "");

        vm.deal(bidder2, threshold);
        vm.prank(bidder2);
        inst.createBid{value: threshold}(1, "");

        auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder2);
        assertEq(auction.highBid, threshold);
    }

    function testFuzz_SettlementSplitCorrect(uint256 highBidRaw) public {
        uint256 highBid = bound(highBidRaw, 0.01 ether, 10_000 ether);

        ERC721AuctionInstance inst = _createDefaultInstance();

        uint256 deposit = 0.01 ether;
        vm.prank(artist);
        inst.queuePiece{value: deposit}("ipfs://fuzz2");

        vm.deal(bidder1, highBid);
        vm.prank(bidder1);
        inst.createBid{value: highBid}(1, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        uint256 artistBalBefore = artist.balance;
        uint256 vaultBalBefore = address(vault).balance;
        uint256 treasuryBalBefore = treasury.balance;

        inst.settleAuction(1);

        uint256 protocolReceived = treasury.balance - treasuryBalBefore;
        uint256 vaultReceived = address(vault).balance - vaultBalBefore;
        uint256 artistReceived = artist.balance - artistBalBefore;
        uint256 creatorCut = artistReceived - deposit;

        assertEq(
            protocolReceived + vaultReceived + creatorCut,
            highBid,
            "settlement split does not sum to highBid"
        );
    }

    // ┌─────────────────────────┐
    // │  Non-Receiver Safety    │
    // └─────────────────────────┘

    /// Audit M6: a contract winner whose onERC721Received reverts must not freeze settlement (and with it the
    /// artist's proceeds and the line's queue). The token is escrowed and the winner pulls it.
    function test_SettleAuction_ContractBidderWithoutERC721Receiver_Escrows() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        NonReceiverBidder bidder = new NonReceiverBidder();
        vm.deal(address(bidder), 10 ether);

        bidder.bid(address(inst), 1, 0.2 ether);

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, address(bidder));

        vm.warp(auction.endTime);

        uint256 artistBefore = artist.balance;
        inst.settleAuction(1);
        assertTrue(inst.getAuction(1).settled, "settled");
        assertGt(artist.balance, artistBefore, "artist paid");
        assertEq(inst.ownerOf(1), address(inst), "token escrowed");
        assertEq(inst.escrowedWinner(1), address(bidder));

        // Only the winner can claim
        vm.expectRevert(NotEscrowedWinner.selector);
        inst.claimEscrowedToken(1, address(this));

        address wallet = makeAddr("bidderWallet");
        bidder.claim(address(inst), 1, wallet);
        assertEq(inst.ownerOf(1), wallet);
        assertEq(inst.escrowedWinner(1), address(0));
    }

    /// Audit round 1: a winner that burns all the gas it gets must not make settlement unaffordable.
    function test_SettleAuction_GasBurningWinnerSettlesAtNormalGas() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");
        GasBurningBidder bidder = new GasBurningBidder();
        vm.deal(address(bidder), 10 ether);
        bidder.bid(address(inst), 1, 0.2 ether);
        vm.warp(inst.getAuction(1).endTime);

        inst.settleAuction{gas: 2_000_000}(1);
        assertTrue(inst.getAuction(1).settled);
        assertEq(inst.escrowedWinner(1), address(bidder));
    }

    function test_SettleAuction_TooLittleGasRevertsInsteadOfEscrowing() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");
        address winner = makeAddr("winner");
        vm.deal(winner, 1 ether);
        vm.prank(winner);
        inst.createBid{value: 0.2 ether}(1, "");
        vm.warp(inst.getAuction(1).endTime);

        vm.expectRevert(SettlementGasTooLow.selector);
        inst.settleAuction{gas: 500_000}(1);
    }

    /// Audit round 1: another caller using a creator's salt gets a different address.
    function test_SaltIsBoundToCreator() public {
        bytes32 salt = _nextSalt();
        address squatter = makeAddr("squatter");
        ERC721AuctionFactory.CreateParams memory p = _params();
        p.creator = squatter;
        vm.prank(squatter);
        address theirs = factory.createInstance(salt, p);
        assertEq(theirs, factory.computeInstanceAddress(salt, squatter));

        vm.prank(artist);
        address mine = factory.createInstance(salt, _params());
        assertEq(mine, factory.computeInstanceAddress(salt, artist));
        assertTrue(mine != theirs);
    }

    /// Claiming an escrowed token into a MiyaPool credits the winner, not the auction contract.
    function test_EscrowClaimIntoPoolCreditsWinner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");
        NonReceiverBidder bidder = new NonReceiverBidder();
        vm.deal(address(bidder), 10 ether);
        bidder.bid(address(inst), 1, 0.2 ether);
        vm.warp(inst.getAuction(1).endTime);
        inst.settleAuction(1);

        MiyaPool pool = MiyaPool(new MiyaPoolFactory().createPool(address(inst), MiyaPool.RedeemMode.TARGETED));
        bidder.claim(address(inst), 1, address(pool));
        assertEq(pool.balanceOf(address(bidder)), 1e18);
        assertEq(pool.balanceOf(address(inst)), 0);
    }

    function test_SettleAuction_EOAWinnerMintedDirectly() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");
        address eoa = makeAddr("eoaBidder");
        vm.deal(eoa, 1 ether);
        vm.prank(eoa);
        inst.createBid{value: 0.2 ether}(1, "");
        vm.warp(inst.getAuction(1).endTime);
        inst.settleAuction(1);
        assertEq(inst.ownerOf(1), eoa);
        assertEq(inst.escrowedWinner(1), address(0));
    }

    function test_RenounceOwnership_Disabled() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        vm.expectRevert(RenounceDisabled.selector);
        inst.renounceOwnership();
    }
}

/// @dev A contract that can receive ETH but intentionally omits IERC721Receiver.
contract NonReceiverBidder {
    function bid(address instance, uint24 tokenId, uint256 amount) external {
        ERC721AuctionInstance(payable(instance)).createBid{value: amount}(tokenId, "");
    }

    function claim(address instance, uint24 tokenId, address to) external {
        ERC721AuctionInstance(payable(instance)).claimEscrowedToken(tokenId, to);
    }

    receive() external payable {}
}

contract GasBurningBidder {
    receive() external payable {}

    function bid(address inst, uint24 tokenId, uint256 amount) external {
        ERC721AuctionInstance(payable(inst)).createBid{value: amount}(tokenId, "");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        while (true) {}
        return this.onERC721Received.selector;
    }
}
