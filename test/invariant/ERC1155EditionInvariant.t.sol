// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1155Instance} from "../../src/factories/erc1155/ERC1155Instance.sol";
import {ERC1155EditionHandler} from "./handlers/ERC1155EditionHandler.sol";
import {TokenPrice} from "../../src/factories/interfaces/TokenPrice.sol";

contract MockAlignmentVault {
    receive() external payable {}
    function receiveContribution(bytes32, uint256, address) external payable {}
}

contract ERC1155EditionInvariantTest is StdInvariant, Test {
    ERC1155Instance public instance;
    ERC1155EditionHandler public handler;

    address public owner = address(0x1);
    address public protocolTreasury = address(0xFEE);
    address public mockVault;

    address[] public actors;

    uint256 constant EDITION_SUPPLY = 100;

    function _eth(uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(address(0), price);
    }

    function setUp() public {
        mockVault = address(new MockAlignmentVault());

        vm.startPrank(owner);

        instance = new ERC1155Instance(
            "Test Collection",
            owner, // creator
            owner, // factory = owner so owner can call factory-gated fns
            mockVault,
            "", // styleUri
            ERC1155Instance.InstanceInit({
                protocolTreasury: protocolTreasury,
                protocolFeeBps: 100,
                alignmentBps: 1900,
                gatingModule: address(0),
                dynamicPricingModule: address(0),
                weth: address(0xBEEF),
                registry: address(0x4E61), // ETH only: never consulted
                acceptedTokens: new address[](1)
            })
        );

        // Add a limited edition (supply = 100)
        instance.addEdition(
            "Limited Piece",
            _eth(0.01 ether),
            EDITION_SUPPLY,
            "ipfs://limited",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0,
            0
        );

        // Add an unlimited edition
        instance.addEdition(
            "Open Piece",
            _eth(0.005 ether),
            0,
            "ipfs://open",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0
        );

        vm.stopPrank();

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));
        actors.push(address(0xDEAD));

        handler = new ERC1155EditionHandler(instance, actors);

        targetContract(address(handler));
    }

    // ── Invariant 1: edition.minted <= edition.supply for limited editions ──

    function invariant_mintedNeverExceedsMaxSupply() public view {
        uint256 editionCount = instance.nextEditionId() - 1;
        for (uint256 i = 1; i <= editionCount; i++) {
            (,, uint256 supply, uint256 minted,,,,) = instance.editions(i);
            if (supply > 0) {
                assertLe(
                    minted,
                    supply,
                    "edition.minted exceeds edition.supply"
                );
            }
        }
    }

    // ── Invariant 2: sum(balanceOf(users, editionId)) == edition.minted ──

    function invariant_balanceSumEqualsMinted() public view {
        uint256 editionCount = instance.nextEditionId() - 1;
        address[] memory actorList = handler.getActors();

        for (uint256 i = 1; i <= editionCount; i++) {
            (,,, uint256 minted,,,,) = instance.editions(i);

            uint256 balanceSum = 0;
            for (uint256 j = 0; j < actorList.length; j++) {
                balanceSum += instance.balanceOf(actorList[j], i);
            }

            assertEq(
                balanceSum,
                minted,
                "sum(balanceOf) != edition.minted"
            );
        }
    }
}
