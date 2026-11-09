// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketsBase } from "./MarketsBase.sol";
import { MarketTypes } from "../../src/markets/MarketTypes.sol";
import { ParimutuelMarket } from "../../src/markets/ParimutuelMarket.sol";

contract MarketFuzzTest is MarketsBase {
    uint256 constant USERS = 6;

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// @notice Every imdUSD staked ends up as exactly one of: a winner payout, a refund, a rake leg (treasury,
    ///         resolver budget, insurance, creator), or the one-year sweep. Rounding dust is at most one wei per
    ///         winner, and it is swept, never lost.
    function testFuzz_conservation(uint256 seed, uint8 winner, uint32 startBack) public {
        winner = uint8(bound(winner, 0, 2));
        ParimutuelMarket m = _winnerMarket();
        uint64 lockAt = m.terms().lockAt;
        uint64 start = lockAt - uint64(bound(startBack, 0, 1 days));

        uint256 t = vm.getBlockTimestamp();
        for (uint256 i; i < USERS; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 stakes = 1 + h % 3;
            for (uint256 j; j < stakes; ++j) {
                uint256 hj = uint256(keccak256(abi.encode(h, j)));
                t += hj % (1 days / 20);
                if (t >= lockAt) break;
                vm.warp(t);
                uint256 room = WALLET_CAP - m.stakedBy(_user(i));
                if (room < MIN_STAKE) break;
                uint256 amount = bound(hj >> 64, MIN_STAKE, room);
                _stake(m, _user(i), uint8(1 + (hj >> 32) % 2), amount);
            }
        }
        uint256 total = m.totalStaked();

        _resolve(m, winner, start);

        uint256 paid;
        uint256 winners;
        for (uint256 i; i < USERS; ++i) {
            address u = _user(i);
            if (m.claimable(u) != 0) {
                paid += _claim(m, u);
                ++winners;
            }
            if (m.refundable(u) != 0) paid += _refund(m, u);
            assertEq(m.claimable(u), 0);
            assertEq(m.refundable(u), 0);
        }
        vm.warp(vm.getBlockTimestamp() + 7 days);
        if (m.creatorEscrow() != 0) m.payCreator();

        uint256 rake =
            imd.balanceOf(treasury) + imd.balanceOf(resolverBudget) + imd.balanceOf(insurance) + imd.balanceOf(creator);
        uint256 dust = imd.balanceOf(address(m));
        assertLe(dust, winners, "dust at most one wei per winner");

        vm.warp(vm.getBlockTimestamp() + 365 days);
        m.sweep();
        assertEq(imd.balanceOf(address(m)), 0);
        assertEq(paid + rake + dust, total, "conservation");
        assertEq(registry.openInterest(), 0);
        if (m.state() == MarketTypes.State.Final) {
            uint256 losing = m.countedPool() - m.winningPool();
            assertApproxEqAbs(rake, losing * 250 / 10_000, 4, "rake is 2.5% of the losing side");
        } else {
            assertEq(rake, 0);
        }
    }

    /// @notice No sequence of stakes takes a wallet past the per-wallet cap or the market past the per-market cap.
    function testFuzz_capsNeverExceeded(uint256[12] memory amounts, uint8[12] memory who) public {
        ParimutuelMarket m = _winnerMarket();
        for (uint256 i; i < 12; ++i) {
            address u = _user(who[i] % 3);
            uint256 amount = bound(amounts[i], MIN_STAKE, 300e18);
            imd.mint(u, amount);
            (MarketTypes.EligibilityPass memory p, bytes memory sig) = _pass(u);
            vm.startPrank(u);
            imd.approve(address(m), amount);
            if (m.stakedBy(u) + amount > WALLET_CAP) {
                vm.expectRevert(ParimutuelMarket.WalletCapExceeded.selector);
            }
            m.stake(uint8(1 + i % 2), amount, p, sig);
            vm.stopPrank();
            assertLe(m.stakedBy(u), WALLET_CAP);
            assertLe(m.totalStaked(), MARKET_CAP);
        }
    }

    /// @notice A stake placed after attestedStart - margin is refunded in full and never shares in the winnings.
    function testFuzz_lateStakesRefunded(uint256 stakeAt, uint256 startBack, uint256 amount) public {
        ParimutuelMarket m = _winnerMarket();
        uint64 lockAt = m.terms().lockAt;
        uint64 start = lockAt - uint64(bound(startBack, 0, 20 hours));
        amount = bound(amount, MIN_STAKE, WALLET_CAP);
        _stake(m, alice, 2, 50e18); // counterparty, staked first
        uint256 t = bound(stakeAt, vm.getBlockTimestamp(), lockAt - 1);
        vm.warp(t);
        _stake(m, bob, 1, amount);

        _resolve(m, 1, start);
        bool late = t > uint256(start) - LOCK_MARGIN;
        if (late) {
            assertEq(m.claimable(bob), 0);
            assertEq(m.refundable(bob), amount);
            assertEq(_refund(m, bob), amount);
        } else {
            assertEq(m.refundable(bob), 0);
            assertGe(m.claimable(bob), amount);
        }
    }

    /// @notice Void refunds every wallet exactly what it staked, whatever the stakes and timing.
    function testFuzz_voidRefundsEverything(uint256 seed) public {
        ParimutuelMarket m = _winnerMarket();
        uint256[USERS] memory staked;
        for (uint256 i; i < USERS; ++i) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), MIN_STAKE, WALLET_CAP);
            _stake(m, _user(i), uint8(1 + i % 2), amount);
            staked[i] = amount;
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        _resolve(m, 0, m.terms().lockAt);
        for (uint256 i; i < USERS; ++i) {
            assertEq(_refund(m, _user(i)), staked[i]);
        }
        assertEq(imd.balanceOf(address(m)), 0);
    }
}
