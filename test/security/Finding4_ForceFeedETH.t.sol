// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Instance} from "../../src/factories/erc1155/ERC1155Instance.sol";
import {InsufficientBalance} from "../../src/factories/erc1155/ERC1155Instance.sol";
import {MockRevertingVault} from "../mocks/MockRevertingVault.sol";
import {TokenPrice} from "../../src/factories/interfaces/TokenPrice.sol";

contract Finding4_ERC1155ForceFeedTest is Test {
    ERC1155Instance public instance;

    address public creator  = address(0xC1);
    address public buyer    = address(0xB2);
    address public treasury = address(0xFEE);
    address public weth     = address(0xE770);

    function _eth(uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(address(0), price);
    }

    function setUp() public {
        instance = new ERC1155Instance(
            "TestCollection",
            creator,
            address(this),
            address(new MockRevertingVault()),
            "",
            ERC1155Instance.InstanceInit({
                protocolTreasury: treasury,
                protocolFeeBps: 100,
                alignmentBps: 1900,
                gatingModule: address(0),
                dynamicPricingModule: address(0),
                weth: weth,
                registry: address(0x4E61), // ETH only: never consulted
                acceptedTokens: new address[](1)
            })
        );

        vm.prank(creator);
        instance.addEdition("Piece 1", _eth(1 ether), 0, "ipfs://meta", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);

        vm.deal(buyer, 100 ether);
        vm.deal(treasury, 10 ether);
    }

    /// @notice Force-fed ETH is not proceeds: the owner's withdraw pays only its share of what was sold.
    function test_withdraw_cannotExceedTotalProceeds() public {
        vm.prank(buyer);
        instance.mint{value: 1 ether}(1, 1, bytes32(0), "", address(0), 0);

        assertEq(instance.totalProceeds(address(0)), 1 ether);

        // Inflate balance as if selfdestruct was used
        vm.deal(address(instance), address(instance).balance + 10 ether);

        vm.prank(creator);
        instance.withdraw(address(0));
        assertEq(creator.balance, 0.8 ether, "only the artist's share of the sale");
        assertEq(instance.unsplitProceeds(address(0)), 0);
        // The vault refused its cut (MockRevertingVault): parked, never paid out to the artist.
        assertEq(instance.pendingVaultCut(address(0)), 0.19 ether);
    }

    /// @notice Normal withdrawal within proceeds works
    function test_withdraw_worksWithinProceeds() public {
        vm.prank(buyer);
        instance.mint{value: 1 ether}(1, 1, bytes32(0), "", address(0), 0);

        vm.deal(treasury, 10 ether);
        vm.prank(creator);
        instance.withdraw(address(0));
    }

    /// @notice Proceeds are paid once
    function test_withdraw_preventsDoubleWithdrawal() public {
        vm.prank(buyer);
        instance.mint{value: 1 ether}(1, 1, bytes32(0), "", address(0), 0);

        vm.deal(treasury, 10 ether);
        vm.prank(creator);
        instance.withdraw(address(0));

        vm.prank(creator);
        vm.expectRevert(InsufficientBalance.selector);
        instance.withdraw(address(0));
    }
}
