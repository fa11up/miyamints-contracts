// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployMarketsTestnet } from "../../script/markets/DeployMarketsTestnet.s.sol";
import { PredictionRegistry } from "../../src/markets/PredictionRegistry.sol";

contract DeployScriptTest is Test {
    function test_script_wiresTheSystem() public {
        vm.chainId(11155111);
        DeployMarketsTestnet s = new DeployMarketsTestnet();
        DeployMarketsTestnet.Deployed memory d = s.run();
        PredictionRegistry.Config memory c = d.registry.config();
        assertEq(d.registry.factory(), address(d.factory));
        assertEq(c.door, address(d.door));
        assertEq(c.eligibility, address(d.gate));
        assertEq(c.exitDesk, address(d.desk));
        assertEq(c.disputeModule, address(d.disputes));
        assertEq(c.disputeResolver, address(d.dispute));
        assertEq(c.council, address(d.council));
        assertTrue(d.registry.isResolverAllowed(address(d.primary)));
        assertEq(d.registry.templateCount(), 2);
        assertEq(d.registry.rakeBps(), 250);
        assertEq(c.lockMargin, 180);
        assertEq(d.primary.attester(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        assertEq(d.desk.capacity(), 25_000e18);
        assertEq(d.registry.openInterestRoom(), 25_000e18);
    }

    function test_script_refusesMainnets() public {
        DeployMarketsTestnet s = new DeployMarketsTestnet();
        vm.chainId(1);
        vm.expectRevert(bytes("NOT FOR MAINNET"));
        s.run();
        vm.chainId(4663);
        vm.expectRevert(bytes("NOT FOR MAINNET"));
        s.run();
    }
}
