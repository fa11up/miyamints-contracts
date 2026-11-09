// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, Vm } from "forge-std/Test.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ERC721DropInstance } from "../../../src/factories/erc721drop/ERC721DropInstance.sol";
import { ERC721DropFactory } from "../../../src/factories/erc721drop/ERC721DropFactory.sol";
import { IMiyaRegistry } from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import { ClaimMode } from "../../../src/interfaces/IAlignmentVault.sol";
import { PaymentLib } from "../../../src/libraries/PaymentLib.sol";
import { TokenPrice } from "../../../src/factories/interfaces/TokenPrice.sol";

/// @dev Minimal stand-in exposing only what the drop factory reads, with the production fee rules.
contract DropTestRegistry {
    address public treasury;
    uint16 public protocolFeeBps = 100;
    uint16 public minAlignmentBps = 1000;
    mapping(address => bool) public isVault;
    mapping(address => address) public vaultOf;

    error InvalidAlignment();

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function setVault(address v, bool ok) external {
        isVault[v] = ok;
    }

    function setFees(uint16 p, uint16 m) external {
        protocolFeeBps = p;
        minAlignmentBps = m;
    }

    function checkAlignmentBps(uint16 a) external view {
        if (a < minAlignmentBps || uint256(a) + protocolFeeBps > 10_000) revert InvalidAlignment();
    }

    function registerInstance(address instance, address vault, address) external {
        vaultOf[instance] = vault;
    }

    function isPaymentToken(address token) external pure returns (bool) {
        return token == address(0);
    }
}

contract DropTestVault {
    bool public rejecting;
    uint256 public received;
    mapping(address => uint256) public credited;
    uint256 public feesToPay;

    function setRejecting(bool r) external {
        rejecting = r;
    }

    function setFees(uint256 f) external payable {
        feesToPay = f;
    }

    function receiveContribution(Currency, uint256 amount, address benefactor) external payable {
        require(!rejecting, "rejecting");
        require(msg.value == amount, "value");
        received += amount;
        credited[benefactor] += amount;
    }

    function claimFees(ClaimMode, uint256) external returns (uint256, uint256, uint256 f) {
        f = feesToPay;
        feesToPay = 0;
        (bool ok,) = msg.sender.call{ value: f }("");
        require(ok);
    }
}

