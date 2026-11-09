// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721DropInstance } from "../../../src/factories/erc721drop/ERC721DropInstance.sol";
import { ERC721DropFactory } from "../../../src/factories/erc721drop/ERC721DropFactory.sol";
import { IMiyaRegistry } from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import { ClaimMode } from "../../../src/interfaces/IAlignmentVault.sol";
import { PaymentLib } from "../../../src/libraries/PaymentLib.sol";
import { TokenPrice } from "../../../src/factories/interfaces/TokenPrice.sol";
import { PaymentTestBase, MockToken } from "./PaymentMocks.sol";

/// @notice Multi-token payments on ERC721 drops (docs/IMD-INFER-VAULT.md "Sale flow").
contract DropPaymentsTest is PaymentTestBase {
    ERC721DropFactory factory;
    uint16 constant ALIGN = 1500; // 1% protocol / 15% vault / 84% artist

    function setUp() public {
        _setUpPayments();
        factory = new ERC721DropFactory(IMiyaRegistry(address(registry)), address(0));
    }

    /// @dev One public phase, open now, priced in each of `tokens` at `prices`.
    function _drop(address[] memory tokens, uint256[] memory prices) internal returns (ERC721DropInstance d) {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0].start = uint64(block.timestamp);
        phases[0].prices = new TokenPrice[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            phases[0].prices[i] = TokenPrice(tokens[i], prices[i]);
        }
        d = _create(tokens, phases);
    }

    function _create(address[] memory tokens, ERC721DropInstance.Phase[] memory phases)
        internal
        returns (ERC721DropInstance d)
    {
        ERC721DropInstance.InitParams memory p;
        p.name = "multi";
        p.symbol = "MULTI";
        p.maxSupply = 1000;
        p.acceptedTokens = tokens;
        p.phases = phases;
        vm.prank(artist);
        d = ERC721DropInstance(payable(factory.createDrop(p, address(vault), ALIGN)));
    }

    function _allSeven() internal view returns (address[] memory t, uint256[] memory p) {
        t = new address[](7);
        p = new uint256[](7);
        (t[0], p[0]) = (ETH, 0.05 ether);
        (t[1], p[1]) = (address(usdc), 150e6);
        (t[2], p[2]) = (address(cbbtc), 0.0015e8);
        (t[3], p[3]) = (address(wbtc), 0.0016e8);
        (t[4], p[4]) = (address(imd), 1234e18);
        (t[5], p[5]) = (address(infer), 77e18);
        (t[6], p[6]) = (address(imdUsd), 150e18);
    }

    function _mint(ERC721DropInstance d, address who, address token, uint256 qty, uint256 cost) internal {
        _approve(who, token, address(d));
        vm.prank(who);
        if (token == ETH) d.mint{ value: cost }(0, qty, new bytes32[](0), token, cost);
        else d.mint(0, qty, new bytes32[](0), token, cost);
    }

    // ── payment, split, withdraw per token and decimals ─────────────────────

    function test_mintSplitWithdraw_everyTokenAndDecimals() public {
        (address[] memory tokens, uint256[] memory prices) = _allSeven();
        ERC721DropInstance d = _drop(tokens, prices);
        assertEq(d.acceptedTokens().length, 7);

        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            uint256 cost = prices[i] * 3;
            uint256 artistBefore = _bal(t, artist);
            uint256 aliceBefore = _bal(t, alice);
            _mint(d, alice, t, 3, cost);
            assertEq(aliceBefore - _bal(t, alice), cost, "buyer paid exactly the price");
            assertEq(d.unsplitProceeds(t), cost);
            assertEq(_bal(t, address(d)), cost);

            vm.prank(makeAddr("anyone"));
            d.distribute(t);
            uint256 protocol = cost * 100 / 10_000;
            uint256 toVault = cost * ALIGN / 10_000;
            assertEq(_bal(t, treasury), protocol, "protocol 1% in the token paid");
            assertEq(vault.received(t), toVault, "vault share in the token paid");
            assertEq(vault.credited(address(d), t), toVault, "credited to the collection");
            assertEq(d.ownerBalance(t), cost - protocol - toVault);
            assertEq(_bal(t, artist), artistBefore, "distribute never pays the artist");

            vm.prank(artist);
            d.withdraw(t);
            assertEq(_bal(t, artist) - artistBefore, cost - protocol - toVault, "artist gets the rest, as paid");
            assertEq(_bal(t, address(d)), 0);
            assertEq(d.ownerBalance(t), 0);
        }
        assertEq(d.totalSupply(), 21);
    }

    function test_withdrawAll_paysEveryTokenIncludingRemovedOnes() public {
        ERC721DropInstance d = _drop(_list(ETH, address(usdc)), _prices(0.1 ether, 300e6));
        _mint(d, alice, ETH, 1, 0.1 ether);
        _mint(d, bob, address(usdc), 2, 600e6);

        // Removing USDC stops USDC sales, never the balance already earned.
        vm.prank(artist);
        d.setAcceptedTokens(_list(ETH));
        assertEq(d.knownTokens().length, 2);

        uint256 ethBefore = artist.balance;
        uint256 usdcBefore = usdc.balanceOf(artist);
        vm.prank(artist);
        d.withdrawAll();
        assertEq(artist.balance - ethBefore, 0.1 ether - 0.001 ether - 0.015 ether);
        assertEq(usdc.balanceOf(artist) - usdcBefore, 600e6 - 6e6 - 90e6);

        vm.prank(artist);
        vm.expectRevert(PaymentLib.NothingToWithdraw.selector);
        d.withdrawAll();
    }

    function test_withdrawAll_skipsATokenThatCantPayOut() public {
        ERC721DropInstance d = _drop(_list(ETH, address(usdc)), _prices(0.1 ether, 100e6));
        _mint(d, alice, ETH, 1, 0.1 ether);
        _mint(d, bob, address(usdc), 1, 100e6);
        usdc.setBlocked(artist, true); // the owner can't receive USDC

        uint256 ethBefore = artist.balance;
        vm.expectEmit(true, false, false, false, address(d));
        emit ERC721DropInstance.WithdrawSkipped(address(usdc));
        vm.prank(artist);
        d.withdrawAll();
        assertEq(artist.balance - ethBefore, 0.1 ether - 0.001 ether - 0.015 ether, "ETH still paid");
        assertEq(d.unsplitProceeds(address(usdc)), 100e6, "the skipped token is untouched");

        usdc.setBlocked(artist, false);
        uint256 usdcBefore = usdc.balanceOf(artist);
        vm.prank(artist);
        d.withdraw(address(usdc));
        assertEq(usdc.balanceOf(artist) - usdcBefore, 100e6 - 1e6 - 15e6);
    }

    function test_withdrawIsOwnerOnly_distributeIsOpen() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(100e6));
        _mint(d, alice, address(usdc), 1, 100e6);
        vm.prank(alice);
        vm.expectRevert();
        d.withdraw(address(usdc));
        vm.prank(alice);
        d.distribute(address(usdc));
        vm.expectRevert(ERC721DropInstance.NothingToWithdraw.selector);
        d.distribute(address(usdc));
    }

    // ── payment rules ───────────────────────────────────────────────────────

    function test_erc20_maxCostRequiredAndBinding() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(100e6));
        _approve(alice, address(usdc), address(d));
        vm.startPrank(alice);
        vm.expectRevert(ERC721DropInstance.ExceedsMaxCost.selector);
        d.mint(0, 2, new bytes32[](0), address(usdc), 0);
        vm.expectRevert(ERC721DropInstance.ExceedsMaxCost.selector);
        d.mint(0, 2, new bytes32[](0), address(usdc), 200e6 - 1);
        d.mint(0, 2, new bytes32[](0), address(usdc), 200e6);
        vm.stopPrank();
        assertEq(d.balanceOf(alice), 2);
    }

    function test_erc20_mintRefusesEth() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(100e6));
        _approve(alice, address(usdc), address(d));
        vm.prank(alice);
        vm.expectRevert(ERC721DropInstance.WrongPayment.selector);
        d.mint{ value: 1 }(0, 1, new bytes32[](0), address(usdc), 100e6);
    }

    function test_eth_exactValueAndMaxCost() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(0.05 ether));
        vm.startPrank(alice);
        vm.expectRevert(ERC721DropInstance.WrongPayment.selector);
        d.mint{ value: 0.05 ether + 1 }(0, 1, new bytes32[](0), ETH, 0);
        vm.expectRevert(ERC721DropInstance.ExceedsMaxCost.selector);
        d.mint{ value: 0.05 ether }(0, 1, new bytes32[](0), ETH, 0.04 ether);
        d.mint{ value: 0.05 ether }(0, 1, new bytes32[](0), ETH, 0);
        vm.stopPrank();
    }

    function test_feeOnTransferTokenRefusedByBalanceCheck() public {
        ERC721DropInstance d = _drop(_list(address(feeToken)), _prices(100e18));
        _approve(alice, address(feeToken), address(d));
        vm.prank(alice);
        vm.expectRevert(PaymentLib.ShortTransfer.selector);
        d.mint(0, 1, new bytes32[](0), address(feeToken), 100e18);
        assertEq(d.totalSupply(), 0);
    }

    function test_unacceptedTokenRefused() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(0.05 ether));
        _approve(alice, address(usdc), address(d));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAccepted.selector, address(usdc)));
        d.mint(0, 1, new bytes32[](0), address(usdc), 100e6);
    }

    function test_tokenMustBeAllowlisted_atCreationAndInSetter() public {
        MockToken rogue = new MockToken("Rogue", "R", 18);
        ERC721DropInstance.Phase[] memory none;
        ERC721DropInstance.InitParams memory p;
        p.name = "x";
        p.symbol = "X";
        p.maxSupply = 10;
        p.acceptedTokens = _list(address(rogue));
        p.phases = none;
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAllowed.selector, address(rogue)));
        factory.createDrop(p, address(vault), ALIGN);

        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAllowed.selector, address(rogue)));
        d.setAcceptedTokens(_list(ETH, address(rogue)));
    }

    function test_acceptedTokenListRules() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        vm.startPrank(artist);
        vm.expectRevert(PaymentLib.NoTokens.selector);
        d.setAcceptedTokens(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.DuplicateToken.selector, address(usdc)));
        d.setAcceptedTokens(_list(address(usdc), address(usdc)));
        address[] memory nine = new address[](9);
        vm.expectRevert(PaymentLib.TooManyTokens.selector);
        d.setAcceptedTokens(nine);
        vm.expectEmit(address(d));
        emit PaymentLib.AcceptedTokensSet(_list(address(usdc), ETH));
        d.setAcceptedTokens(_list(address(usdc), ETH));
        vm.stopPrank();
        assertEq(d.acceptedTokens()[0], address(usdc));
        assertTrue(d.isAcceptedToken(ETH));

        vm.prank(alice);
        vm.expectRevert();
        d.setAcceptedTokens(_list(ETH));
    }

    function test_allowlistRemovalStopsNewSalesButKeepsBalances() public {
        ERC721DropInstance d = _drop(_list(ETH, address(usdc)), _prices(0.05 ether, 100e6));
        _mint(d, alice, address(usdc), 1, 100e6);
        registry.setPaymentToken(address(usdc), false);

        _approve(bob, address(usdc), address(d));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAllowed.selector, address(usdc)));
        d.mint(0, 1, new bytes32[](0), address(usdc), 100e6);

        _mint(d, bob, ETH, 1, 0.05 ether); // other tokens still sell
        vm.prank(artist);
        d.withdraw(address(usdc));
        assertEq(usdc.balanceOf(artist), 1_000_000e6 + 84e6);
    }

    // ── phases ──────────────────────────────────────────────────────────────

    function test_phasesPriceEachTokenSeparately() public {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](2);
        phases[0].start = uint64(block.timestamp);
        phases[0].end = uint64(block.timestamp + 1 days);
        phases[0].maxPerWallet = 2;
        phases[0].prices = _one(address(usdc), 50e6); // USDC only
        phases[1].start = uint64(block.timestamp + 1 days);
        phases[1].prices = new TokenPrice[](2);
        phases[1].prices[0] = TokenPrice(address(usdc), 80e6);
        phases[1].prices[1] = TokenPrice(address(cbbtc), 0.001e8);
        ERC721DropInstance d = _create(_list(ETH, address(usdc), address(cbbtc), address(imd)), phases);

        (bool priced, uint256 price) = d.priceOf(0, address(usdc));
        assertTrue(priced);
        assertEq(price, 50e6);
        (priced,) = d.priceOf(0, ETH);
        assertFalse(priced);

        vm.prank(alice);
        vm.expectRevert(ERC721DropInstance.TokenNotPriced.selector);
        d.mint{ value: 0.05 ether }(0, 1, new bytes32[](0), ETH, 0);

        _approve(alice, address(usdc), address(d));
        vm.prank(alice);
        d.mint(0, 2, new bytes32[](0), address(usdc), 100e6);
        vm.prank(alice);
        vm.expectRevert(ERC721DropInstance.WalletLimit.selector);
        d.mint(0, 1, new bytes32[](0), address(usdc), 50e6);

        vm.warp(block.timestamp + 1 days);
        _approve(alice, address(cbbtc), address(d));
        vm.prank(alice);
        d.mint(1, 3, new bytes32[](0), address(cbbtc), 0.003e8);
        assertEq(cbbtc.balanceOf(address(d)), 0.003e8);
        assertEq(usdc.balanceOf(address(d)), 100e6);
    }

    function test_phasePricesMustUseAcceptedTokens() public {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0].start = uint64(block.timestamp);
        phases[0].prices = _one(address(usdc), 50e6);
        ERC721DropInstance.InitParams memory p;
        p.name = "x";
        p.symbol = "X";
        p.maxSupply = 10;
        p.acceptedTokens = _list(ETH);
        p.phases = phases;
        vm.prank(artist);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAccepted.selector, address(usdc)));
        factory.createDrop(p, address(vault), ALIGN);
    }

    function test_setPhasePricesKeepsCounters() public {
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0].start = uint64(block.timestamp);
        phases[0].maxPerWallet = 2;
        phases[0].prices = _one(address(usdc), 50e6);
        ERC721DropInstance d = _create(_list(ETH, address(usdc)), phases);
        _approve(alice, address(usdc), address(d));
        vm.prank(alice);
        d.mint(0, 1, new bytes32[](0), address(usdc), 50e6);

        TokenPrice[] memory next = new TokenPrice[](2);
        next[0] = TokenPrice(address(usdc), 70e6);
        next[1] = TokenPrice(ETH, 0.02 ether);
        vm.prank(artist);
        d.setPhasePrices(0, next);
        assertEq(d.mintedInPhase(0, alice), 1, "counts kept");

        vm.prank(alice);
        vm.expectRevert(ERC721DropInstance.ExceedsMaxCost.selector);
        d.mint(0, 1, new bytes32[](0), address(usdc), 50e6);
        vm.prank(alice);
        d.mint{ value: 0.02 ether }(0, 1, new bytes32[](0), ETH, 0);
        vm.prank(alice);
        vm.expectRevert(ERC721DropInstance.WalletLimit.selector);
        d.mint(0, 1, new bytes32[](0), address(usdc), 70e6);
    }

    function test_freePhaseInAToken() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(0));
        vm.prank(alice);
        d.mint(0, 2, new bytes32[](0), address(usdc), 0);
        assertEq(d.balanceOf(alice), 2);
        vm.expectRevert(ERC721DropInstance.NothingToWithdraw.selector);
        d.distribute(address(usdc));
    }

    // ── failing vault, treasury, owner ──────────────────────────────────────

    function test_vaultRefusesErc20_cutParkedAllowanceCleared_thenToppedUp() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(1e6));
        _mint(d, alice, address(usdc), 1, 1e6); // vault cut 0.15 USDC
        vault.setMinContribution(address(usdc), 1e6);
        d.distribute(address(usdc));
        assertEq(d.pendingVaultCut(address(usdc)), 0.15e6, "parked, not redirected");
        assertEq(usdc.allowance(address(d), address(vault)), 0, "no allowance left behind");
        assertEq(d.ownerBalance(address(usdc)), 0.84e6);
        assertEq(usdc.balanceOf(address(d)), 0.99e6);

        // Too little top-up: the vault still refuses and the top-up goes back.
        usdc.mint(bob, 1e6);
        vm.prank(bob);
        usdc.approve(address(d), type(uint256).max);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        d.flushPendingVaultCut(address(usdc), 0.5e6);
        assertEq(usdc.balanceOf(bob), bobBefore);

        vm.prank(bob);
        d.flushPendingVaultCut(address(usdc), 0.85e6);
        assertEq(d.pendingVaultCut(address(usdc)), 0);
        assertEq(vault.credited(address(d), address(usdc)), 1e6, "parked cut + top-up, credited to the drop");
        assertEq(vault.credited(bob, address(usdc)), 0);

        vm.expectRevert(PaymentLib.NothingParked.selector);
        d.flushPendingVaultCut(address(usdc), 0);
    }

    function test_parkedErc20VaultCutGoesWithNextSplit() public {
        ERC721DropInstance d = _drop(_list(address(cbbtc)), _prices(0.01e8));
        _mint(d, alice, address(cbbtc), 1, 0.01e8);
        vault.setRejecting(true);
        d.distribute(address(cbbtc));
        uint256 parked = d.pendingVaultCut(address(cbbtc));
        assertEq(parked, 0.0015e8);
        vault.setRejecting(false);
        _mint(d, bob, address(cbbtc), 1, 0.01e8);
        d.distribute(address(cbbtc));
        assertEq(d.pendingVaultCut(address(cbbtc)), 0);
        assertEq(vault.received(address(cbbtc)), parked * 2);
    }

    function test_ethFlushTopUpMustMatchValue() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(0.001 ether));
        _mint(d, alice, ETH, 1, 0.001 ether);
        vault.setRejecting(true);
        d.distribute(ETH);
        vault.setRejecting(false);
        vm.prank(bob);
        vm.expectRevert(PaymentLib.WrongValue.selector);
        d.flushPendingVaultCut{ value: 1 }(ETH, 2);
        vm.prank(bob);
        d.flushPendingVaultCut{ value: 0.001 ether }(ETH, 0.001 ether);
        assertEq(vault.credited(address(d), ETH), 0.00015 ether + 0.001 ether);
    }

    function test_blocklistedTreasuryParksProtocolCut() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(100e6));
        usdc.setBlocked(treasury, true);
        _mint(d, alice, address(usdc), 1, 100e6);
        d.distribute(address(usdc));
        assertEq(d.pendingProtocolCut(address(usdc)), 1e6);
        assertEq(vault.received(address(usdc)), 15e6, "vault still paid");
        assertEq(d.ownerBalance(address(usdc)), 84e6, "artist still credited");

        vm.expectRevert();
        d.flushPendingProtocolCut(address(usdc));

        _mint(d, bob, address(usdc), 1, 100e6);
        usdc.setBlocked(treasury, false);
        d.distribute(address(usdc));
        assertEq(usdc.balanceOf(treasury), 2e6, "parked cut carried by the next split");
        assertEq(d.pendingProtocolCut(address(usdc)), 0);
    }

    function test_blocklistedOwnerBlocksNothingButItsOwnWithdraw() public {
        ERC721DropInstance d = _drop(_list(ETH, address(usdc)), _prices(0.05 ether, 100e6));
        usdc.setBlocked(artist, true);
        _mint(d, alice, address(usdc), 1, 100e6);
        d.distribute(address(usdc));
        assertEq(usdc.balanceOf(treasury), 1e6);

        _mint(d, alice, ETH, 1, 0.05 ether);
        vm.startPrank(artist);
        vm.expectRevert();
        d.withdraw(address(usdc));
        d.withdraw(ETH);
        vm.stopPrank();
        assertEq(d.ownerBalance(address(usdc)), 84e6, "kept for later");

        usdc.setBlocked(artist, false);
        vm.prank(artist);
        d.withdraw(address(usdc));
        assertEq(d.ownerBalance(address(usdc)), 0);
    }

    function test_sweepUntrackedErc20CountsAsProceeds() public {
        ERC721DropInstance d = _drop(_list(address(usdc)), _prices(100e6));
        _mint(d, alice, address(usdc), 1, 100e6);
        vm.prank(bob);
        usdc.transfer(address(d), 50e6); // e.g. royalties paid in USDC
        d.sweepUntracked(address(usdc));
        assertEq(d.unsplitProceeds(address(usdc)), 150e6);
        vm.expectRevert(ERC721DropInstance.NothingToWithdraw.selector);
        d.sweepUntracked(address(usdc));
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAccepted.selector, address(wbtc)));
        d.sweepUntracked(address(wbtc));
    }

    // ── vault fees ──────────────────────────────────────────────────────────

    function test_claimVaultFees_tokensModeForwardsInferImdAndEth() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        _fundVaultFees(5e18, 7e18, 0.01 ether);
        uint256 ethBefore = artist.balance;
        vm.prank(artist);
        (uint256 i, uint256 m, uint256 e) = d.claimVaultFees(ClaimMode.TOKENS, 0);
        assertEq(i, 5e18);
        assertEq(m, 7e18);
        assertEq(e, 0.01 ether);
        assertEq(infer.balanceOf(artist), 5e18);
        assertEq(imd.balanceOf(artist), 7e18);
        assertEq(artist.balance - ethBefore, 0.01 ether);
        assertEq(uint8(vault.lastMode()), uint8(ClaimMode.TOKENS));

        vm.prank(artist);
        vm.expectRevert(PaymentLib.NoFeesToClaim.selector);
        d.claimVaultFees(ClaimMode.TOKENS, 0);
    }

    function test_claimVaultFees_forwardsTheVaultsOwnFeeTokens() public {
        // Off mainnet the vault's fee tokens are other addresses: the collection reads them from the vault.
        MockToken feeA = new MockToken("A", "A", 18);
        MockToken feeB = new MockToken("B", "B", 18);
        vault.setFeeTokens(address(feeA), address(feeB));
        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        feeA.mint(address(vault), 3e18);
        feeB.mint(address(vault), 4e18);
        vault.setFees(3e18, 4e18, 0);
        vm.prank(artist);
        (uint256 i, uint256 m,) = d.claimVaultFees(ClaimMode.TOKENS, 0);
        assertEq(i, 3e18);
        assertEq(m, 4e18);
        assertEq(feeA.balanceOf(artist), 3e18);
        assertEq(feeB.balanceOf(artist), 4e18);
        assertEq(feeA.balanceOf(address(d)) + feeB.balanceOf(address(d)), 0, "nothing stranded");
    }

    function test_claimVaultFees_ethModePassesFloor() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        _fundVaultFees(0, 0, 0.3 ether);
        uint256 before = artist.balance;
        vm.prank(artist);
        vm.expectRevert(bytes("minEthOut"));
        d.claimVaultFees(ClaimMode.ETH, 0.31 ether);
        vm.prank(artist);
        d.claimVaultFees(ClaimMode.ETH, 0.3 ether);
        assertEq(artist.balance - before, 0.3 ether);
        assertEq(vault.lastMinEthOut(), 0.3 ether);
    }

    function test_claimVaultFees_reinvestPaysNothingAndDoesNotRevert() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        _fundVaultFees(5e18, 7e18, 0);
        vm.prank(artist);
        (uint256 i, uint256 m, uint256 e) = d.claimVaultFees(ClaimMode.REINVEST, 1);
        assertEq(i + m + e, 0);
        assertEq(uint8(vault.lastMode()), uint8(ClaimMode.REINVEST));
        assertEq(infer.balanceOf(artist), 0);
    }

    function test_claimVaultFees_ownerOnly() public {
        ERC721DropInstance d = _drop(_list(ETH), _prices(1));
        vm.prank(alice);
        vm.expectRevert();
        d.claimVaultFees(ClaimMode.TOKENS, 0);
    }

    function test_vaultFeesInAnAcceptedTokenDontTouchProceeds() public {
        ERC721DropInstance d = _drop(_list(address(imd)), _prices(100e18));
        _mint(d, alice, address(imd), 1, 100e18);
        _fundVaultFees(0, 3e18, 0);
        vm.prank(artist);
        d.claimVaultFees(ClaimMode.TOKENS, 0);
        assertEq(imd.balanceOf(artist), 3e18);
        assertEq(d.unsplitProceeds(address(imd)), 100e18);
        assertEq(imd.balanceOf(address(d)), 100e18);
    }

    // ── conservation ────────────────────────────────────────────────────────

    function testFuzz_splitConservesEveryDecimals(uint256 price, uint8 qty, uint16 align, uint8 which) public {
        address[4] memory ts = [ETH, address(usdc), address(cbbtc), address(imdUsd)];
        address t = ts[which % 4];
        price = bound(price, 0, t == ETH ? 10 ether : (t == address(usdc) ? 10_000e6 : 1e8));
        qty = uint8(bound(qty, 1, 20));
        uint16 a = uint16(bound(align, 1000, 9900));
        ERC721DropInstance.Phase[] memory phases = new ERC721DropInstance.Phase[](1);
        phases[0].start = uint64(block.timestamp);
        phases[0].prices = _one(t, price);
        ERC721DropInstance.InitParams memory p;
        p.name = "f";
        p.symbol = "F";
        p.maxSupply = 100;
        p.acceptedTokens = _list(t);
        p.phases = phases;
        vm.prank(artist);
        ERC721DropInstance d = ERC721DropInstance(payable(factory.createDrop(p, address(vault), a)));
        uint256 cost = price * qty;
        _mint(d, alice, t, qty, cost);
        uint256 artistBefore = _bal(t, artist);
        vm.prank(artist);
        if (cost == 0) vm.expectRevert(PaymentLib.NothingToWithdraw.selector);
        d.withdraw(t);
        assertEq(_bal(t, treasury) + vault.received(t) + _bal(t, artist) - artistBefore, cost);
        assertEq(_bal(t, address(d)), 0);
    }

    function _prices(uint256 a) internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = a;
    }

    function _prices(uint256 a, uint256 b) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = a;
        p[1] = b;
    }
}
