// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";
import { PredictionRegistry } from "../../src/markets/PredictionRegistry.sol";
import { EligibilityGate } from "../../src/markets/EligibilityGate.sol";
import { UsdcDoor } from "../../src/markets/UsdcDoor.sol";
import { ExitDesk } from "../../src/markets/ExitDesk.sol";
import { IPegPriceFeed } from "../../src/markets/interfaces/IMarkets.sol";

contract DoorDeskTest is MarketsBase {
    ParimutuelMarket m;

    function setUp() public override {
        super.setUp();
        m = _winnerMarket();
    }

    function _doorStake(address user, uint8 outcome, uint256 usdcIn) internal returns (uint256 imdOut) {
        usdc.mint(user, usdcIn);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(user);
        vm.startPrank(user);
        usdc.approve(address(door), usdcIn);
        imdOut = door.stake(address(m), outcome, usdcIn, 0, p, sig);
        vm.stopPrank();
    }

    function _cashOut(address user, uint256 usdcOut) internal {
        vm.startPrank(user);
        imd.approve(address(desk), usdcOut * 1e12);
        desk.cashOut(usdcOut);
        vm.stopPrank();
    }

    // ── door ────────────────────────────────────────────────────────────────

    function test_door_stakesForCallerAndTracksDeposits() public {
        uint256 out = _doorStake(alice, 1, 100e6);
        assertEq(out, 100e18);
        assertEq(m.stakeOf(alice, 1), 100e18);
        assertEq(m.stakeOf(address(door), 1), 0);
        assertEq(door.depositedUsdc(alice), 100e6);
        assertEq(usdc.balanceOf(address(door)), 0);
        assertEq(imd.balanceOf(address(door)), 0);
    }

    function test_door_belowPegBuysMoreImd() public {
        swapper.setRate(1.1e18);
        assertEq(_doorStake(alice, 1, 100e6), 110e18);
    }

    function test_door_quotesTollAbovePeg() public {
        swapper.setToll(150); // 1.5%
        assertEq(door.quote(100e6), 98.5e18);
        assertEq(_doorStake(alice, 1, 100e6), 98.5e18);
    }

    function test_door_slippageAndZero() public {
        usdc.mint(alice, 100e6);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.startPrank(alice);
        usdc.approve(address(door), 100e6);
        vm.expectRevert();
        door.stake(address(m), 1, 100e6, 101e18, p, sig);
        vm.expectRevert(UsdcDoor.ZeroAmount.selector);
        door.stake(address(m), 1, 0, 0, p, sig);
        vm.stopPrank();
    }

    function test_door_unknownMarket() public {
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.prank(alice);
        vm.expectRevert(UsdcDoor.UnknownMarket.selector);
        door.stake(alice, 1, 1e6, 0, p, sig);
    }

    function test_door_deniedCrewCannotUseDoor() public {
        usdc.mint(crewMod, 10e6);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(crewMod);
        vm.startPrank(crewMod);
        usdc.approve(address(door), 10e6);
        vm.expectRevert(ParimutuelMarket.Denied.selector);
        door.stake(address(m), 1, 10e6, 0, p, sig);
        vm.stopPrank();
    }

    function test_door_passMustBeCallers() public {
        usdc.mint(alice, 10e6);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(bob);
        vm.startPrank(alice);
        usdc.approve(address(door), 10e6);
        vm.expectRevert(EligibilityGate.WrongWallet.selector);
        door.stake(address(m), 1, 10e6, 0, p, sig);
        vm.stopPrank();
    }

    function test_door_walletCapCountsImdStaked() public {
        swapper.setRate(1.25e18);
        _doorStake(alice, 1, 200e6); // 250 imdUSD: at the cap
        usdc.mint(alice, 1e6);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.startPrank(alice);
        usdc.approve(address(door), 1e6);
        vm.expectRevert(ParimutuelMarket.WalletCapExceeded.selector);
        door.stake(address(m), 1, 1e6, 0, p, sig);
        vm.stopPrank();
    }

    // ── desk: when it pays ──────────────────────────────────────────────────

    function test_desk_openOnlyBelow0995AndFresh() public {
        feed.setPrice(1e18);
        assertFalse(desk.isOpen());
        feed.setPrice(0.995e18);
        assertFalse(desk.isOpen());
        feed.setPrice(0.9949e18);
        assertTrue(desk.isOpen());
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        assertFalse(desk.isOpen());
        feed.set(0.9e18, uint64(vm.getBlockTimestamp() + 10)); // a timestamp from the future is not fresh
        assertFalse(desk.isOpen());
    }

    function test_desk_closedReverts() public {
        _doorStake(alice, 1, 10e6);
        feed.setPrice(1e18);
        vm.prank(alice);
        vm.expectRevert(ExitDesk.DeskClosed.selector);
        desk.cashOut(1e6);
    }

    function test_desk_paysOneToOneUpToDoorDeposits() public {
        _doorStake(alice, 1, 100e6);
        _doorStake(bob, 2, 100e6);
        _resolve(m, 1, m.terms().lockAt);
        uint256 won = _claim(m, alice); // 197.5 imdUSD
        assertEq(won, 197.5e18);

        feed.setPrice(0.95e18);
        assertEq(desk.creditOf(alice), 100e6);
        _cashOut(alice, 60e6);
        assertEq(usdc.balanceOf(alice), 60e6);
        assertEq(imd.balanceOf(alice), won - 60e18);
        assertEq(desk.creditOf(alice), 40e6);
        _cashOut(alice, 40e6);
        vm.startPrank(alice);
        imd.approve(address(desk), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ExitDesk.ExceedsCredit.selector, 1e6, 0));
        desk.cashOut(1e6);
        vm.stopPrank();
    }

    // ── arbitrage ───────────────────────────────────────────────────────────

    /// @notice Buy imdUSD below the peg elsewhere, bet both sides, try to cash out at $1: no door deposits, no credit.
    function test_arbitrage_externalBuyerHasNoCredit() public {
        _stake(m, dave, 1, 112e18); // imdUSD bought at ~$0.89 outside the door
        _stake(m, dave, 2, 112e18);
        _resolve(m, 1, m.terms().lockAt);
        uint256 got = _claim(m, dave);
        assertGt(got, 220e18);
        feed.setPrice(0.89e18);
        assertEq(desk.creditOf(dave), 0);
        vm.startPrank(dave);
        imd.approve(address(desk), got);
        vm.expectRevert(abi.encodeWithSelector(ExitDesk.ExceedsCredit.selector, 1e6, 0));
        desk.cashOut(1e6);
        vm.stopPrank();
    }

    /// @notice The same trade through the door: the desk pays back at most the USDC that went in.
    function test_arbitrage_doorBothSidesCappedAtDeposits() public {
        swapper.setRate(1.123595505617977528e18); // $0.89 per imdUSD
        uint256 a = _doorStake(alice, 1, 100e6);
        uint256 b = _doorStake(alice, 2, 100e6);
        _resolve(m, 1, m.terms().lockAt);
        uint256 got = _claim(m, alice);
        assertApproxEqAbs(got, a + b - b * 250 / 10_000, 4); // each rake leg rounds down separately
        assertGt(got, 200e18); // more imdUSD than USDC put in...

        feed.setPrice(0.89e18);
        _cashOut(alice, 200e6); // ...but only the 200 USDC deposited comes back at $1
        assertEq(desk.paidUsdc(alice), 200e6);
        vm.startPrank(alice);
        imd.approve(address(desk), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ExitDesk.ExceedsCredit.selector, 1e6, 0));
        desk.cashOut(1e6);
        vm.stopPrank();
        // What is left is imdUSD the wallet bought at market; the desk paid out no more than went in.
        assertLe(usdc.balanceOf(alice), 200e6);
    }

    /// @notice Two wallets, one each side, pooling winnings: still bounded by the two wallets' own door deposits.
    function test_arbitrage_twoWalletSelfHedgeBoundedByTotalDeposits() public {
        swapper.setRate(1.123595505617977528e18);
        address sybil = makeAddr("sybil");
        _doorStake(alice, 1, 100e6);
        _doorStake(sybil, 2, 100e6);
        _resolve(m, 1, m.terms().lockAt);
        uint256 got = _claim(m, alice);
        vm.prank(alice);
        imd.transfer(sybil, got - 100e18);

        feed.setPrice(0.89e18);
        _cashOut(alice, 100e6);
        _cashOut(sybil, 100e6);
        uint256 totalPaid = desk.paidUsdc(alice) + desk.paidUsdc(sybil);
        uint256 totalDeposited = door.depositedUsdc(alice) + door.depositedUsdc(sybil);
        assertEq(totalPaid, totalDeposited);
        vm.startPrank(sybil);
        imd.approve(address(desk), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ExitDesk.ExceedsCredit.selector, 1e6, 0));
        desk.cashOut(1e6);
        vm.stopPrank();
    }

    // ── open interest vs exit cover ─────────────────────────────────────────

    function _shrinkDeskTo(uint256 usdcLeft) internal {
        uint256 bal = usdc.balanceOf(address(desk));
        vm.prank(owner);
        desk.withdrawUsdc(owner, bal - usdcLeft);
    }

    function test_openInterestCappedByDeskBalance() public {
        _shrinkDeskTo(300e6);
        assertEq(registry.openInterestRoom(), 300e18);
        _stake(m, alice, 1, 250e18);
        assertEq(registry.openInterestRoom(), 50e18);
        imd.mint(bob, 100e18);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(bob);
        vm.startPrank(bob);
        imd.approve(address(m), 100e18);
        vm.expectRevert(abi.encodeWithSelector(PredictionRegistry.ExceedsExitCover.selector, 350e18, 300e18));
        m.stake(2, 100e18, p, sig);
        m.stake(2, 50e18, p, sig);
        vm.stopPrank();
        assertEq(registry.openInterestRoom(), 0);
    }

    function test_openInterestReleasedByPayouts() public {
        _shrinkDeskTo(300e6);
        _stake(m, alice, 1, 100e18);
        _stake(m, bob, 2, 200e18);
        assertEq(registry.openInterestRoom(), 0);
        _resolve(m, 1, m.terms().lockAt);
        // rake legs other than the creator's left at Final
        assertEq(registry.openInterest(), 300e18 - 3.5e18);
        _claim(m, alice);
        assertEq(registry.openInterest(), 1.5e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        m.payCreator();
        assertEq(registry.openInterest(), 0);
    }

    function test_withdrawUsdc_neverBelowCover() public {
        _shrinkDeskTo(300e6);
        _stake(m, alice, 1, 250e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ExitDesk.BelowCover.selector, 249e6, 250e6));
        desk.withdrawUsdc(owner, 51e6);
        vm.prank(owner);
        desk.withdrawUsdc(owner, 50e6);
        assertEq(desk.capacity(), 250e18);
    }

    function test_noDeskMeansNoStakes() public {
        vm.prank(owner);
        registry.setModules(
            address(door), address(gate), address(0), address(disputes), address(mockDisputeResolver), address(council)
        );
        assertEq(registry.exitCover(), 0);
        imd.mint(alice, 1e18);
        (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(alice);
        vm.startPrank(alice);
        imd.approve(address(m), 1e18);
        vm.expectRevert(abi.encodeWithSelector(PredictionRegistry.ExceedsExitCover.selector, 1e18, 0));
        m.stake(1, 1e18, p, sig);
        vm.stopPrank();
    }

    // ── desk admin ──────────────────────────────────────────────────────────

    function test_desk_adminOnlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        desk.withdrawUsdc(alice, 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        desk.withdrawImd(alice, 1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        desk.setPriceFeed(IPegPriceFeed(address(feed)), 1 hours);
        vm.stopPrank();
    }

    function test_desk_setPriceFeedBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(ExitDesk.InvalidPriceAge.selector);
        desk.setPriceFeed(IPegPriceFeed(address(feed)), 0);
        vm.expectRevert(ExitDesk.InvalidPriceAge.selector);
        desk.setPriceFeed(IPegPriceFeed(address(feed)), 1 days + 1);
        vm.expectRevert(ExitDesk.InvalidAddress.selector);
        desk.setPriceFeed(IPegPriceFeed(address(0)), 1 hours);
        desk.setPriceFeed(IPegPriceFeed(address(feed)), 2 hours);
        vm.stopPrank();
        assertEq(desk.maxPriceAge(), 2 hours);
    }

    function test_desk_withdrawImdItBought() public {
        _doorStake(alice, 1, 10e6);
        _doorStake(bob, 2, 10e6);
        _resolve(m, 1, m.terms().lockAt);
        _claim(m, alice);
        feed.setPrice(0.95e18);
        _cashOut(alice, 10e6);
        vm.prank(owner);
        desk.withdrawImd(owner, 10e18);
        assertEq(imd.balanceOf(owner), 10e18);
    }
}