contract ERC721DropTest is Test {
    DropTestRegistry registry;
    DropTestVault vault;
    ERC721DropFactory factory;
    address treasury = makeAddr("treasury");
    address artist = makeAddr("artist");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint128 constant PRICE = 0.05 ether;

    function setUp() public {
        registry = new DropTestRegistry(treasury);
        vault = new DropTestVault();
        registry.setVault(address(vault), true);
        factory = new ERC721DropFactory(IMiyaRegistry(address(registry)), address(0));
        vm.warp(1_000_000);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _leaf(address a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Read by `_params` and `_drop`; set these before `_drop` to vary them.
    uint32 reserve;
    uint32 phaseZeroCap;

    function _params(ERC721DropInstance.Phase[] memory phases, uint32 maxSupply)
        internal
        view
        returns (ERC721DropInstance.InitParams memory p)
    {
        p.name = "miyamaker";
        p.symbol = "MIYA";
        p.maxSupply = maxSupply;
        p.ownerReserve = reserve;
        p.unrevealedURI = "ar://unrevealed.json";
        p.contractURI = "ar://contract.json";
        p.royaltyReceiver = artist;
        p.royaltyBps = 500;
        p.acceptedTokens = new address[](1); // ETH
        p.phases = phases;
    }

    /// @dev Phase 0: allowlist (alice, bob), 2 per wallet, 0.03 ETH. Phase 1: public, 0.05 ETH, unlimited.
    function _drop(uint32 maxSupply, uint16 alignmentBps) internal returns (ERC721DropInstance d) {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](2);
        phases[0] = ERC721DropInstance.Phase({
            start: uint64(block.timestamp),
            end: uint64(block.timestamp + 1 days),
            prices: _eth(0.03 ether),
            maxPerWallet: 2,
            merkleRoot: _pair(_leaf(alice), _leaf(bob)),
            supplyCap: phaseZeroCap
        });
        phases[1] = ERC721DropInstance.Phase({
            start: uint64(block.timestamp + 1 days),
            end: 0,
            prices: _eth(PRICE),
            maxPerWallet: 0,
            merkleRoot: bytes32(0),
            supplyCap: 0
        });
        vm.prank(artist);
        d = ERC721DropInstance(payable(factory.createDrop(_params(phases, maxSupply), address(vault), alignmentBps)));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _noProof() internal pure returns (bytes32[] memory p) { }

    function _eth(uint256 price) internal pure returns (TokenPrice[] memory p) {
        p = new TokenPrice[](1);
        p[0] = TokenPrice(address(0), price);
    }

    /// @dev The old permissionless withdraw(): anyone splits (distribute), then the owner collects its share.
    function _withdraw(ERC721DropInstance d) internal {
        d.distribute(address(0));
        if (d.ownerBalance(address(0)) == 0) return; // e.g. 1% protocol + 99% alignment
        vm.prank(d.owner());
        d.withdraw(address(0));
    }

    // ── factory ──────────────────────────────────────────────────────────────

    function test_lifecycle_reportsTypeAndEntersMinting() public {
        vm.recordLogs();
        ERC721DropInstance d = _drop(10, 1000);
        assertEq(d.instanceType(), keccak256("erc721"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(d) && logs[i].topics[0] == keccak256("StateChanged(bytes32)")
                    && logs[i].topics[1] == keccak256("minting")
            ) seen = true;
        }
        assertTrue(seen);
    }

    function test_factory_snapshotsTerms() public {
        ERC721DropInstance d = _drop(100, 1500);
        assertEq(d.owner(), artist);
        assertEq(d.protocolBps(), 100);
        assertEq(d.alignmentBps(), 1500);
        assertEq(d.treasury(), treasury);
        assertEq(address(d.vault()), address(vault));
        assertEq(registry.vaultOf(address(d)), address(vault));
        assertEq(d.name(), "miyamaker");
        assertEq(d.maxSupply(), 100);
    }

    function test_factory_rejectsUnregisteredVault() public {
        ERC721DropInstance.Phase[] memory none;
        vm.expectRevert(ERC721DropFactory.InvalidVault.selector);
        factory.createDrop(_params(none, 10), makeAddr("fakeVault"), 1000);
    }

    function test_factory_enforcesMinimumAlignment() public {
        ERC721DropInstance.Phase[] memory none;
        vm.expectRevert(DropTestRegistry.InvalidAlignment.selector);
        factory.createDrop(_params(none, 10), address(vault), 999);
        vm.expectRevert(DropTestRegistry.InvalidAlignment.selector);
        factory.createDrop(_params(none, 10), address(vault), 9901);
        factory.createDrop(_params(none, 10), address(vault), 1000);
        factory.createDrop(_params(none, 10), address(vault), 9900);
    }

    function test_laterFeeChangesDoNotAffectExistingDrop() public {
        ERC721DropInstance d = _drop(100, 1000);
        registry.setFees(300, 2000);
        assertEq(d.protocolBps(), 100);
        assertEq(d.alignmentBps(), 1000);
    }

    // ── minting ──────────────────────────────────────────────────────────────

    function test_allowlistMint() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(alice);
        d.mint{ value: 0.06 ether }(0, 2, _proof(_leaf(bob)), address(0), 0);
        assertEq(d.balanceOf(alice), 2);
        assertEq(d.ownerOf(1), alice);
        assertEq(d.ownerOf(2), alice);
        assertEq(d.totalSupply(), 2);
        assertEq(d.mintedInPhase(0, alice), 2);
    }

    function test_allowlistRejectsOutsiders() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(carol);
        vm.expectRevert(ERC721DropInstance.NotAllowlisted.selector);
        d.mint{ value: 0.03 ether }(0, 1, _proof(_leaf(bob)), address(0), 0);
    }

    function test_walletLimit() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.startPrank(alice);
        d.mint{ value: 0.03 ether }(0, 1, _proof(_leaf(bob)), address(0), 0);
        vm.expectRevert(ERC721DropInstance.WalletLimit.selector);
        d.mint{ value: 0.06 ether }(0, 2, _proof(_leaf(bob)), address(0), 0);
        vm.stopPrank();
    }

    function test_phaseWindows() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(carol);
        vm.expectRevert(ERC721DropInstance.PhaseNotActive.selector);
        d.mint{ value: PRICE }(1, 1, _noProof(), address(0), 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(ERC721DropInstance.PhaseNotActive.selector);
        d.mint{ value: 0.03 ether }(0, 1, _proof(_leaf(bob)), address(0), 0);

        vm.prank(carol);
        d.mint{ value: PRICE * 5 }(1, 5, _noProof(), address(0), 0);
        assertEq(d.balanceOf(carol), 5);

        vm.expectRevert(ERC721DropInstance.PhaseNotActive.selector);
        d.mint{ value: PRICE }(7, 1, _noProof(), address(0), 0);
    }

    function test_exactPaymentRequired() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(carol);
        vm.expectRevert(ERC721DropInstance.WrongPayment.selector);
        d.mint{ value: PRICE - 1 }(1, 1, _noProof(), address(0), 0);
        vm.expectRevert(ERC721DropInstance.WrongPayment.selector);
        d.mint{ value: PRICE + 1 }(1, 1, _noProof(), address(0), 0);
        vm.stopPrank();
    }

    function test_soldOut() public {
        ERC721DropInstance d = _drop(3, 1000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 2 }(1, 2, _noProof(), address(0), 0);
        vm.prank(bob);
        vm.expectRevert(ERC721DropInstance.SoldOut.selector);
        d.mint{ value: PRICE * 2 }(1, 2, _noProof(), address(0), 0);
        vm.prank(bob);
        d.mint{ value: PRICE }(1, 1, _noProof(), address(0), 0);
        assertEq(d.totalSupply(), 3);
    }

    function test_zeroQuantityReverts() public {
        ERC721DropInstance d = _drop(3, 1000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        vm.expectRevert(ERC721DropInstance.InvalidParams.selector);
        d.mint(1, 0, _noProof(), address(0), 0);
    }

    function test_ownerMintLimitedToReserve() public {
        reserve = 5;
        ERC721DropInstance d = _drop(5, 1000);
        vm.prank(artist);
        d.ownerMint(bob, 4);
        assertEq(d.balanceOf(bob), 4);
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.ReserveExceeded.selector);
        d.ownerMint(bob, 2);
        vm.prank(alice);
        vm.expectRevert();
        d.ownerMint(alice, 1);
    }

    // ── proceeds ─────────────────────────────────────────────────────────────

    function test_withdrawSplitsOnePercentChosenAlignmentRestToArtist() public {
        ERC721DropInstance d = _drop(100, 1500);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0); // 1 ether

        vm.prank(makeAddr("anyone"));
        _withdraw(d);

        assertEq(treasury.balance, 0.01 ether, "protocol 1%");
        assertEq(vault.received(), 0.15 ether, "alignment 15%");
        assertEq(vault.credited(address(d)), 0.15 ether, "credited to the collection");
        assertEq(artist.balance, 0.84 ether, "artist remainder");
        assertEq(address(d).balance, 0);

        vm.expectRevert(ERC721DropInstance.NothingToWithdraw.selector);
        d.distribute(address(0));
    }

    function test_parkedVaultCutGoesWithTheNextSplit() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE }(1, 1, new bytes32[](0), address(0), 0);
        vault.setRejecting(true);
        _withdraw(d);
        uint256 parked = d.pendingVaultCut(address(0));
        assertGt(parked, 0);

        vault.setRejecting(false);
        vm.prank(carol);
        d.mint{ value: PRICE }(1, 1, new bytes32[](0), address(0), 0);
        _withdraw(d);
        assertEq(d.pendingVaultCut(address(0)), 0);
        assertEq(vault.received(), parked * 2);
    }

    function test_rejectedVaultCutIsParkedNotRedirected() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0);

        vault.setRejecting(true);
        _withdraw(d);
        assertEq(d.pendingVaultCut(address(0)), 0.1 ether);
        assertEq(artist.balance, 0.89 ether);
        assertEq(address(d).balance, 0.1 ether);

        // a second withdraw does not touch the parked cut
        vm.expectRevert(ERC721DropInstance.NothingToWithdraw.selector);
        d.distribute(address(0));

        vault.setRejecting(false);
        d.flushPendingVaultCut(address(0), 0);
        assertEq(vault.received(), 0.1 ether);
        assertEq(d.pendingVaultCut(address(0)), 0);
        assertEq(address(d).balance, 0);
    }

    function test_flushPendingVaultCut_topUpGoesToTheVaultForTheDrop() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE }(1, 1, _noProof(), address(0), 0);
        vault.setRejecting(true);
        _withdraw(d);
        uint256 parked = d.pendingVaultCut(address(0));
        assertGt(parked, 0);

        vault.setRejecting(false);
        vm.prank(bob);
        d.flushPendingVaultCut{ value: 0.001 ether }(address(0), 0.001 ether);
        assertEq(d.pendingVaultCut(address(0)), 0);
        assertEq(address(d).balance, 0);
        assertEq(vault.received(), parked + 0.001 ether);
        assertEq(vault.credited(address(d)), parked + 0.001 ether);
        assertEq(vault.credited(bob), 0);

        vm.prank(bob);
        vm.expectRevert(PaymentLib.NothingParked.selector);
        d.flushPendingVaultCut{ value: 0.001 ether }(address(0), 0.001 ether);
    }

    function test_claimVaultFeesGoesToOwner() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.deal(address(vault), 1 ether);
        vault.setFees(0.2 ether);
        vm.prank(artist);
        d.claimVaultFees(ClaimMode.TOKENS, 0);
        assertEq(artist.balance, 0.2 ether);
    }

    // ── metadata ─────────────────────────────────────────────────────────────

    function test_revealAndLock() public {
        reserve = 1;
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(artist);
        d.ownerMint(alice, 1);
        assertEq(d.tokenURI(1), "ar://unrevealed.json");

        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.InvalidParams.selector);
        d.lockMetadata();

        vm.prank(artist);
        d.setMetadata("ar://revealed/", "", "ar://contract.json");
        assertEq(d.tokenURI(1), "ar://revealed/1");

        vm.prank(artist);
        d.lockMetadata();
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.Locked.selector);
        d.setMetadata("ar://rug/", "", "");

        vm.expectRevert();
        d.tokenURI(2);
    }

    function test_royaltiesAndInterfaces() public {
        ERC721DropInstance d = _drop(100, 1000);
        (address receiver, uint256 amount) = d.royaltyInfo(1, 1 ether);
        assertEq(receiver, artist);
        assertEq(amount, 0.05 ether);
        assertTrue(d.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(d.supportsInterface(0x2a55205a)); // ERC2981
    }

    /// Audit Low: per-wallet counters belong to a phase list; a new list (setPhases) starts them fresh rather
    /// than applying old phase-0 mints to whatever the new phase 0 is.
    /// Phase 0 is [t, t + 1 day); phase 1 is [t + 1 day, forever).
    function test_isPhaseActive_trueInsideWindow() public {
        ERC721DropInstance d = _drop(100, 1000);
        uint256 t = block.timestamp;
        assertTrue(d.isPhaseActive(0), "phase 0 active at its start (inclusive)");
        vm.warp(t + 1 days - 1);
        assertTrue(d.isPhaseActive(0), "phase 0 active on its last second");
        vm.warp(t + 1 days);
        assertTrue(d.isPhaseActive(1), "phase 1 active at its start");
        vm.warp(t + 365 days);
        assertTrue(d.isPhaseActive(1), "end == 0 never closes");
    }

    function test_isPhaseActive_falseBeforeStartAtEndAndOutOfRange() public {
        ERC721DropInstance d = _drop(100, 1000);
        uint256 t = block.timestamp;
        assertFalse(d.isPhaseActive(1), "phase 1 before its start");
        vm.warp(t + 1 days);
        assertFalse(d.isPhaseActive(0), "phase 0 at its end (exclusive)");
        vm.warp(t + 2 days);
        assertFalse(d.isPhaseActive(0), "phase 0 after its end");
        assertFalse(d.isPhaseActive(2), "out-of-range id");
        assertFalse(d.isPhaseActive(type(uint256).max), "huge id");
    }

    function test_setPhasesResetsWalletCounters() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(alice);
        d.mint{ value: 0.06 ether }(0, 2, _proof(_leaf(bob)), address(0), 0);
        assertEq(d.mintedInPhase(0, alice), 2);

        ERC721DropInstance.Phase[] memory next = new ERC721DropInstance.Phase[](1);
        next[0] = ERC721DropInstance.Phase({
            start: uint64(block.timestamp),
            end: 0,
            prices: _eth(PRICE),
            maxPerWallet: 1,
            merkleRoot: bytes32(0),
            supplyCap: 0
        });
        vm.prank(artist);
        d.setPhases(next);
        assertEq(d.mintedInPhase(0, alice), 0, "counter scoped to the old phase list");

        vm.startPrank(alice);
        d.mint{ value: PRICE }(0, 1, _noProof(), address(0), 0);
        vm.expectRevert(ERC721DropInstance.WalletLimit.selector);
        d.mint{ value: PRICE }(0, 1, _noProof(), address(0), 0);
        vm.stopPrank();
    }

    /// Audit Low: renouncing would make owner() == address(0) and permissionless withdraw() burn the artist share.
    function test_renounceOwnershipDisabled() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.RenounceDisabled.selector);
        d.renounceOwnership();
    }

    function test_setPhasesValidation() public {
        ERC721DropInstance d = _drop(100, 1000);
        ERC721DropInstance.Phase[] memory bad = new ERC721DropInstance.Phase[](1);
        bad[0] = ERC721DropInstance.Phase(100, 50, 0, bytes32(0), 0, _eth(1));
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.InvalidParams.selector);
        d.setPhases(bad);

        ERC721DropInstance.Phase[] memory tooMany = new ERC721DropInstance.Phase[](9);
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.InvalidParams.selector);
        d.setPhases(tooMany);
    }

    // ── owner reserve ────────────────────────────────────────────────────────

    function _openPublic() internal {
        vm.warp(block.timestamp + 1 days);
        vm.deal(carol, 1000 ether);
    }

    function test_noReserveMeansNoOwnerMint() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.ReserveExceeded.selector);
        d.ownerMint(bob, 1);
    }

    function test_reserveAboveSupplyRejected() public {
        reserve = 11;
        ERC721DropInstance.Phase[] memory none;
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.InvalidParams.selector);
        factory.createDrop(_params(none, 10), address(vault), 1000);
    }

    function test_phasesCannotSellTheReserve() public {
        reserve = 3;
        ERC721DropInstance d = _drop(10, 1000);
        _openPublic();
        assertEq(d.publicRemaining(), 7);
        vm.startPrank(carol);
        vm.expectRevert(ERC721DropInstance.SoldOut.selector);
        d.mint{ value: PRICE * 8 }(1, 8, new bytes32[](0), address(0), 0);
        d.mint{ value: PRICE * 7 }(1, 7, new bytes32[](0), address(0), 0);
        vm.expectRevert(ERC721DropInstance.SoldOut.selector);
        d.mint{ value: PRICE }(1, 1, new bytes32[](0), address(0), 0);
        vm.stopPrank();
        assertEq(d.publicRemaining(), 0);

        vm.prank(artist);
        d.ownerMint(bob, 3);
        assertEq(d.totalSupply(), 10);
        assertEq(d.publicRemaining(), 0);
        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.ReserveExceeded.selector);
        d.ownerMint(bob, 1);
    }

    function test_ownerMintDoesNotShrinkPublicSupply() public {
        reserve = 3;
        ERC721DropInstance d = _drop(10, 1000);
        vm.prank(artist);
        d.ownerMint(bob, 2);
        assertEq(d.publicRemaining(), 7);
        _openPublic();
        vm.prank(carol);
        d.mint{ value: PRICE * 7 }(1, 7, new bytes32[](0), address(0), 0);
        assertEq(d.totalSupply(), 9);
    }

    function testFuzz_reserveAlwaysClaimable(uint32 supply, uint32 reserve_, uint32 sold, uint32 ownerFirst) public {
        supply = uint32(bound(supply, 1, 200));
        reserve = uint32(bound(reserve_, 0, supply));
        ERC721DropInstance d = _drop(supply, 1000);
        uint256 first = bound(ownerFirst, 0, reserve);
        if (first != 0) {
            vm.prank(artist);
            d.ownerMint(bob, first);
        }
        _openPublic();
        uint256 want = bound(sold, 1, supply);
        uint256 room = supply - reserve;
        vm.prank(carol);
        if (want > room) vm.expectRevert(ERC721DropInstance.SoldOut.selector);
        d.mint{ value: PRICE * want }(1, want, new bytes32[](0), address(0), 0);
        uint256 publicSold = want > room ? 0 : want;
        assertEq(d.publicRemaining(), room - publicSold);
        if (reserve > first) {
            vm.prank(artist);
            d.ownerMint(bob, reserve - first);
        }
        assertEq(d.totalSupply(), publicSold + reserve);
        assertLe(d.totalSupply(), supply);
    }

    // ── phase supply cap ─────────────────────────────────────────────────────

    function test_phaseCapStopsThatPhaseOnly() public {
        phaseZeroCap = 3;
        ERC721DropInstance d = _drop(100, 1000);
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = _leaf(bob);
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = _leaf(alice);
        vm.prank(alice);
        d.mint{ value: 0.06 ether }(0, 2, aliceProof, address(0), 0);
        vm.prank(bob);
        vm.expectRevert(ERC721DropInstance.PhaseSoldOut.selector);
        d.mint{ value: 0.06 ether }(0, 2, bobProof, address(0), 0);
        vm.prank(bob);
        d.mint{ value: 0.03 ether }(0, 1, bobProof, address(0), 0);
        assertEq(d.phasesMinted()[0], 3);

        _openPublic();
        vm.prank(carol);
        d.mint{ value: PRICE * 5 }(1, 5, new bytes32[](0), address(0), 0);
        assertEq(d.phasesMinted()[1], 5);
    }

    function test_phaseCountsResetWithNewPhaseList() public {
        phaseZeroCap = 2;
        ERC721DropInstance d = _drop(100, 1000);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(bob);
        vm.prank(alice);
        d.mint{ value: 0.06 ether }(0, 2, proof, address(0), 0);

        ERC721DropInstance.Phase[] memory next = new ERC721DropInstance.Phase[](1);
        next[0] = ERC721DropInstance.Phase(uint64(block.timestamp), 0, 0, bytes32(0), 1, _eth(0));
        vm.prank(artist);
        d.setPhases(next);
        assertEq(d.phasesMinted().length, 1);
        assertEq(d.phasesMinted()[0], 0);
        vm.prank(carol);
        d.mint(0, 1, new bytes32[](0), address(0), 0);
        vm.prank(carol);
        vm.expectRevert(ERC721DropInstance.PhaseSoldOut.selector);
        d.mint(0, 1, new bytes32[](0), address(0), 0);
    }

    // ── mintTo ───────────────────────────────────────────────────────────────

    function test_mintToSendsToRecipientAndChargesPayerLimits() public {
        ERC721DropInstance d = _drop(100, 1000);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(bob);
        vm.startPrank(alice);
        d.mintTo{ value: 0.06 ether }(carol, 0, 2, proof, address(0), 0);
        assertEq(d.balanceOf(carol), 2);
        assertEq(d.balanceOf(alice), 0);
        assertEq(d.mintedInPhase(0, alice), 2);
        assertEq(d.mintedInPhase(0, carol), 0);
        // The wallet limit follows the payer, so a new recipient does not reset it.
        vm.expectRevert(ERC721DropInstance.WalletLimit.selector);
        d.mintTo{ value: 0.03 ether }(makeAddr("dave"), 0, 1, proof, address(0), 0);
        vm.stopPrank();
    }

    function test_mintToChecksAllowlistOnPayerNotRecipient() public {
        ERC721DropInstance d = _drop(100, 1000);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(alice);
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert(ERC721DropInstance.NotAllowlisted.selector);
        d.mintTo{ value: 0.03 ether }(bob, 0, 1, proof, address(0), 0);
    }

    function test_mintToZeroAddressReverts() public {
        ERC721DropInstance d = _drop(100, 1000);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = _leaf(bob);
        vm.prank(alice);
        vm.expectRevert();
        d.mintTo{ value: 0.03 ether }(address(0), 0, 1, proof, address(0), 0);
        assertEq(d.totalSupply(), 0);
        assertEq(d.mintedInPhase(0, alice), 0);
    }

    // ── metadata events and royalty lock ─────────────────────────────────────

    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function test_setMetadataEmitsEip4906() public {
        ERC721DropInstance d = _drop(100, 1000);
        assertTrue(d.supportsInterface(0x49064906));
        vm.expectEmit(address(d));
        emit BatchMetadataUpdate(1, 100);
        vm.prank(artist);
        d.setMetadata("ar://revealed/", "", "");
    }

    function test_royaltyLockIsPermanentAndOwnerOnly() public {
        ERC721DropInstance d = _drop(100, 1000);
        vm.prank(alice);
        vm.expectRevert();
        d.lockRoyalty();

        vm.prank(artist);
        d.setRoyalty(bob, 100);
        vm.prank(artist);
        d.lockRoyalty();
        assertTrue(d.royaltyLocked());

        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.Locked.selector);
        d.setRoyalty(artist, 1000);
        (address to, uint256 amount) = d.royaltyInfo(1, 10_000);
        assertEq(to, bob);
        assertEq(amount, 100);
    }

    event RoyaltySet(address indexed receiver, uint96 bps);

    /// The app promises royalties of at most 10%; the contract enforces it on every path.
    function test_royaltyCappedAtTenPercent() public {
        ERC721DropInstance d = _drop(100, 1000);
        assertEq(d.MAX_ROYALTY_BPS(), 1000);

        vm.prank(artist);
        vm.expectRevert(ERC721DropInstance.RoyaltyTooHigh.selector);
        d.setRoyalty(bob, 1001);

        vm.expectEmit(address(d));
        emit RoyaltySet(bob, 1000);
        vm.prank(artist);
        d.setRoyalty(bob, 1000);
        (address to, uint256 amount) = d.royaltyInfo(1, 10_000);
        assertEq(to, bob);
        assertEq(amount, 1000);

        // Creation is capped too.
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0] = ERC721DropInstance.Phase(uint64(block.timestamp), 0, 0, bytes32(0), 0, _eth(PRICE));
        ERC721DropInstance.InitParams memory p = _params(phases, 10);
        p.royaltyBps = 1001;
        vm.prank(artist);
        vm.expectRevert();
        factory.createDrop(p, address(vault), 1000);
        p.royaltyBps = 1000;
        vm.prank(artist);
        ERC721DropInstance ok = ERC721DropInstance(payable(factory.createDrop(p, address(vault), 1000)));
        (, amount) = ok.royaltyInfo(1, 10_000);
        assertEq(amount, 1000);
    }

    function testFuzz_splitConservesValue(uint96 paid, uint16 alignmentBps) public {
        alignmentBps = uint16(bound(alignmentBps, 1000, 9900));
        uint256 quantity = bound(paid, 1, 50);
        ERC721DropInstance d = _drop(100, alignmentBps);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * quantity }(1, quantity, _noProof(), address(0), 0);
        _withdraw(d);
        assertEq(treasury.balance + vault.received() + artist.balance, PRICE * quantity);
        assertEq(address(d).balance, 0);
    }

    // ── a treasury that refuses ETH ──────────────────────────────────────────

    function test_withdrawParksProtocolCutWhenTreasuryRefuses() public {
        vm.etch(treasury, hex"60006000fd");
        ERC721DropInstance d = _drop(100, 1500);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0); // 1 ether

        _withdraw(d);

        assertEq(d.pendingProtocolCut(address(0)), 0.01 ether, "parked");
        assertEq(vault.received(), 0.15 ether, "vault still paid");
        assertEq(artist.balance, 0.84 ether, "artist still paid");
        assertEq(address(d).balance, 0.01 ether, "only the parked cut stays");
    }

    function test_parkedProtocolCutIsNotSplitAgain() public {
        vm.etch(treasury, hex"60006000fd");
        ERC721DropInstance d = _drop(100, 1500);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0);
        _withdraw(d);

        vm.expectRevert(ERC721DropInstance.NothingToWithdraw.selector);
        d.distribute(address(0));
    }

    function test_parkedProtocolCutReachesTreasuryOnceItAccepts() public {
        vm.etch(treasury, hex"60006000fd");
        ERC721DropInstance d = _drop(100, 1500);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0);
        _withdraw(d);

        vm.expectRevert();
        d.flushPendingProtocolCut(address(0));

        vm.etch(treasury, "");
        vm.prank(makeAddr("anyone"));
        d.flushPendingProtocolCut(address(0));
        assertEq(treasury.balance, 0.01 ether);
        assertEq(d.pendingProtocolCut(address(0)), 0);
        assertEq(address(d).balance, 0);
    }

    function test_nextWithdrawCarriesParkedProtocolCut() public {
        vm.etch(treasury, hex"60006000fd");
        ERC721DropInstance d = _drop(100, 1500);
        vm.warp(block.timestamp + 1 days);
        vm.prank(carol);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0);
        _withdraw(d);

        vm.etch(treasury, "");
        vm.prank(alice);
        d.mint{ value: PRICE * 20 }(1, 20, _noProof(), address(0), 0);
        _withdraw(d);
        assertEq(treasury.balance, 0.02 ether);
        assertEq(d.pendingProtocolCut(address(0)), 0);
    }
}
