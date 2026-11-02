// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { CREATEX } from "../../src/shared/CreateXConstants.sol";
import { CREATEX_BYTECODE } from "createx-forge/script/CreateX.d.sol";
import { MiyaRegistry } from "../../src/registry/MiyaRegistry.sol";
import { IMiyaRegistry } from "../../src/registry/interfaces/IMiyaRegistry.sol";
import { ERC721DropFactory } from "../../src/factories/erc721drop/ERC721DropFactory.sol";
import { ERC721DropInstance } from "../../src/factories/erc721drop/ERC721DropInstance.sol";
import { UniAlignmentVault } from "../../src/vaults/uni/UniAlignmentVault.sol";
import { UniAlignmentVaultFactory } from "../../src/vaults/uni/UniAlignmentVaultFactory.sol";
import { IVaultPriceValidator } from "../../src/interfaces/IVaultPriceValidator.sol";
import { MockEXECToken } from "../mocks/MockEXECToken.sol";
import { MockZRouter } from "../mocks/MockZRouter.sol";
import { MockVaultPriceValidator } from "../mocks/MockVaultPriceValidator.sol";

/// @notice ERC721 drop launched through a real MiyaRegistry and a real registered alignment vault.
contract MiyaDropLaunchTest is Test {
    MiyaRegistry registry;
    UniAlignmentVaultFactory vaultFactory;
    ERC721DropFactory dropFactory;
    address vault;

    address dao = makeAddr("dao");
    address treasury = makeAddr("treasury");
    address artist = makeAddr("artist");
    address buyer = makeAddr("buyer");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);
        MockEXECToken token = new MockEXECToken(1_000_000e18);
        registry = new MiyaRegistry(dao, treasury, 100, 1000);
        vaultFactory = new UniAlignmentVaultFactory(
            weth,
            makeAddr("poolManager"),
            address(new MockZRouter()),
            3000,
            60,
            IVaultPriceValidator(address(new MockVaultPriceValidator())),
            IMiyaRegistry(address(registry))
        );
        dropFactory = new ERC721DropFactory(IMiyaRegistry(address(registry)), weth);

        vm.startPrank(dao);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        registry.addTarget("Remilia", tokens);
        registry.setVaultFactory(address(vaultFactory), true);
        registry.setFactory(address(dropFactory), true);
        vm.stopPrank();

        bytes32 salt = bytes32(abi.encodePacked(address(vaultFactory), uint8(0x00), bytes11(uint88(1))));
        vault = vaultFactory.deployVault(salt, address(token), 0, IVaultPriceValidator(address(0)));
        vm.deal(buyer, 100 ether);
    }

    function _launch(uint16 alignmentBps) internal returns (ERC721DropInstance d) {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0] = ERC721DropInstance.Phase(uint64(block.timestamp), 0, 0.1 ether, 0, bytes32(0));
        ERC721DropInstance.InitParams memory p;
        p.name = "miyamaker";
        p.symbol = "MIYA";
        p.maxSupply = 1000;
        p.unrevealedURI = "ar://unrevealed.json";
        p.phases = phases;
        vm.prank(artist);
        d = ERC721DropInstance(payable(dropFactory.createDrop(p, vault, alignmentBps)));
    }

    function test_dropSplitsIntoRealVault() public {
        ERC721DropInstance d = _launch(2000);
        assertEq(registry.vaultOf(address(d)), vault);
        assertEq(registry.factoryOf(address(d)), address(dropFactory));

        vm.prank(buyer);
        d.mint{ value: 1 ether }(0, 10, new bytes32[](0));
        d.withdraw();

        assertEq(treasury.balance, 0.01 ether, "1% protocol");
        assertEq(UniAlignmentVault(payable(vault)).pendingETH(address(d)), 0.2 ether, "20% alignment, drop is benefactor");
        assertEq(artist.balance, 0.79 ether, "artist remainder");
    }

    function test_registryChangesDoNotReachLaunchedDrop() public {
        ERC721DropInstance d = _launch(1000);
        address newTreasury = makeAddr("newTreasury");
        vm.startPrank(dao);
        registry.setFees(500, 3000);
        registry.setTreasury(newTreasury);
        vm.stopPrank();

        vm.prank(buyer);
        d.mint{ value: 1 ether }(0, 10, new bytes32[](0));
        d.withdraw();
        assertEq(treasury.balance, 0.01 ether);
        assertEq(newTreasury.balance, 0);
        assertEq(artist.balance, 0.89 ether);
    }

    function test_unregisteredFactoryCannotRegister() public {
        ERC721DropFactory rogue = new ERC721DropFactory(IMiyaRegistry(address(registry)), weth);
        ERC721DropInstance.InitParams memory p;
        p.name = "x";
        p.symbol = "X";
        p.maxSupply = 1;
        vm.expectRevert(MiyaRegistry.NotFactory.selector);
        rogue.createDrop(p, vault, 1000);
    }

    function test_rejectsVaultNotFromRegisteredFactory() public {
        ERC721DropInstance.InitParams memory p;
        p.name = "x";
        p.symbol = "X";
        p.maxSupply = 1;
        vm.expectRevert(ERC721DropFactory.InvalidVault.selector);
        dropFactory.createDrop(p, artist, 1000);
    }
}
