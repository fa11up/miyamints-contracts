// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Instance} from "../../../src/factories/erc1155/ERC1155Instance.sol";

/// @notice Invariant handler for ERC1155Instance edition accounting
contract ERC1155EditionHandler is Test {
    ERC1155Instance public instance;

    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost variables for balance tracking
    // ghost_balances[editionId][actor] mirrors expected balanceOf
    mapping(uint256 => mapping(address => uint256)) public ghost_balances;

    uint256 public ghost_mintCount;
    uint256 public ghost_transferCount;

    constructor(ERC1155Instance _instance, address[] memory _actors) {
        instance = _instance;
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
            isActor[_actors[i]] = true;
        }
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice Mint tokens for a random actor on a random edition
    function mint(uint256 actorSeed, uint256 editionSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 editionCount = instance.nextEditionId() - 1;
        if (editionCount == 0) return;
        uint256 editionId = (editionSeed % editionCount) + 1;

        amount = bound(amount, 1, 10);

        // Check supply limit for limited editions
        (,,, uint256 supply, uint256 minted,,,,) = instance.editions(editionId);
        if (supply > 0 && minted + amount > supply) return;

        uint256 cost = instance.calculateMintCost(editionId, amount);

        vm.deal(actor, actor.balance + cost);
        vm.prank(actor);
        instance.mint{value: cost}(editionId, amount, bytes32(0), "", 0);

        ghost_balances[editionId][actor] += amount;
        ghost_mintCount++;
    }

    /// @notice Transfer tokens between random actors
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 editionSeed, uint256 amount) external {
        address from = _getActor(fromSeed);
        address to = _getActor(toSeed);
        if (from == to) return;

        uint256 editionCount = instance.nextEditionId() - 1;
        if (editionCount == 0) return;
        uint256 editionId = (editionSeed % editionCount) + 1;

        uint256 balance = instance.balanceOf(from, editionId);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);

        vm.prank(from);
        instance.safeTransferFrom(from, to, editionId, amount, "");

        ghost_balances[editionId][from] -= amount;
        ghost_balances[editionId][to] += amount;
        ghost_transferCount++;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}
