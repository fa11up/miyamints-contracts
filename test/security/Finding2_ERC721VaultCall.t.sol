// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721AuctionInstance} from "../../src/factories/erc721/ERC721AuctionInstance.sol";
import {MockRevertingVault} from "../mocks/MockRevertingVault.sol";
import {PaymentLib} from "../../src/libraries/PaymentLib.sol";

contract Finding2_ERC721VaultCallTest is Test {
    ERC721AuctionInstance public instance;
    MockRevertingVault public revertVault;

    address public artist   = address(0xA1);
    address public bidder   = address(0xB1);
    address public treasury = address(0xFEE);
    address public weth     = address(0xE770);

    function setUp() public {
        revertVault = new MockRevertingVault();

        instance = new ERC721AuctionInstance(
            ERC721AuctionInstance.ConstructorParams({
                vault: address(revertVault),
                protocolTreasury: treasury,
                protocolFeeBps: 100,
                alignmentBps: 1900,
                owner: artist,
                name: "Test",
                symbol: "TST",
                lines: 1,
                baseDuration: 1 hours,
                timeBuffer: 5 minutes,
                bidIncrement: 0.01 ether,
                factory: address(this),
                weth: weth,
                registry: address(0x4E61), // ETH only: never consulted
                currency: address(0)
            })
        );

        vm.deal(artist, 10 ether);
        vm.deal(bidder, 10 ether);
        vm.deal(treasury, 1 ether);
    }

    /// @notice settleAuction must NOT revert when vault.receiveContribution reverts.
    ///         pendingVaultCut must accumulate and VaultContributionFailed must emit.
    function test_settleAuction_doesNotRevertWhenVaultFails() public {
        vm.prank(artist);
        instance.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);

        vm.prank(bidder);
        instance.createBid{value: 0.1 ether}(1, 0.1 ether, "");

        vm.warp(block.timestamp + 2 hours);

        vm.expectEmit(true, false, false, false);
        emit PaymentLib.VaultContributionFailed(address(0), 0);
        instance.settleAuction(1);

        assertGt(instance.pendingVaultCut(address(0)), 0, "pendingVaultCut should accumulate");
    }

    /// @notice flushPendingVaultCut with reverting vault should revert (vault still broken)
    function test_flushPendingVaultCut_revertsWhenVaultStillBroken() public {
        vm.prank(artist);
        instance.queuePiece{value: 0.1 ether}("ipfs://piece1", 0.1 ether);
        vm.prank(bidder);
        instance.createBid{value: 0.1 ether}(1, 0.1 ether, "");
        vm.warp(block.timestamp + 2 hours);
        instance.settleAuction(1);

        vm.expectRevert();
        instance.flushPendingVaultCut(address(0), 0);
    }
}
