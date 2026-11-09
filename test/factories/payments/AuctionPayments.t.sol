// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721AuctionFactory } from "../../../src/factories/erc721/ERC721AuctionFactory.sol";
import {
    ERC721AuctionInstance,
    WrongPayment,
    NothingToRefund,
    BidTooLow,
    BidBelowMinimum,
    AuctionExpired,
    Unauthorized
} from "../../../src/factories/erc721/ERC721AuctionInstance.sol";
import { IMiyaRegistry } from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import { ClaimMode } from "../../../src/interfaces/IAlignmentVault.sol";
import { PaymentLib } from "../../../src/libraries/PaymentLib.sol";
import { PaymentTestBase, MockToken } from "./PaymentMocks.sol";

/// @notice Auctions in one currency per collection: ETH as before, or an allowlisted ERC-20 with pull refunds.
contract AuctionPaymentsTest is PaymentTestBase {
    ERC721AuctionFactory factory;
    uint16 constant ALIGN = 1900;
    uint40 constant DURATION = 1 hours;
    uint40 constant BUFFER = 5 minutes;
    uint256 salt;

    function setUp() public {
        _setUpPayments();
        factory = new ERC721AuctionFactory(IMiyaRegistry(address(registry)), makeAddr("weth"));
    }

    function _auction(address currency, uint256 increment) internal returns (ERC721AuctionInstance a) {
        ERC721AuctionFactory.CreateParams memory p = ERC721AuctionFactory.CreateParams({
            name: "One of one",
            metadataURI: "ipfs://m",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGN,
            symbol: "OOO",
            lines: 1,
            baseDuration: DURATION,
            timeBuffer: BUFFER,
            bidIncrement: increment,
            currency: currency
        });
        vm.prank(artist);
        a = ERC721AuctionInstance(payable(factory.createInstance(bytes32(++salt), p)));
    }

    function _queue(ERC721AuctionInstance a, uint256 deposit) internal returns (uint24 id) {
        address c = a.currency();
        _approve(artist, c, address(a));
        vm.prank(artist);
        if (c == ETH) a.queuePiece{ value: deposit }("ar://piece", deposit);
        else a.queuePiece("ar://piece", deposit);
        id = a.nextTokenId() - 1;
    }

    function _bid(ERC721AuctionInstance a, address who, uint24 id, uint256 amount) internal {
        address c = a.currency();
        _approve(who, c, address(a));
        vm.prank(who);
        if (c == ETH) a.createBid{ value: amount }(id, amount, "");
        else a.createBid(id, amount, "");
    }

    /// @dev What the collection holds equals what it owes, per token.
    function _assertSolvent(ERC721AuctionInstance a) internal view {
        address c = a.currency();
        assertEq(
            _bal(c, address(a)),
            a.escrowed(c) + a.ownerBalance(c) + a.pendingVaultCut(c) + a.pendingProtocolCut(c),
            "held == owed"
        );
    }

    // ── ETH: today's behaviour ──────────────────────────────────────────────

    function test_eth_refundsPushedAndSettlePays() public {
        ERC721AuctionInstance a = _auction(ETH, 0.01 ether);
        assertEq(a.acceptedTokens()[0], ETH);
        uint24 id = _queue(a, 0.1 ether);
        _bid(a, alice, id, 0.1 ether);
        uint256 aliceBefore = alice.balance;
        _bid(a, bob, id, 0.11 ether);
        assertEq(alice.balance - aliceBefore, 0.1 ether, "outbid ETH refunded at once");
        assertEq(a.refundOf(alice), 0);
        _assertSolvent(a);

        vm.warp(block.timestamp + DURATION);
        uint256 artistBefore = artist.balance;
        a.settleAuction(id);
        assertEq(a.ownerOf(id), bob);
        uint256 protocol = 0.11 ether / 100;
        uint256 toVault = 0.11 ether * uint256(ALIGN) / 10_000;
        assertEq(treasury.balance, protocol);
        assertEq(vault.received(ETH), toVault);
        assertEq(artist.balance - artistBefore, 0.1 ether + 0.11 ether - protocol - toVault, "deposit + share pushed");
        assertEq(address(a).balance, 0);

        vm.prank(artist);
        vm.expectRevert(PaymentLib.NothingToWithdraw.selector);
        a.withdraw(ETH);
    }

    function test_eth_valueMustMatchAmount() public {
        ERC721AuctionInstance a = _auction(ETH, 0.01 ether);
        vm.prank(artist);
        vm.expectRevert(WrongPayment.selector);
        a.queuePiece{ value: 0.1 ether }("u", 0.2 ether);
        uint24 id = _queue(a, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert(WrongPayment.selector);
        a.createBid{ value: 0.1 ether }(id, 0.2 ether, "");
    }

    // ── ERC-20 auctions ─────────────────────────────────────────────────────

    function test_usdc_fullCycle_pullRefundsAndOwnerBalance() public {
        ERC721AuctionInstance a = _auction(address(usdc), 10e6);
        uint256 artistStart = usdc.balanceOf(artist);
        uint24 id = _queue(a, 500e6);
        assertEq(artistStart - usdc.balanceOf(artist), 500e6, "deposit pulled");

        vm.prank(alice);
        vm.expectRevert(BidBelowMinimum.selector);
        a.createBid(id, 499e6, "");
        _bid(a, alice, id, 500e6);
        vm.prank(bob);
        vm.expectRevert(BidTooLow.selector);
        a.createBid(id, 509e6, "");
        uint256 aliceBefore = usdc.balanceOf(alice);
        _bid(a, bob, id, 510e6);
        assertEq(usdc.balanceOf(alice), aliceBefore, "ERC-20 refunds are pulled, not pushed");
        assertEq(a.refundOf(alice), 500e6);
        _bid(a, alice, id, 600e6);
        assertEq(a.refundOf(bob), 510e6);
        _assertSolvent(a);

        vm.prank(alice);
        a.claimRefund(alice);
        assertEq(usdc.balanceOf(alice), aliceBefore - 600e6 + 500e6);
        vm.prank(alice);
        vm.expectRevert(NothingToRefund.selector);
        a.claimRefund(alice);

        vm.warp(block.timestamp + DURATION);
        a.settleAuction(id);
        assertEq(a.ownerOf(id), alice);
        uint256 protocol = 6e6;
        uint256 toVault = 600e6 * uint256(ALIGN) / 10_000;
        assertEq(usdc.balanceOf(treasury), protocol);
        assertEq(vault.received(address(usdc)), toVault);
        assertEq(a.ownerBalance(address(usdc)), 500e6 + 600e6 - protocol - toVault);
        _assertSolvent(a);

        vm.prank(artist);
        a.withdrawAll();
        assertEq(usdc.balanceOf(artist), artistStart + 600e6 - protocol - toVault);

        // Bob's refund survives settlement.
        vm.prank(bob);
        a.claimRefund(bob);
        assertEq(a.escrowed(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(a)), 0);
    }

    function test_usdc_refusesEth() public {
        ERC721AuctionInstance a = _auction(address(usdc), 10e6);
        _approve(artist, address(usdc), address(a));
        vm.prank(artist);
        vm.expectRevert(PaymentLib.WrongValue.selector);
        a.queuePiece{ value: 1 }("u", 100e6);
        uint24 id = _queue(a, 100e6);
        _approve(alice, address(usdc), address(a));
        vm.prank(alice);
        vm.expectRevert(PaymentLib.WrongValue.selector);
        a.createBid{ value: 1 }(id, 100e6, "");
    }

    function test_blocklistedBidderCannotStopAHigherBid() public {
        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        uint24 id = _queue(a, 100e6);
        _bid(a, alice, id, 100e6);
        usdc.setBlocked(alice, true);
        _bid(a, bob, id, 101e6);
        assertEq(a.refundOf(alice), 100e6);

        vm.prank(alice);
        vm.expectRevert();
        a.claimRefund(alice);
        address safe = makeAddr("aliceSafe");
        vm.prank(alice);
        a.claimRefund(safe);
        assertEq(usdc.balanceOf(safe), 100e6);
    }

    function test_blocklistedOwnerOrTreasuryCannotStopSettlement() public {
        ERC721AuctionInstance a = _auction(address(wbtc), 0.0001e8);
        uint24 id = _queue_wbtc(a, 0.01e8);
        _bid(a, alice, id, 0.02e8);
        wbtc.setBlocked(artist, true);
        wbtc.setBlocked(treasury, true);
        vm.warp(block.timestamp + DURATION);
        a.settleAuction(id);
        assertEq(a.ownerOf(id), alice);
        assertEq(a.pendingProtocolCut(address(wbtc)), 0.0002e8);
        assertEq(a.ownerBalance(address(wbtc)), 0.01e8 + 0.02e8 - 0.0002e8 - 0.0038e8);
        _assertSolvent(a);

        vm.prank(artist);
        vm.expectRevert();
        a.withdraw(address(wbtc));
        wbtc.setBlocked(artist, false);
        wbtc.setBlocked(treasury, false);
        vm.prank(artist);
        a.withdraw(address(wbtc));
        a.flushPendingProtocolCut(address(wbtc));
        assertEq(wbtc.balanceOf(address(a)), 0);
    }

    function _queue_wbtc(ERC721AuctionInstance a, uint256 deposit) internal returns (uint24) {
        wbtc.mint(artist, deposit);
        return _queue(a, deposit);
    }

    function test_vaultRefusesErc20_parkedThenFlushed() public {
        ERC721AuctionInstance a = _auction(address(imdUsd), 1e18);
        imdUsd.mint(artist, 100e18);
        uint24 id = _queue(a, 10e18);
        _bid(a, alice, id, 20e18);
        vault.setRejecting(true);
        vm.warp(block.timestamp + DURATION);
        a.settleAuction(id);
        assertEq(a.pendingVaultCut(address(imdUsd)), 3.8e18);
        assertEq(imdUsd.allowance(address(a), address(vault)), 0);
        _assertSolvent(a);
        vault.setRejecting(false);
        a.flushPendingVaultCut(address(imdUsd), 0);
        assertEq(vault.credited(address(a), address(imdUsd)), 3.8e18);
    }

    function test_reclaimUnsold_forfeitsDepositInCurrency() public {
        ERC721AuctionInstance a = _auction(address(cbbtc), 0.0001e8);
        uint24 id = _queue(a, 0.005e8);
        vm.warp(block.timestamp + DURATION);
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        a.reclaimUnsold(id);
        vm.prank(artist);
        a.reclaimUnsold(id);
        assertEq(cbbtc.balanceOf(treasury), 0.005e8);
        assertEq(a.escrowed(address(cbbtc)), 0);
        _assertSolvent(a);
    }

    function test_reclaimUnsold_blocklistedTreasuryParks() public {
        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        uint24 id = _queue(a, 50e6);
        usdc.setBlocked(treasury, true);
        vm.warp(block.timestamp + DURATION + a.UNSOLD_CLOSE_GRACE());
        vm.prank(bob); // anyone after the grace period
        a.reclaimUnsold(id);
        assertEq(a.pendingProtocolCut(address(usdc)), 50e6);
        _assertSolvent(a);
    }

    function test_antiSnipeUnchangedForErc20() public {
        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        uint24 id = _queue(a, 10e6);
        _bid(a, alice, id, 10e6);
        uint40 end = a.getAuction(id).endTime;
        vm.warp(end - 1 minutes);
        _bid(a, bob, id, 11e6);
        assertEq(a.getAuction(id).endTime, uint40(block.timestamp) + BUFFER);
        vm.warp(a.getAuction(id).endTime);
        vm.prank(carol);
        vm.expectRevert(AuctionExpired.selector);
        a.createBid(id, 20e6, "");
    }

    function test_feeOnTransferCurrencyRefused() public {
        ERC721AuctionInstance a = _auction(address(feeToken), 1e18);
        feeToken.mint(artist, 100e18);
        _approve(artist, address(feeToken), address(a));
        vm.prank(artist);
        vm.expectRevert(PaymentLib.ShortTransfer.selector);
        a.queuePiece("u", 10e18);
    }

    function test_currencyMustBeAllowlisted_andRemovalStopsNewPiecesOnly() public {
        MockToken rogue = new MockToken("R", "R", 18);
        ERC721AuctionFactory.CreateParams memory p = ERC721AuctionFactory.CreateParams({
            name: "x",
            metadataURI: "",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGN,
            symbol: "X",
            lines: 1,
            baseDuration: DURATION,
            timeBuffer: BUFFER,
            bidIncrement: 1,
            currency: address(rogue)
        });
        vm.prank(artist);
        vm.expectRevert();
        factory.createInstance(bytes32(uint256(777)), p);

        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        uint24 id = _queue(a, 10e6);
        registry.setPaymentToken(address(usdc), false);
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAllowed.selector, address(usdc)));
        a.queuePiece("u2", 10e6);
        // The running auction finishes in its currency.
        _bid(a, alice, id, 10e6);
        vm.warp(block.timestamp + DURATION);
        a.settleAuction(id);
        assertEq(a.ownerOf(id), alice);
    }

    function test_sweepUntracked_strayCurrencyIsSplitLikeASale() public {
        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        uint24 id = _queue(a, 10e6);
        _bid(a, alice, id, 20e6);
        uint256 owed = a.ownerBalance(address(usdc));
        vm.prank(bob);
        usdc.transfer(address(a), 100e6); // e.g. royalties paid to the auction house
        a.sweepUntracked(address(usdc));
        assertGt(a.ownerBalance(address(usdc)), owed, "artist share booked");
        _assertSolvent(a);
        vm.expectRevert(PaymentLib.NothingToWithdraw.selector);
        a.sweepUntracked(address(usdc)); // escrow and bids are never counted
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAccepted.selector, address(wbtc)));
        a.sweepUntracked(address(wbtc));
    }

    function test_claimVaultFees() public {
        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        _fundVaultFees(1e18, 2e18, 0.1 ether);
        uint256 before = artist.balance;
        vm.prank(artist);
        a.claimVaultFees(ClaimMode.TOKENS, 0);
        assertEq(infer.balanceOf(artist), 1e18);
        assertEq(imd.balanceOf(artist), 2e18);
        assertEq(artist.balance - before, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert();
        a.claimVaultFees(ClaimMode.TOKENS, 0);
    }

    function testFuzz_erc20BiddingStaysSolvent(uint256 seed, uint8 rounds) public {
        ERC721AuctionInstance a = _auction(address(usdc), 1e6);
        uint24 id = _queue(a, 10e6);
        rounds = uint8(bound(rounds, 1, 12));
        address[3] memory who = [alice, bob, carol];
        uint256 bid = 10e6;
        for (uint256 i; i < rounds; ++i) {
            _bid(a, who[(seed >> i) % 3], id, bid);
            bid += 1e6 + (seed >> (i + 8)) % 5e6;
            _assertSolvent(a);
        }
        vm.warp(block.timestamp + 2 hours);
        a.settleAuction(id);
        _assertSolvent(a);
        for (uint256 i; i < 3; ++i) {
            if (a.refundOf(who[i]) != 0) {
                vm.prank(who[i]);
                a.claimRefund(who[i]);
            }
        }
        vm.prank(artist);
        a.withdraw(address(usdc));
        assertEq(usdc.balanceOf(address(a)), 0);
    }
}
