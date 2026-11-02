// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DynamicPricingModule} from "../../../src/factories/erc1155/DynamicPricingModule.sol";
import {IComponentModule} from "../../../src/interfaces/IComponentModule.sol";

contract DynamicPricingModuleTest is Test {
    DynamicPricingModule module;
    address owner = address(0xA11CE);

    function setUp() public {
        vm.prank(owner);
        module = new DynamicPricingModule();
    }

    // ── calculatePrice ───────────────────────────────────────────────────────

    function test_calculatePrice_zeroMinted_returnsBasePrice() public view {
        uint256 price = module.calculatePrice(1 ether, 100, 0);
        assertEq(price, 1 ether);
    }

    function test_calculatePrice_zeroRate_returnsBasePrice() public view {
        uint256 price = module.calculatePrice(1 ether, 0, 10);
        assertEq(price, 1 ether);
    }

    function test_calculatePrice_onePercent_oneMinted() public view {
        // price = 1 ether * 1.01^1 = 1.01 ether
        uint256 price = module.calculatePrice(1 ether, 100, 1);
        assertApproxEqRel(price, 1.01 ether, 1e14); // 0.01% tolerance
    }

    function test_calculatePrice_onePercent_tenMinted() public view {
        // price = 1 ether * 1.01^10 ≈ 1.10462 ether
        uint256 price = module.calculatePrice(1 ether, 100, 10);
        assertApproxEqRel(price, 1.10462212541120451 ether, 1e14);
    }

    function test_calculatePrice_neverBelowBasePrice() public view {
        uint256 price = module.calculatePrice(0.01 ether, 50, 5);
        assertGe(price, 0.01 ether);
    }

    // ── calculateBatchCost ───────────────────────────────────────────────────

    function test_calculateBatchCost_zeroRate_isLinear() public view {
        uint256 cost = module.calculateBatchCost(1 ether, 0, 0, 5);
        assertEq(cost, 5 ether);
    }

    function test_calculateBatchCost_matchesSumOfIndividualPrices() public view {
        uint256 basePrice = 0.1 ether;
        uint256 rate = 100; // 1%
        uint256 startMinted = 0;
        uint256 amount = 3;

        // Sum individual prices: p0 + p1 + p2
        uint256 manual = 0;
        for (uint256 i = 0; i < amount; i++) {
            manual += module.calculatePrice(basePrice, rate, startMinted + i);
        }

        uint256 batch = module.calculateBatchCost(basePrice, rate, startMinted, amount);
        assertApproxEqRel(batch, manual, 1e13); // 0.001% tolerance for rounding
    }

    function test_calculateBatchCost_startMinted_offsetsCorrectly() public view {
        uint256 costFrom0 = module.calculateBatchCost(1 ether, 100, 0, 5);
        uint256 costFrom5 = module.calculateBatchCost(1 ether, 100, 5, 5);
        // Second batch starts at higher price, should cost more
        assertGt(costFrom5, costFrom0);
    }

    // ── IComponentModule ─────────────────────────────────────────────────────

    function test_metadataURI_defaultEmpty() public view {
        assertEq(module.metadataURI(), "");
    }

    function test_setMetadataURI_ownerCanSet() public {
        vm.prank(owner);
        module.setMetadataURI("ipfs://Qm123");
        assertEq(module.metadataURI(), "ipfs://Qm123");
    }

    function test_setMetadataURI_nonOwnerReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        module.setMetadataURI("ipfs://Qm123");
    }

    function test_setMetadataURI_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit IComponentModule.MetadataURIUpdated("ipfs://Qm123");
        module.setMetadataURI("ipfs://Qm123");
    }
}
