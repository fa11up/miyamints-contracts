// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MarketsBase } from "../MarketsBase.sol";
import { MarketTypes } from "../../../src/markets/MarketTypes.sol";
import { ParimutuelMarket } from "../../../src/markets/ParimutuelMarket.sol";
import { EligibilityGate } from "../../../src/markets/EligibilityGate.sol";
import { DisputeModule } from "../../../src/markets/DisputeModule.sol";
import { CouncilResolver } from "../../../src/markets/CouncilResolver.sol";
import { PredictionRegistry } from "../../../src/markets/PredictionRegistry.sol";
import { MockImdUSD } from "../mocks/MarketMockTokens.sol";
import { MockMarketResolver } from "../mocks/MarketMockOracles.sol";

/// @notice Drives one market through random stake / lock / propose / dispute / panel / council / claim / refund /
///         sweep sequences, with time moving forward only.
contract MarketHandler is Test {
    ParimutuelMarket public m;
    MockImdUSD public imd;
    EligibilityGate public gate;
    MockMarketResolver public resolver;
    MockMarketResolver public disputeResolver;
    DisputeModule public disputes;
    CouncilResolver public council;
    uint256 public kycKey;
    address[] public members;
    address[] public users;
    address public disputer = makeAddr("inv-disputer");

    uint256 public totalIn;
    uint256 public totalOut;
    /// @dev Coverage ghosts. Asserting any of these is zero fails within a few hundred calls (checked while
    ///      writing the suite), i.e. sequences do reach claims, refunds, disputes and council decisions.
    uint256 public claims;
    uint256 public refunds;
    uint256 public disputesOpened;
    uint256 public councilDecisions;

    constructor(
        ParimutuelMarket m_,
        MockImdUSD imd_,
        EligibilityGate gate_,
        MockMarketResolver resolver_,
        MockMarketResolver disputeResolver_,
        DisputeModule disputes_,
        CouncilResolver council_,
        uint256 kycKey_,
        address[] memory members_
    ) {
        m = m_;
        imd = imd_;
        gate = gate_;
        resolver = resolver_;
        disputeResolver = disputeResolver_;
        disputes = disputes_;
        council = council_;
        kycKey = kycKey_;
        members = members_;
        for (uint256 i; i < 4; ++i) {
            users.push(address(uint160(0xA000 + i)));
        }
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    modifier tracked() {
        uint256 before = imd.balanceOf(address(m));
        _;
        uint256 afterBal = imd.balanceOf(address(m));
        if (afterBal < before) totalOut += before - afterBal;
        else totalIn += afterBal - before;
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 3 days));
    }

    function stake(uint256 who, uint256 outcome, uint256 amount, uint256 dt) external tracked {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 2 hours));
        if (m.state() != MarketTypes.State.Open) return;
        address u = users[who % users.length];
        amount = bound(amount, 1e18, 250e18);
        if (m.stakedBy(u) + amount > 250e18) return;
        MarketTypes.EligibilityPass memory p = MarketTypes.EligibilityPass({
            wallet: u, issuedAt: uint64(vm.getBlockTimestamp()), expiresAt: uint64(vm.getBlockTimestamp() + 1 hours)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(kycKey, gate.passDigest(p));
        imd.mint(u, amount);
        vm.startPrank(u);
        imd.approve(address(m), amount);
        m.stake(uint8(1 + outcome % 2), amount, p, abi.encodePacked(r, s, v));
        vm.stopPrank();
    }

    function propose(uint256 outcome, uint256 startBack) external {
        MarketTypes.Terms memory t = m.terms();
        if (vm.getBlockTimestamp() < t.resolveAfter) vm.warp(t.resolveAfter);
        uint64 start = t.lockAt - uint64(bound(startBack, 0, 1 days));
        try resolver.propose(address(m), uint8(outcome % 3), start) { } catch { }
    }

    function dispute() external {
        if (m.state() != MarketTypes.State.Proposed || vm.getBlockTimestamp() >= m.disputeDeadline()) return;
        uint256 bond = disputes.bondFor(address(m));
        imd.mint(disputer, bond);
        vm.startPrank(disputer);
        imd.approve(address(disputes), bond);
        try disputes.dispute(address(m)) {
            ++disputesOpened;
        } catch { }
        vm.stopPrank();
    }

    function panel(uint256 outcome) external tracked {
        try disputeResolver.panel(address(disputes), address(m), uint8(outcome % 3)) { } catch { }
    }

    function escalateTimeout() external {
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        try disputes.escalate(address(m)) { } catch { }
    }

    function councilDecide(uint256 outcome) external tracked {
        if (m.state() != MarketTypes.State.Escalated) return;
        uint8 o = uint8(outcome % 3);
        for (uint256 i; i < 3; ++i) {
            vm.prank(members[i]);
            try council.vote(address(m), o) { } catch { }
        }
        if (m.state() != MarketTypes.State.Escalated) ++councilDecisions;
    }

    function finalize() external tracked {
        try m.finalize() { } catch { }
    }

    function voidUnresolved() external tracked {
        try m.voidUnresolved() { } catch { }
    }

    function claim(uint256 who) external tracked {
        address u = users[who % users.length];
        vm.prank(u);
        try m.claim() {
            ++claims;
        } catch { }
    }

    function refund(uint256 who) external tracked {
        address u = users[who % users.length];
        vm.prank(u);
        try m.refund() {
            ++refunds;
        } catch { }
    }

    function payCreator() external tracked {
        try m.payCreator() { } catch { }
    }

    function slash() external tracked {
        for (uint256 i; i < 3; ++i) {
            vm.prank(members[i]);
            try council.voteSlash(address(m)) { } catch { }
        }
    }

    function sweep(uint256 dt) external tracked {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 400 days));
        try m.sweep() { } catch { }
    }

    function settleBond() external {
        try disputes.settleBond(address(m)) { } catch { }
    }
}

contract MarketInvariantTest is MarketsBase {
    MarketHandler handler;
    ParimutuelMarket m;

    function setUp() public override {
        super.setUp();
        m = _winnerMarket();
        handler = new MarketHandler(
            m, imd, gate, mockResolver, mockDisputeResolver, disputes, council, KYC_KEY, councilMembers
        );
        targetContract(address(handler));
    }

    /// @notice The market's token balance always covers everything it still owes: every pending claim, every
    ///         pending refund, the creator's escrow and bond.
    function invariant_balanceCoversOutstandingClaims() public view {
        if (m.swept()) return;
        uint256 owed = m.creatorEscrow() + m.bondHeld();
        uint256 n = handler.userCount();
        for (uint256 i; i < n; ++i) {
            address u = handler.users(i);
            owed += m.claimable(u) + m.refundable(u);
        }
        assertGe(imd.balanceOf(address(m)), owed);
    }

    /// @notice Nothing is created or lost: what came in is either still held or was paid out.
    function invariant_conservation() public view {
        assertEq(handler.totalIn(), imd.balanceOf(address(m)) + handler.totalOut());
        assertEq(handler.totalIn(), m.totalStaked());
    }

    /// @notice The registry's open interest mirrors the market's stake-derived holdings.
    function invariant_openInterestMirrorsMarket() public view {
        assertEq(registry.openInterest(), m.openInterest());
        assertLe(m.openInterest(), imd.balanceOf(address(m)));
    }

    function invariant_walletCaps() public view {
        uint256 n = handler.userCount();
        for (uint256 i; i < n; ++i) {
            assertLe(m.stakedBy(handler.users(i)), WALLET_CAP);
        }
        assertLe(m.totalStaked(), MARKET_CAP);
    }
}
