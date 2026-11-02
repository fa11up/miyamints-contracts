// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Factory} from "../../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC1155Instance} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import {MiyaRegistry} from "../../../src/registry/MiyaRegistry.sol";
import {IMiyaRegistry} from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";
import {FreeMintDisabled, FreeMintAlreadyClaimed, FreeMintExhausted, EditionNotOpen, EditionNotFound, LengthMismatch, RenounceDisabled} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import {MiyaPool} from "../../../src/pools/MiyaPool.sol";
import {MiyaPoolFactory} from "../../../src/pools/MiyaPoolFactory.sol";
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract MockVaultERC1155FM {
    function supportsCapability(bytes32) external pure returns (bool) { return true; }
    receive() external payable {}
}

contract ERC1155FreeMintTest is Test {
    ERC1155Factory factory;
    MiyaRegistry registry;
    MockVaultERC1155FM mockVault;

    uint256 internal _saltCounter;

    address protocol = makeAddr("protocol");
    address creator  = makeAddr("creator");
    address user1    = makeAddr("user1");
    address user2    = makeAddr("user2");

    uint256 constant FREE_ALLOC = 5;

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function setUp() public {
        vm.startPrank(protocol);
        vm.etch(CREATEX, CREATEX_BYTECODE);
        registry = new MiyaRegistry(protocol, makeAddr("treasury"), 100, 1000);
        mockVault    = new MockVaultERC1155FM();

        factory = new ERC1155Factory(IMiyaRegistry(address(registry)), address(0xBEEF));
        registry.setFactory(address(factory), true);
        registry.setVaultFactory(protocol, true);
        registry.registerVault(address(mockVault));
        vm.stopPrank();
    }

    function _deploy(uint256 alloc, GatingScope scope) internal returns (ERC1155Instance) {
        vm.startPrank(creator);
        address inst = factory.createInstance(
            _nextSalt(),
            ERC1155Factory.CreateParams({
                name: "FreeMintEdition",
                metadataURI: "ipfs://meta",
                creator: creator,
                vault: address(mockVault),
                alignmentBps: 1900,
                styleUri: "",
                gatingModule: address(0),
                freeMint: FreeMintParams({allocation: alloc, scope: scope})
            })
        );
        vm.stopPrank();
        return ERC1155Instance(payable(inst));
    }

    function _addEdition(ERC1155Instance inst, uint256 supply) internal returns (uint256 editionId) {
        vm.prank(creator);
        inst.addEdition(
            "Piece 1", 0.01 ether, supply, "ipfs://edition",
            ERC1155Instance.PricingModel.LIMITED_FIXED, 0, 0
        );
        return inst.nextEditionId() - 1;
    }

    // ── allocation stored ─────────────────────────────────────────────────────

    function test_erc1155_freeMintAllocationStored() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        assertEq(inst.freeMintAllocation(), FREE_ALLOC);
    }

    // ── claimFreeMint happy path ──────────────────────────────────────────────

    function test_erc1155_claimFreeMint_mintsOneToken() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);

        vm.prank(user1);
        inst.claimFreeMint(editionId, "");

        assertEq(inst.balanceOf(user1, editionId), 1);
        assertEq(inst.freeMintsClaimed(), 1);
        assertTrue(inst.freeMintClaimed(user1));
    }

    // ── reverts ───────────────────────────────────────────────────────────────

    function test_erc1155_freeMint_revertsWhenDisabled() public {
        ERC1155Instance inst = _deploy(0, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1);
        vm.expectRevert(FreeMintDisabled.selector);
        inst.claimFreeMint(editionId, "");
    }

    function test_erc1155_freeMint_revertsWhenAlreadyClaimed() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1); inst.claimFreeMint(editionId, "");
        vm.prank(user1);
        vm.expectRevert(FreeMintAlreadyClaimed.selector);
        inst.claimFreeMint(editionId, "");
    }

    function test_erc1155_freeMint_revertsWhenExhausted() public {
        ERC1155Instance inst = _deploy(1, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1); inst.claimFreeMint(editionId, "");
        vm.prank(user2);
        vm.expectRevert(FreeMintExhausted.selector);
        inst.claimFreeMint(editionId, "");
    }

    // ── claimFreeMint respects openTime (audit Low) ───────────────────────────

    function test_erc1155_freeMint_revertsBeforeOpenTime() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 openAt = block.timestamp + 1 days;
        vm.prank(creator);
        inst.addEdition(
            "Timed", 0.01 ether, 100, "ipfs://timed", ERC1155Instance.PricingModel.LIMITED_FIXED, 0, openAt
        );
        uint256 editionId = inst.nextEditionId() - 1;

        vm.prank(user1);
        vm.expectRevert(EditionNotOpen.selector);
        inst.claimFreeMint(editionId, "");

        vm.warp(openAt);
        vm.prank(user1);
        inst.claimFreeMint(editionId, "");
        assertEq(inst.balanceOf(user1, editionId), 1);
    }

    // ── ERC165 / ERC1155 surface (audit M7) ───────────────────────────────────

    function test_erc1155_supportsInterface() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        assertTrue(inst.supportsInterface(0x01ffc9a7), "ERC165");
        assertTrue(inst.supportsInterface(0xd9b67a26), "ERC1155");
        assertTrue(inst.supportsInterface(0x0e89341c), "ERC1155MetadataURI");
        assertFalse(inst.supportsInterface(0x80ac58cd), "not ERC721");
        assertFalse(inst.supportsInterface(0xffffffff), "ERC165 invalid id");
    }

    function test_erc1155_uriAndBalanceOfBatch() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        assertEq(inst.uri(editionId), "ipfs://edition");
        vm.expectRevert(EditionNotFound.selector);
        inst.uri(999);

        vm.prank(user1);
        inst.claimFreeMint(editionId, "");
        address[] memory accounts = new address[](2);
        uint256[] memory ids = new uint256[](2);
        accounts[0] = user1;
        accounts[1] = user2;
        ids[0] = editionId;
        ids[1] = editionId;
        uint256[] memory bals = inst.balanceOfBatch(accounts, ids);
        assertEq(bals[0], 1);
        assertEq(bals[1], 0);

        vm.expectRevert(LengthMismatch.selector);
        inst.balanceOfBatch(accounts, new uint256[](1));
    }

    function test_erc1155_miyaPoolCanBeCreatedAndDepositedInto() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        uint256 editionId = _addEdition(inst, 100);
        vm.prank(user1);
        inst.claimFreeMint(editionId, "");

        MiyaPoolFactory poolFactory = new MiyaPoolFactory();
        MiyaPool pool = MiyaPool(poolFactory.createPool(address(inst), MiyaPool.RedeemMode.TARGETED));
        assertEq(uint256(pool.kind()), uint256(MiyaPool.Kind.ERC1155));

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = editionId;
        amounts[0] = 1;
        vm.startPrank(user1);
        inst.setApprovalForAll(address(pool), true);
        pool.deposit(ids, amounts, user1);
        vm.stopPrank();
        assertEq(inst.balanceOf(address(pool), editionId), 1);
        assertEq(pool.balanceOf(user1), 1e18);
    }

    function test_erc1155_renounceOwnershipDisabled() public {
        ERC1155Instance inst = _deploy(FREE_ALLOC, GatingScope.BOTH);
        vm.prank(creator);
        vm.expectRevert(RenounceDisabled.selector);
        inst.renounceOwnership();
    }
}
