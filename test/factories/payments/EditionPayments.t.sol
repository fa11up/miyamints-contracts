// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1155Factory } from "../../../src/factories/erc1155/ERC1155Factory.sol";
import {
    ERC1155Instance,
    ExceedsMaxCost,
    InsufficientPayment,
    InsufficientBalance,
    InvalidPrice,
    AmountMustBePositive,
    TokenNotPriced,
    WrongPayment,
    Unauthorized
} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import { DynamicPricingModule } from "../../../src/factories/erc1155/DynamicPricingModule.sol";
import { IMiyaRegistry } from "../../../src/registry/interfaces/IMiyaRegistry.sol";
import { ClaimMode } from "../../../src/interfaces/IAlignmentVault.sol";
import { PaymentLib } from "../../../src/libraries/PaymentLib.sol";
import { TokenPrice } from "../../../src/factories/interfaces/TokenPrice.sol";
import { FreeMintParams } from "../../../src/interfaces/IFactoryTypes.sol";
import { GatingScope } from "../../../src/gating/IGatingModule.sol";
import { PaymentTestBase, MockToken } from "./PaymentMocks.sol";

/// @notice Multi-token payments on ERC1155 editions, including LIMITED_DYNAMIC prices per token.
contract EditionPaymentsTest is PaymentTestBase {
    ERC1155Factory factory;
    DynamicPricingModule module;
    uint16 constant ALIGN = 1900; // 1% protocol / 19% vault / 80% artist
    uint256 salt;

    function setUp() public {
        _setUpPayments();
        factory = new ERC1155Factory(IMiyaRegistry(address(registry)), makeAddr("weth"));
        module = new DynamicPricingModule();
        registry.setComponent(address(module), true);
        factory.setDynamicPricingModule(address(module));
    }

    function _instance(address[] memory tokens) internal returns (ERC1155Instance inst) {
        ERC1155Factory.CreateParams memory p = ERC1155Factory.CreateParams({
            name: "Editions",
            metadataURI: "ipfs://c",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGN,
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }),
            acceptedTokens: tokens
        });
        vm.prank(artist);
        inst = ERC1155Instance(payable(factory.createInstance(bytes32(++salt), p)));
    }

    function _three(address a, uint256 pa, address b, uint256 pb, address c, uint256 pc)
        internal
        pure
        returns (TokenPrice[] memory p)
    {
        p = new TokenPrice[](3);
        p[0] = TokenPrice(a, pa);
        p[1] = TokenPrice(b, pb);
        p[2] = TokenPrice(c, pc);
    }

    function _mint(ERC1155Instance inst, address who, uint256 id, uint256 n, address token) internal returns (uint256) {
        uint256 cost = inst.calculateMintCost(id, n, token);
        _approve(who, token, address(inst));
        vm.prank(who);
        if (token == ETH) inst.mint{ value: cost }(id, n, bytes32(0), "", token, cost);
        else inst.mint(id, n, bytes32(0), "", token, cost);
        return cost;
    }

    // ── fixed price per token ───────────────────────────────────────────────

    function test_fixedEdition_payAndSplitInEachToken() public {
        ERC1155Instance inst = _instance(_list(ETH, address(usdc), address(wbtc), address(imdUsd)));
        TokenPrice[] memory prices = new TokenPrice[](4);
        prices[0] = TokenPrice(ETH, 0.01 ether);
        prices[1] = TokenPrice(address(usdc), 25e6);
        prices[2] = TokenPrice(address(wbtc), 0.0003e8);
        prices[3] = TokenPrice(address(imdUsd), 25e18);
        vm.prank(artist);
        inst.addEdition("Song", prices, 0, "ipfs://s", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);

        for (uint256 i; i < prices.length; ++i) {
            address t = prices[i].token;
            uint256 artistBefore = _bal(t, artist);
            uint256 cost = _mint(inst, alice, 1, 4, t);
            assertEq(cost, prices[i].price * 4);
            assertEq(inst.totalProceeds(t), cost);
            vm.prank(artist);
            inst.withdraw(t);
            uint256 protocol = cost / 100;
            uint256 toVault = cost * ALIGN / 10_000;
            assertEq(_bal(t, treasury), protocol);
            assertEq(vault.received(t), toVault);
            assertEq(_bal(t, artist) - artistBefore, cost - protocol - toVault);
            assertEq(_bal(t, address(inst)), 0);
        }
        assertEq(inst.balanceOf(alice, 1), 16);
    }

    function test_ethExcessStillRefunded_erc20PullsExactly() public {
        ERC1155Instance inst = _instance(_list(ETH, address(usdc)));
        TokenPrice[] memory prices = new TokenPrice[](2);
        prices[0] = TokenPrice(ETH, 0.01 ether);
        prices[1] = TokenPrice(address(usdc), 25e6);
        vm.prank(artist);
        inst.addEdition("S", prices, 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        inst.mint{ value: 1 ether }(1, 2, bytes32(0), "", ETH, 0);
        assertEq(before - alice.balance, 0.02 ether);

        _approve(alice, address(usdc), address(inst));
        vm.startPrank(alice);
        vm.expectRevert(WrongPayment.selector);
        inst.mint{ value: 1 }(1, 1, bytes32(0), "", address(usdc), 25e6);
        vm.expectRevert(ExceedsMaxCost.selector);
        inst.mint(1, 1, bytes32(0), "", address(usdc), 0);
        uint256 u = usdc.balanceOf(alice);
        inst.mint(1, 1, bytes32(0), "", address(usdc), 1000e6);
        vm.stopPrank();
        assertEq(u - usdc.balanceOf(alice), 25e6, "maxCost is a cap, not the amount pulled");
    }

    function test_feeOnTransferRefused() public {
        ERC1155Instance inst = _instance(_list(address(feeToken)));
        vm.prank(artist);
        inst.addEdition("S", _one(address(feeToken), 1e18), 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        _approve(alice, address(feeToken), address(inst));
        vm.prank(alice);
        vm.expectRevert(PaymentLib.ShortTransfer.selector);
        inst.mint(1, 1, bytes32(0), "", address(feeToken), 1e18);
    }

    function test_editionPricesValidated() public {
        ERC1155Instance inst = _instance(_list(ETH, address(usdc)));
        vm.startPrank(artist);
        vm.expectRevert(PaymentLib.InvalidPrice.selector);
        inst.addEdition("S", _one(address(usdc), 0), 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(PaymentLib.TokenNotAccepted.selector, address(wbtc)));
        inst.addEdition("S", _one(address(wbtc), 1), 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.expectRevert(PaymentLib.NoTokens.selector);
        inst.addEdition("S", new TokenPrice[](0), 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        inst.addEdition("S", _one(address(usdc), 5e6), 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(TokenNotPriced.selector);
        inst.mint{ value: 1 ether }(1, 1, bytes32(0), "", ETH, 0);

        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        inst.setEditionPrices(1, _one(ETH, 1));
        vm.prank(artist);
        inst.setEditionPrices(1, _one(ETH, 0.002 ether));
        (bool priced, uint256 price) = inst.priceOf(1, ETH);
        assertTrue(priced);
        assertEq(price, 0.002 ether);
        (priced,) = inst.priceOf(1, address(usdc));
        assertFalse(priced);
    }

    function test_factoryRejectsUnlistedToken() public {
        MockToken rogue = new MockToken("R", "R", 18);
        ERC1155Factory.CreateParams memory p = ERC1155Factory.CreateParams({
            name: "E",
            metadataURI: "",
            creator: artist,
            vault: address(vault),
            alignmentBps: ALIGN,
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({ allocation: 0, scope: GatingScope.BOTH }),
            acceptedTokens: _list(address(rogue))
        });
        vm.prank(artist);
        vm.expectRevert();
        factory.createInstance(bytes32(uint256(999)), p);
    }

    // ── dynamic price per token ─────────────────────────────────────────────

    function test_dynamicEdition_everyTokenRisesByTheSameRule() public {
        ERC1155Instance inst = _instance(_list(ETH, address(usdc), address(cbbtc)));
        uint256 rate = 500; // 5% per mint
        TokenPrice[] memory prices = _three(ETH, 0.01 ether, address(usdc), 30e6, address(cbbtc), 0.0004e8);
        vm.prank(artist);
        inst.addEdition("Rising", prices, 50, "u", ERC1155Instance.PricingModel.LIMITED_DYNAMIC, rate, 0);

        // Mint 3 in USDC, 2 in ETH, 4 in cbBTC: each token's cost follows its own base on the shared curve.
        uint256 minted;
        address[3] memory order = [address(usdc), ETH, address(cbbtc)];
        uint256[3] memory counts = [uint256(3), 2, 4];
        for (uint256 i; i < 3; ++i) {
            address t = order[i];
            (, uint256 base) = inst.priceOf(1, t);
            uint256 expected = module.calculateBatchCost(base, rate, minted, counts[i]);
            uint256 cost = _mint(inst, alice, 1, counts[i], t);
            assertEq(cost, expected, "cost on the shared curve");
            minted += counts[i];
            for (uint256 j; j < 3; ++j) {
                address u = prices[j].token;
                assertEq(inst.getCurrentPrice(1, u), module.calculatePrice(prices[j].price, rate, minted));
            }
        }
        assertGt(inst.getCurrentPrice(1, address(usdc)), 30e6);
        // The ratio between tokens holds as the price rises (to rounding).
        assertApproxEqRel(
            inst.getCurrentPrice(1, address(usdc)) * 1e30 / inst.getCurrentPrice(1, ETH), 30e6 * 1e30 / 0.01 ether, 1e12
        );
    }

    function test_dynamicEdition_maxCostProtectsAgainstAPriceRise() public {
        ERC1155Instance inst = _instance(_list(address(usdc)));
        vm.prank(artist);
        inst.addEdition("R", _one(address(usdc), 10e6), 10, "u", ERC1155Instance.PricingModel.LIMITED_DYNAMIC, 1000, 0);
        uint256 quoted = inst.calculateMintCost(1, 1, address(usdc));
        _mint(inst, bob, 1, 1, address(usdc)); // front-runs alice
        _approve(alice, address(usdc), address(inst));
        vm.prank(alice);
        vm.expectRevert(ExceedsMaxCost.selector);
        inst.mint(1, 1, bytes32(0), "", address(usdc), quoted);
    }

    // ── withdraw, failing parties ───────────────────────────────────────────

    function test_withdrawOwnerOnly_distributeOpen_withdrawAll() public {
        ERC1155Instance inst = _instance(_list(ETH, address(usdc)));
        TokenPrice[] memory prices = new TokenPrice[](2);
        prices[0] = TokenPrice(ETH, 0.1 ether);
        prices[1] = TokenPrice(address(usdc), 100e6);
        vm.prank(artist);
        inst.addEdition("S", prices, 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        _mint(inst, alice, 1, 1, ETH);
        _mint(inst, alice, 1, 1, address(usdc));

        vm.prank(alice);
        vm.expectRevert();
        inst.withdraw(ETH);
        vm.prank(alice);
        inst.distribute(address(usdc));
        assertEq(usdc.balanceOf(treasury), 1e6);
        assertEq(inst.ownerBalance(address(usdc)), 80e6);

        uint256 e = artist.balance;
        uint256 u = usdc.balanceOf(artist);
        vm.prank(artist);
        inst.withdrawAll();
        assertEq(artist.balance - e, 0.08 ether);
        assertEq(usdc.balanceOf(artist) - u, 80e6);
        vm.prank(artist);
        vm.expectRevert(InsufficientBalance.selector);
        inst.withdrawAll();
    }

    function test_vaultRefusesErc20_parkedThenToppedUp() public {
        ERC1155Instance inst = _instance(_list(address(usdc)));
        vm.prank(artist);
        inst.addEdition("S", _one(address(usdc), 5e6), 1, "u", ERC1155Instance.PricingModel.LIMITED_FIXED, 0, 0);
        _mint(inst, alice, 1, 1, address(usdc));
        vault.setMinContribution(address(usdc), 1e6);
        inst.distribute(address(usdc));
        assertEq(inst.pendingVaultCut(address(usdc)), 0.95e6);
        assertEq(usdc.allowance(address(inst), address(vault)), 0);

        _approve(bob, address(usdc), address(inst));
        vm.prank(bob);
        inst.flushPendingVaultCut(address(usdc), 0.05e6);
        assertEq(vault.credited(address(inst), address(usdc)), 1e6);
        assertEq(inst.pendingVaultCut(address(usdc)), 0);
    }

    function test_blocklistedTreasuryParksWbtcCut() public {
        ERC1155Instance inst = _instance(_list(address(wbtc)));
        vm.prank(artist);
        inst.addEdition("S", _one(address(wbtc), 0.01e8), 0, "u", ERC1155Instance.PricingModel.UNLIMITED, 0, 0);
        wbtc.setBlocked(treasury, true);
        _mint(inst, alice, 1, 1, address(wbtc));
        vm.prank(artist);
        inst.withdraw(address(wbtc));
        assertEq(inst.pendingProtocolCut(address(wbtc)), 0.0001e8);
        assertEq(wbtc.balanceOf(artist), 0.008e8);
        wbtc.setBlocked(treasury, false);
        inst.flushPendingProtocolCut(address(wbtc));
        assertEq(wbtc.balanceOf(treasury), 0.0001e8);
        assertEq(wbtc.balanceOf(address(inst)), 0);
    }

    function test_sweepUntrackedErc20() public {
        ERC1155Instance inst = _instance(_list(address(imdUsd)));
        vm.prank(alice);
        imdUsd.transfer(address(inst), 10e18);
        inst.sweepUntracked(address(imdUsd));
        assertEq(inst.totalProceeds(address(imdUsd)), 10e18);
        vm.expectRevert(AmountMustBePositive.selector);
        inst.sweepUntracked(address(imdUsd));
    }

    // ── vault fees ──────────────────────────────────────────────────────────

    function test_claimVaultFeesForwardsToOwner_claimAllFeesNeverRevertsOnZero() public {
        ERC1155Instance inst = _instance(_list(ETH));
        vm.prank(artist);
        inst.claimAllFees(); // nothing yet: no revert

        _fundVaultFees(2e18, 3e18, 0);
        vm.prank(artist);
        inst.claimVaultFees(ClaimMode.TOKENS, 0);
        assertEq(infer.balanceOf(artist), 2e18);
        assertEq(imd.balanceOf(artist), 3e18);

        _fundVaultFees(0, 0, 0.5 ether);
        uint256 before = artist.balance;
        vm.prank(artist);
        inst.claimVaultFees(ClaimMode.ETH, 0.5 ether);
        assertEq(artist.balance - before, 0.5 ether);

        vm.prank(artist);
        vm.expectRevert(PaymentLib.NoFeesToClaim.selector);
        inst.claimVaultFees(ClaimMode.TOKENS, 0);
    }
}
