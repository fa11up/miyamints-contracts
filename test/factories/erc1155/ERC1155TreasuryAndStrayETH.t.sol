// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AmountMustBePositive, ERC1155Instance, NoPendingProtocolCut } from "../../../src/factories/erc1155/ERC1155Instance.sol";

contract StrayTestVault {
    bool public rejecting;
    uint256 public received;

    function setRejecting(bool r) external {
        rejecting = r;
    }

    function receiveContribution(address, uint256 amount, address) external payable {
        require(!rejecting, "rejecting");
        received += amount;
    }
}

contract ERC1155TreasuryAndStrayETHTest is Test {
    ERC1155Instance instance;
    StrayTestVault vault;

    address creator = address(0xC1);
    address buyer = address(0xB2);
    address treasury = address(0xFEE);

    function setUp() public {
        vault = new StrayTestVault();
        instance = new ERC1155Instance(
            "TestCollection",
            creator,
            address(this),
            address(vault),
            "",
            ERC1155Instance.InstanceInit({
                protocolTreasury: treasury,
                protocolFeeBps: 100,
                alignmentBps: 1900,
                gatingModule: address(0),
                dynamicPricingModule: address(0),
                weth: address(0xE770)
            })
        );
        vm.prank(creator);
        instance.addEdition("Piece 1", 1 ether, 0, "ipfs://meta", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        instance.mint{ value: 1 ether }(1, 1, bytes32(0), "", 0);
    }

    function test_withdrawParksProtocolCutWhenTreasuryRefuses() public {
        vm.etch(treasury, hex"60006000fd");
        instance.withdraw(1 ether);
        assertEq(instance.pendingProtocolCut(), 0.01 ether);
        assertEq(vault.received(), 0.19 ether);
        assertEq(creator.balance, 0.8 ether);
        assertEq(address(instance).balance, 0.01 ether);
    }

    function test_parkedProtocolCutReachesTreasuryOnceItAccepts() public {
        vm.etch(treasury, hex"60006000fd");
        instance.withdraw(1 ether);

        vm.expectRevert();
        instance.flushPendingProtocolCut();

        vm.etch(treasury, "");
        instance.flushPendingProtocolCut();
        assertEq(treasury.balance, 0.01 ether);
        assertEq(instance.pendingProtocolCut(), 0);

        vm.expectRevert(NoPendingProtocolCut.selector);
        instance.flushPendingProtocolCut();
    }

    function test_strayETHCanBeSweptThroughTheSplit() public {
        (bool ok,) = address(instance).call{ value: 1 ether }("");
        require(ok);

        vm.prank(makeAddr("anyone"));
        instance.sweepUntrackedETH();
        assertEq(instance.totalProceeds(), 2 ether);

        instance.withdraw(2 ether);
        assertEq(treasury.balance, 0.02 ether);
        assertEq(vault.received(), 0.38 ether);
        assertEq(creator.balance, 1.6 ether);
        assertEq(address(instance).balance, 0);
    }

    function test_sweepFindsNothingInMintProceeds() public {
        vm.expectRevert(AmountMustBePositive.selector);
        instance.sweepUntrackedETH();
    }

    function test_sweepLeavesParkedCutsAlone() public {
        vm.etch(treasury, hex"60006000fd");
        vault.setRejecting(true);
        instance.withdraw(1 ether);
        assertEq(address(instance).balance, 0.2 ether, "both cuts parked");

        vm.expectRevert(AmountMustBePositive.selector);
        instance.sweepUntrackedETH();
    }

    function test_sweepAfterPartialWithdrawOnlyCountsTheStray() public {
        instance.withdraw(0.25 ether);
        vm.deal(address(instance), address(instance).balance + 0.5 ether);
        instance.sweepUntrackedETH();
        assertEq(instance.totalProceeds() - instance.totalWithdrawn(), 1.25 ether);
    }
}
