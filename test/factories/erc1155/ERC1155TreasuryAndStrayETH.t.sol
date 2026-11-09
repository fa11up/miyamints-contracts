// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AmountMustBePositive, ERC1155Instance } from "../../../src/factories/erc1155/ERC1155Instance.sol";
import { PaymentLib } from "../../../src/libraries/PaymentLib.sol";
import { TokenPrice } from "../../../src/factories/interfaces/TokenPrice.sol";

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

    function _eth(uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(address(0), price);
    }

    /// @dev Split the ETH proceeds (anyone) and pay the creator its share.
    function _withdraw() internal {
        instance.distribute(address(0));
        vm.prank(creator);
        instance.withdraw(address(0));
    }

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
                weth: address(0xE770),
                registry: address(0x4E61), // ETH only: never consulted
                acceptedTokens: new address[](1)
            })
        );
        vm.prank(creator);
        instance.addEdition("Piece 1", _eth(1 ether), 0, "ipfs://meta", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.deal(buyer, 100 ether);
        vm.prank(buyer);
        instance.mint{ value: 1 ether }(1, 1, bytes32(0), "", address(0), 0);
    }

    function test_withdrawParksProtocolCutWhenTreasuryRefuses() public {
        vm.etch(treasury, hex"60006000fd");
        _withdraw();
        assertEq(instance.pendingProtocolCut(address(0)), 0.01 ether);
        assertEq(vault.received(), 0.19 ether);
        assertEq(creator.balance, 0.8 ether);
        assertEq(address(instance).balance, 0.01 ether);
    }

    function test_parkedProtocolCutReachesTreasuryOnceItAccepts() public {
        vm.etch(treasury, hex"60006000fd");
        _withdraw();

        vm.expectRevert();
        instance.flushPendingProtocolCut(address(0));

        vm.etch(treasury, "");
        instance.flushPendingProtocolCut(address(0));
        assertEq(treasury.balance, 0.01 ether);
        assertEq(instance.pendingProtocolCut(address(0)), 0);

        vm.expectRevert(PaymentLib.NothingParked.selector);
        instance.flushPendingProtocolCut(address(0));
    }

    function test_strayETHCanBeSweptThroughTheSplit() public {
        (bool ok,) = address(instance).call{ value: 1 ether }("");
        require(ok);

        vm.prank(makeAddr("anyone"));
        instance.sweepUntracked(address(0));
        assertEq(instance.totalProceeds(address(0)), 2 ether);

        _withdraw();
        assertEq(treasury.balance, 0.02 ether);
        assertEq(vault.received(), 0.38 ether);
        assertEq(creator.balance, 1.6 ether);
        assertEq(address(instance).balance, 0);
    }

    function test_sweepFindsNothingInMintProceeds() public {
        vm.expectRevert(AmountMustBePositive.selector);
        instance.sweepUntracked(address(0));
    }

    function test_sweepLeavesParkedCutsAlone() public {
        vm.etch(treasury, hex"60006000fd");
        vault.setRejecting(true);
        _withdraw();
        assertEq(address(instance).balance, 0.2 ether, "both cuts parked");

        vm.expectRevert(AmountMustBePositive.selector);
        instance.sweepUntracked(address(0));
    }

    function test_sweepAfterSplitOnlyCountsTheStray() public {
        instance.distribute(address(0)); // the artist's 0.8 stays owed here
        vm.deal(address(instance), address(instance).balance + 0.5 ether);
        instance.sweepUntracked(address(0));
        assertEq(instance.unsplitProceeds(address(0)), 0.5 ether);
        assertEq(instance.totalProceeds(address(0)), 1.5 ether);
    }
}
