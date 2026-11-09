// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {MiyaPool} from "../../../src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "../../../src/pools/MiyaPoolFactory.sol";
import {ERC721AuctionFactory} from "../../../src/factories/erc721/ERC721AuctionFactory.sol";
import {ERC721AuctionInstance, SettlementGasTooLow, DepositRequired, URIRequired, BidBelowMinimum, BidTooLow, AuctionExpired, AuctionNotEnded, AuctionAlreadySettled, NoBids, HasBids, Unauthorized, NotEscrowedWinner, RenounceDisabled} from "../../../src/factories/erc721/ERC721AuctionInstance.sol";
import {MockVaultV2} from "../payments/PaymentMocks.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {PaymentLib} from "../../../src/libraries/PaymentLib.sol";
import {MiyaRegistry} from "../../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract ERC721AuctionFactoryTest is Test {
    ERC721AuctionFactory public factory;
    MockVaultV2 public vault;
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
            bidIncrement: BID_INCREMENT,
            currency: address(0)
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

        // Vault v2 stand-in (collections only send it their cut); the real vault keeps a 0.001 ETH minimum.
        vault = new MockVaultV2();
        vault.setMinContribution(address(0), 0.001 ether);

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

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
        inst.queuePiece{value: 0}("ipfs://piece1", 0);
    }

    function test_QueuePiece_RequiresURI() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        vm.expectRevert(URIRequired.selector);
        inst.queuePiece{value: 0.1 ether}("", 0.1 ether);
    }

    function test_QueuePiece_OnlyOwner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert();
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
    }

    function test_Bidding_FirstBid() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder1);
        assertEq(auction.highBid, 0.1 ether);
    }

    function test_Bidding_BelowMinimum() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert(BidBelowMinimum.selector);
        inst.createBid{value: 0.05 ether}(1, 0.05 ether, "");
    }

    function test_Bidding_Outbid() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        uint256 bidder1BalBefore = bidder1.balance;
        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        inst.createBid{value: 0.15 ether}(1, 0.15 ether, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder2);
        assertEq(auction.highBid, 0.15 ether);
        assertEq(bidder1.balance, bidder1BalBefore + 0.1 ether);
    }

    function test_Bidding_IncrementTooLow() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        vm.expectRevert(BidTooLow.selector);
        inst.createBid{value: 0.105 ether}(1, 0.105 ether, "");
    }

    function test_Bidding_AntiSnipe() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        uint40 originalEnd = auction.endTime;

        vm.warp(originalEnd - 2 minutes);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        auction = inst.getAuction(1);
        assertEq(auction.endTime, uint40(block.timestamp) + TIME_BUFFER);
        assertTrue(auction.endTime > originalEnd);
    }

    function test_Bidding_ExpiredAuction() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime + 1);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert(AuctionExpired.selector);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");
    }

    // ┌─────────────────────────┐
    // │   Settlement Tests      │
    // └─────────────────────────┘

    function test_SettleAuction() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 1 ether}(1, 1 ether, "");

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        vm.expectRevert(AuctionNotEnded.selector);
        inst.settleAuction(1);
    }

    function test_SettleAuction_NoBids() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.prank(artist);
        vm.expectRevert(HasBids.selector);
        inst.reclaimUnsold(1);
    }

    function test_ReclaimUnsold_OnlyOwner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.prank(bidder1);
        vm.expectRevert(Unauthorized.selector);
        inst.reclaimUnsold(1);
    }

    function test_ReclaimUnsold_AnyoneAfterGrace_AdvancesLineAndPaysOnlyTreasury() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        inst.queuePiece{value: 0.2 ether}("ipfs://piece2", 0.2 ether);
        vm.stopPrank();
        uint40 endTime = inst.getAuction(1).endTime;

        vm.warp(uint256(endTime) + inst.UNSOLD_CLOSE_GRACE() - 1);
        vm.prank(bidder1);
        vm.expectRevert(Unauthorized.selector);
        inst.reclaimUnsold(1);

        vm.warp(uint256(endTime) + inst.UNSOLD_CLOSE_GRACE());
        uint256 treasuryBefore = treasury.balance;
        uint256 callerBefore = bidder1.balance;
        uint256 artistBefore = artist.balance;
        vm.prank(bidder1);
        inst.reclaimUnsold(1);

        assertTrue(inst.getAuction(1).settled);
        assertEq(treasury.balance - treasuryBefore, 0.1 ether);
        assertEq(bidder1.balance, callerBefore);
        assertEq(artist.balance, artistBefore);
        // only the next piece's deposit is left, and that piece is now live
        assertEq(address(inst).balance, 0.2 ether);
        assertEq(inst.getActiveAuction(0), 2);

        vm.prank(bidder1);
        vm.expectRevert(AuctionAlreadySettled.selector);
        inst.reclaimUnsold(1);
    }

    function test_ReclaimUnsold_GraceDoesNotOpenBidAuctionsOrLiveOnes() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.prank(bidder1);
        vm.expectRevert(AuctionNotEnded.selector);
        inst.reclaimUnsold(1);

        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");
        vm.warp(uint256(inst.getAuction(1).endTime) + inst.UNSOLD_CLOSE_GRACE());
        vm.prank(bidder1);
        vm.expectRevert(HasBids.selector);
        inst.reclaimUnsold(1);
    }

    function test_GetActiveAuction_EndedPieceIsNotActive() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        assertEq(inst.getActiveAuction(0), 1);

        vm.warp(inst.getAuction(1).endTime);
        assertEq(inst.getActiveAuction(0), 0);
        // still findable, so it can be closed
        assertEq(inst.lineQueues(0, inst.lineQueueHead(0)), 1);
        assertEq(inst.getQueueLength(0), 1);
    }

    // ┌─────────────────────────┐
    // │   Parked vault cuts     │
    // └─────────────────────────┘

    /// @dev Sells one piece for 0.005 ETH: a 19% cut of 0.00095 ETH, under the real vault's 0.001 minimum, so it parks.
    function _instanceWithDustParked() internal returns (ERC721AuctionInstance inst) {
        inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.005 ether}("ipfs://piece1", 0.005 ether);
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.005 ether}(1, 0.005 ether, "");
        vm.warp(inst.getAuction(1).endTime);
        inst.settleAuction(1);
        assertEq(inst.pendingVaultCut(address(0)), 0.00095 ether);
        assertEq(address(inst).balance, 0.00095 ether);
    }

    function test_FlushVaultCut_DustCanBeToppedUpToReachTheVault() public {
        ERC721AuctionInstance inst = _instanceWithDustParked();

        vm.expectRevert(bytes("below minimum"));
        inst.flushPendingVaultCut(address(0), 0);

        // not enough: reverts, so the helper keeps its ETH and the cut stays parked
        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        vm.expectRevert(bytes("below minimum"));
        inst.flushPendingVaultCut{value: 0.00004 ether}(address(0), 0.00004 ether);
        assertEq(bidder2.balance, 1 ether);
        assertEq(inst.pendingVaultCut(address(0)), 0.00095 ether);

        uint256 vaultBefore = address(vault).balance;
        vm.prank(bidder2);
        inst.flushPendingVaultCut{value: 0.00005 ether}(address(0), 0.00005 ether);
        assertEq(inst.pendingVaultCut(address(0)), 0);
        assertEq(address(inst).balance, 0);
        assertEq(address(vault).balance - vaultBefore, 0.001 ether);
        // credited to the collection, not to whoever topped it up
        assertEq(vault.credited(address(inst), address(0)), 0.001 ether);
        assertEq(vault.credited(bidder2, address(0)), 0);
    }

    function test_FlushVaultCut_ToppingUpNothingParkedReverts() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert(PaymentLib.NothingParked.selector);
        inst.flushPendingVaultCut{value: 0.01 ether}(address(0), 0.01 ether);
    }

    function test_FlushVaultCut_NextSaleCarriesDust() public {
        ERC721AuctionInstance inst = _instanceWithDustParked();
        vm.prank(artist);
        inst.queuePiece{value: 0.005 ether}("ipfs://piece2", 0.005 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.005 ether}(2, 0.005 ether, "");
        vm.warp(inst.getAuction(2).endTime);
        inst.settleAuction(2);
        assertEq(inst.pendingVaultCut(address(0)), 0);
        assertEq(vault.credited(address(inst), address(0)), 0.0019 ether);
    }

    function test_SettleAuction_ZeroAlignmentMakesNoVaultCall() public {
        ERC721AuctionInstance inst = new ERC721AuctionInstance(
            ERC721AuctionInstance.ConstructorParams({
                vault: address(vault),
                protocolTreasury: treasury,
                protocolFeeBps: 100,
                alignmentBps: 0,
                owner: artist,
                name: "No alignment",
                symbol: "NA",
                lines: 1,
                baseDuration: BASE_DURATION,
                timeBuffer: TIME_BUFFER,
                bidIncrement: BID_INCREMENT,
                factory: address(factory),
                weth: address(0),
                registry: address(registry),
                currency: address(0)
            })
        );
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 1 ether}(1, 1 ether, "");
        vm.warp(inst.getAuction(1).endTime);

        vm.recordLogs();
        inst.settleAuction(1);
        bytes32 failed = keccak256("VaultContributionFailed(address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != failed, "no contribution was due");
        }
        assertEq(inst.pendingVaultCut(address(0)), 0);
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
                bidIncrement: BID_INCREMENT,
                currency: address(0)
            })
        );
        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));

        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1", 0.1 ether); // tokenId 1 -> line 0
        inst.queuePiece{value: 0.1 ether}("ipfs://2", 0.1 ether); // tokenId 2 -> line 1
        inst.queuePiece{value: 0.1 ether}("ipfs://3", 0.1 ether); // tokenId 3 -> line 2
        inst.queuePiece{value: 0.1 ether}("ipfs://4", 0.1 ether); // tokenId 4 -> line 0
        inst.queuePiece{value: 0.1 ether}("ipfs://5", 0.1 ether); // tokenId 5 -> line 1
        inst.queuePiece{value: 0.1 ether}("ipfs://6", 0.1 ether); // tokenId 6 -> line 2
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
        inst.queuePiece{value: 0.1 ether}("ipfs://1", 0.1 ether);
        inst.queuePiece{value: 0.1 ether}("ipfs://2", 0.1 ether);
        vm.stopPrank();

        assertEq(inst.getActiveAuction(0), 1);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "");

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
        inst.queuePiece{value: 0.1 ether}("ipfs://1", 0.1 ether);
        inst.queuePiece{value: 0.2 ether}("ipfs://2", 0.2 ether);
        inst.queuePiece{value: 0.3 ether}("ipfs://3", 0.3 ether);
        vm.stopPrank();

        assertEq(inst.getActiveAuction(0), 1);

        vm.deal(bidder1, 10 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.5 ether}(1, 0.5 ether, "");

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
        inst.createBid{value: 0.3 ether}(3, 0.3 ether, "");

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectEmit(true, true, false, true, address(inst));
        emit ERC721AuctionInstance.BidMessage(1, bidder1, "gm love this piece");
        inst.createBid{value: 0.1 ether}(1, 0.1 ether, "gm love this piece");

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
        inst.queuePiece{value: minBid}("ipfs://fuzz1", minBid);

        uint256 firstBid = bound(firstBidRaw, minBid, 100 ether);

        vm.deal(bidder1, firstBid);
        vm.prank(bidder1);
        inst.createBid{value: firstBid}(1, firstBid, "");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBid, firstBid);

        uint256 threshold = firstBid + BID_INCREMENT;

        uint256 lowBid = bound(secondBidRaw, minBid, threshold - 1);
        vm.deal(bidder2, lowBid);
        vm.prank(bidder2);
        vm.expectRevert(BidTooLow.selector);
        inst.createBid{value: lowBid}(1, lowBid, "");

        vm.deal(bidder2, threshold);
        vm.prank(bidder2);
        inst.createBid{value: threshold}(1, threshold, "");

        auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder2);
        assertEq(auction.highBid, threshold);
    }

    function testFuzz_SettlementSplitCorrect(uint256 highBidRaw) public {
        uint256 highBid = bound(highBidRaw, 0.01 ether, 10_000 ether);

        ERC721AuctionInstance inst = _createDefaultInstance();

        uint256 deposit = 0.01 ether;
        vm.prank(artist);
        inst.queuePiece{value: deposit}("ipfs://fuzz2", deposit);

        vm.deal(bidder1, highBid);
        vm.prank(bidder1);
        inst.createBid{value: highBid}(1, highBid, "");

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        address winner = makeAddr("winner");
        vm.deal(winner, 1 ether);
        vm.prank(winner);
        inst.createBid{value: 0.2 ether}(1, 0.2 ether, "");
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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
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
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        address eoa = makeAddr("eoaBidder");
        vm.deal(eoa, 1 ether);
        vm.prank(eoa);
        inst.createBid{value: 0.2 ether}(1, 0.2 ether, "");
        vm.warp(inst.getAuction(1).endTime);
        inst.settleAuction(1);
        assertEq(inst.ownerOf(1), eoa);
        assertEq(inst.escrowedWinner(1), address(0));
    }

    /// Happy path of safeMintWinner: settleAuction self-calls it and the winner gets the token.
    function test_SafeMintWinner_CalledBySettle() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        address eoa = makeAddr("eoaBidder");
        vm.deal(eoa, 1 ether);
        vm.prank(eoa);
        inst.createBid{value: 0.2 ether}(1, 0.2 ether, "");
        vm.warp(inst.getAuction(1).endTime);
        vm.expectCall(address(inst), abi.encodeCall(ERC721AuctionInstance.safeMintWinner, (eoa, uint24(1))));
        inst.settleAuction(1);
        assertEq(inst.ownerOf(1), eoa);
    }

    function test_SafeMintWinner_DirectCallReverts() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        inst.safeMintWinner(attacker, 1);

        // Not even the owner can call it directly.
        vm.prank(artist);
        vm.expectRevert(Unauthorized.selector);
        inst.safeMintWinner(artist, 1);
    }

    function test_RenounceOwnership_Disabled() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.prank(artist);
        vm.expectRevert(RenounceDisabled.selector);
        inst.renounceOwnership();
    }

    // ── a treasury that refuses ETH ──────────────────────────────────────────

    function _instanceWithOwnTreasury(address taker) internal returns (ERC721AuctionInstance) {
        vm.prank(owner);
        registry.setTreasury(taker);
        return _createDefaultInstance();
    }

    function test_SettleAuction_ParksProtocolCutWhenTreasuryRefuses() public {
        address taker = makeAddr("refusing treasury");
        ERC721AuctionInstance inst = _instanceWithOwnTreasury(taker);
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 1 ether}(1, 1 ether, "");
        vm.warp(inst.getAuction(1).endTime);

        vm.etch(taker, hex"60006000fd");
        inst.settleAuction(1);

        assertTrue(inst.getAuction(1).settled);
        assertEq(inst.ownerOf(1), bidder1);
        assertEq(inst.pendingProtocolCut(address(0)), 0.01 ether);

        vm.expectRevert();
        inst.flushPendingProtocolCut(address(0));

        vm.etch(taker, "");
        inst.flushPendingProtocolCut(address(0));
        assertEq(taker.balance, 0.01 ether);
        assertEq(inst.pendingProtocolCut(address(0)), 0);
    }

    function test_ReclaimUnsold_ParksDepositWhenTreasuryRefuses() public {
        address taker = makeAddr("refusing treasury");
        ERC721AuctionInstance inst = _instanceWithOwnTreasury(taker);
        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        vm.warp(inst.getAuction(1).endTime);

        vm.etch(taker, hex"60006000fd");
        vm.prank(artist);
        inst.reclaimUnsold(1);

        assertTrue(inst.getAuction(1).settled);
        assertEq(inst.pendingProtocolCut(address(0)), 0.1 ether);
    }

    function test_FlushProtocolCut_NothingParked() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        vm.expectRevert(PaymentLib.NothingParked.selector);
        inst.flushPendingProtocolCut(address(0));
    }
}

/// @dev A contract that can receive ETH but intentionally omits IERC721Receiver.
contract NonReceiverBidder {
    function bid(address instance, uint24 tokenId, uint256 amount) external {
        ERC721AuctionInstance(payable(instance)).createBid{value: amount}(tokenId, amount, "");
    }

    function claim(address instance, uint24 tokenId, address to) external {
        ERC721AuctionInstance(payable(instance)).claimEscrowedToken(tokenId, to);
    }

    receive() external payable {}
}

contract GasBurningBidder {
    receive() external payable {}

    function bid(address inst, uint24 tokenId, uint256 amount) external {
        ERC721AuctionInstance(payable(inst)).createBid{value: amount}(tokenId, amount, "");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        while (true) {}
        return this.onERC721Received.selector;
    }
}
