// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IMiyaRegistry } from "../../src/registry/interfaces/IMiyaRegistry.sol";
import { TokenPrice } from "../../src/factories/interfaces/TokenPrice.sol";
import { FreeMintParams } from "../../src/interfaces/IFactoryTypes.sol";
import { GatingScope } from "../../src/gating/IGatingModule.sol";
import { ERC721DropFactory } from "../../src/factories/erc721drop/ERC721DropFactory.sol";
import { ERC721DropInstance } from "../../src/factories/erc721drop/ERC721DropInstance.sol";
import { ERC1155Factory } from "../../src/factories/erc1155/ERC1155Factory.sol";
import { ERC1155Instance } from "../../src/factories/erc1155/ERC1155Instance.sol";
import { DynamicPricingModule } from "../../src/factories/erc1155/DynamicPricingModule.sol";
import { ERC721AuctionFactory } from "../../src/factories/erc721/ERC721AuctionFactory.sol";
import { ERC721AuctionInstance } from "../../src/factories/erc721/ERC721AuctionInstance.sol";
import { VaultTestBase } from "../vaults/VaultTestBase.sol";

/// @notice Each collection type selling in USDC into a REAL vault (TestableUniAlignmentVault on a real MiyaRegistry and
///         vault factory; only the alignment pool is simulated), not MockVaultV2: the cut arrives and converts; a refusal
///         by the real vault (token dropped from the registry allowlist, or a cut under the factory's per-token minimum)
///         parks the cut and leaves no allowance behind; a later flush succeeds.
contract RealVaultErc20Test is VaultTestBase {
    ERC721DropFactory dropFactory;
    ERC1155Factory editionFactory;
    ERC721AuctionFactory auctionFactory;
    address artist = makeAddr("artist");
    address weth = makeAddr("weth");
    uint256 salt;

    uint16 constant ALIGN = 1500; // 1% protocol, 15% vault, 84% artist

    function setUp() public override {
        super.setUp();
        dropFactory = new ERC721DropFactory(IMiyaRegistry(address(registry)), weth);
        editionFactory = new ERC1155Factory(IMiyaRegistry(address(registry)), weth);
        auctionFactory = new ERC721AuctionFactory(IMiyaRegistry(address(registry)), weth);
        DynamicPricingModule module = new DynamicPricingModule();
        registry.setComponent(address(module), true);
        editionFactory.setDynamicPricingModule(address(module));
        registry.setFactory(address(dropFactory), true);
        registry.setFactory(address(editionFactory), true);
        registry.setFactory(address(auctionFactory), true);
        // The test vault is a plain clone: register it as its factory would.
        vm.prank(address(factory));
        registry.registerVault(address(vault));
        factory.setMinContribution(USDC_ADDR, 2e6); // as deployed: ~0.001 ETH
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(artist, 1_000_000e6);
    }

    function _usdcOnly() internal pure returns (address[] memory t) {
        t = new address[](1);
        t[0] = USDC_ADDR;
    }

    function _price(uint256 p) internal pure returns (TokenPrice[] memory a) {
        a = new TokenPrice[](1);
        a[0] = TokenPrice(USDC_ADDR, p);
    }

    function _approveUsdc(address who, address spender) internal {
        vm.prank(who);
        usdc.approve(spender, type(uint256).max);
    }

    /// @dev The cut reached the vault, credited to the collection, and converts into shares for it.
    function _assertArrivedAndConverts(address collection, uint256 cut) internal {
        assertEq(vault.pendingOf(collection, USDC_ADDR), cut, "cut credited to the collection");
        assertEq(usdc.allowance(collection, address(vault)), 0, "no allowance left");
        _convert();
        assertGt(vault.benefactorShares(collection), 0, "the collection holds shares");
        assertEq(vault.pendingOf(collection, USDC_ADDR), 0);
        _assertSolvent(vault);
    }

    // ── drop ────────────────────────────────────────────────────────────────

    function _drop() internal returns (ERC721DropInstance d) {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0].start = uint64(block.timestamp);
        phases[0].prices = _price(100e6);
        ERC721DropInstance.InitParams memory p;
        p.name = "usdc drop";
        p.symbol = "UD";
        p.maxSupply = 100;
        p.acceptedTokens = _usdcOnly();
        p.phases = phases;
        vm.prank(artist);
        d = ERC721DropInstance(payable(dropFactory.createDrop(p, address(vault), ALIGN)));
    }

    function _mintDrop(ERC721DropInstance d, address who) internal {
        _approveUsdc(who, address(d));
        vm.prank(who);
        d.mint(0, 1, new bytes32[](0), USDC_ADDR, 100e6);
    }

    function test_drop_usdcCutArrivesAndConverts() public {
        ERC721DropInstance d = _drop();
        _mintDrop(d, alice);
        d.distribute(USDC_ADDR);
        assertEq(d.pendingVaultCut(USDC_ADDR), 0);
        _assertArrivedAndConverts(address(d), 15e6);
    }

    function test_drop_tokenDroppedFromRegistry_parksThenFlushes() public {
        ERC721DropInstance d = _drop();
        _mintDrop(d, alice);
        // The registry drops USDC after the sale: the real vault refuses the cut (TokenNotAllowed).
        registry.setPaymentToken(USDC_ADDR, false);
        d.distribute(USDC_ADDR);
        assertEq(d.pendingVaultCut(USDC_ADDR), 15e6, "parked");
        assertEq(usdc.allowance(address(d), address(vault)), 0, "allowance reset");
        assertEq(vault.pendingByToken(USDC_ADDR), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        // Allowed again: the flush goes through.
        registry.setPaymentToken(USDC_ADDR, true);
        d.flushPendingVaultCut(USDC_ADDR, 0);
        assertEq(d.pendingVaultCut(USDC_ADDR), 0);
        _assertArrivedAndConverts(address(d), 15e6);
    }

    // ── 1155 edition ────────────────────────────────────────────────────────

    function _edition(uint256 price) internal returns (ERC1155Instance inst) {
        ERC1155Factory.CreateParams memory p = ERC1155Factory.CreateParams({
            name: "usdc editions",
            metadataURI: "ipfs://c",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGN,
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }),
            acceptedTokens: _usdcOnly()
        });
        vm.prank(artist);
        inst = ERC1155Instance(payable(editionFactory.createInstance(bytes32(++salt), p)));
        vm.prank(artist);
        inst.addEdition("track", _price(price), 0, "ipfs://t", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
    }

    function _mintEdition(ERC1155Instance inst, address who) internal {
        uint256 cost = inst.calculateMintCost(1, 1, USDC_ADDR);
        _approveUsdc(who, address(inst));
        vm.prank(who);
        inst.mint(1, 1, bytes32(0), "", USDC_ADDR, cost);
    }

    function test_edition_usdcCutArrivesAndConverts() public {
        ERC1155Instance inst = _edition(20e6);
        _mintEdition(inst, alice);
        inst.distribute(USDC_ADDR);
        _assertArrivedAndConverts(address(inst), 3e6);
    }

    function test_edition_cutBelowMinimum_parksThenFlushesWithTopUp() public {
        ERC1155Instance inst = _edition(10e6); // vault cut 1.5 USDC, under the 2 USDC minimum
        _mintEdition(inst, alice);
        inst.distribute(USDC_ADDR);
        assertEq(inst.pendingVaultCut(USDC_ADDR), 1.5e6, "parked: the real vault refused it (below minimum)");
        assertEq(usdc.allowance(address(inst), address(vault)), 0, "allowance reset");
        assertEq(vault.pendingByToken(USDC_ADDR), 0);
        // Anyone can top it up past the minimum.
        _approveUsdc(bob, address(inst));
        vm.prank(bob);
        inst.flushPendingVaultCut(USDC_ADDR, 0.5e6);
        assertEq(inst.pendingVaultCut(USDC_ADDR), 0);
        _assertArrivedAndConverts(address(inst), 2e6);
    }

    // ── auction ─────────────────────────────────────────────────────────────

    function _auction() internal returns (ERC721AuctionInstance a) {
        ERC721AuctionFactory.CreateParams memory p = ERC721AuctionFactory.CreateParams({
            name: "usdc 1/1",
            metadataURI: "ipfs://m",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGN,
            symbol: "U11",
            lines: 1,
            baseDuration: 1 hours,
            timeBuffer: 5 minutes,
            bidIncrement: 1e6,
            currency: USDC_ADDR
        });
        vm.prank(artist);
        a = ERC721AuctionInstance(payable(auctionFactory.createInstance(bytes32(++salt), p)));
    }

    function _sell(ERC721AuctionInstance a, uint256 bid) internal returns (uint24 id) {
        _approveUsdc(artist, address(a));
        vm.prank(artist);
        a.queuePiece("ar://piece", 5e6);
        id = a.nextTokenId() - 1;
        _approveUsdc(alice, address(a));
        vm.prank(alice);
        a.createBid(id, bid, "");
        vm.warp(block.timestamp + 1 hours);
        a.settleAuction(id);
    }

    function test_auction_usdcCutArrivesAndConverts() public {
        ERC721AuctionInstance a = _auction();
        _sell(a, 100e6);
        assertEq(a.pendingVaultCut(USDC_ADDR), 0);
        _assertArrivedAndConverts(address(a), 15e6);
    }

    function test_auction_cutBelowMinimum_parksThenFlushes() public {
        ERC721AuctionInstance a = _auction();
        factory.setMinContribution(USDC_ADDR, 50e6); // the Safe raises the minimum above this sale's cut
        _sell(a, 100e6);
        assertEq(a.pendingVaultCut(USDC_ADDR), 15e6, "parked");
        assertEq(usdc.allowance(address(a), address(vault)), 0, "allowance reset");
        assertEq(vault.pendingByToken(USDC_ADDR), 0);
        factory.setMinContribution(USDC_ADDR, 2e6);
        a.flushPendingVaultCut(USDC_ADDR, 0);
        assertEq(a.pendingVaultCut(USDC_ADDR), 0);
        _assertArrivedAndConverts(address(a), 15e6);
    }
}
