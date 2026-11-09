// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketTypes } from "./MarketTypes.sol";
import { IDisputeModule, IParimutuelMarket, IPredictionRegistry } from "./interfaces/IMarkets.sol";

/**
 * @title DisputeModule
 * @notice Bonded disputes for ParimutuelMarket proposals.
 *
 *         1. During a market's dispute window anyone may dispute by posting a bond of
 *            max(minBond, bondBps of the market's total stake), both snapshotted in the market's terms.
 *         2. A second, independent panel answers through the market's dispute resolver (a SwarmResolver of the
 *            Dispute tier, with its own address and larger panel floors). If it agrees with the proposal, the
 *            proposal stands. If it disagrees, or it does not answer within PANEL_WINDOW, the market escalates
 *            to the council.
 *         3. Once the market is Final or Void, `settleBond` pays the bond: if the decided outcome equals the
 *            proposal, the disputer lost and the bond splits 50% to the proposer (the winner of the dispute) and
 *            50% to the market's treasury; otherwise, or if the council never decided, the bond is returned.
 *
 *         No owner. The module holds only dispute bonds, never stakes.
 */
contract DisputeModule is ReentrancyGuard, IDisputeModule {
    using SafeTransferLib for address;

    uint256 public constant BPS = 10_000;
    uint64 public constant PANEL_WINDOW = 3 days;

    struct Dispute {
        address disputer;
        uint128 bond;
        uint8 proposedOutcome;
        uint64 panelDeadline;
        bool panelDone;
        bool settled;
    }

    IPredictionRegistry public immutable registry;

    mapping(address market => Dispute) public disputes;

    event DisputeOpened(address indexed market, address indexed disputer, uint256 bond, uint8 proposedOutcome);
    event PanelResult(address indexed market, uint8 outcome, bool agrees);
    event Escalated(address indexed market);
    event BondSettled(
        address indexed market, bool disputerWon, uint256 toDisputer, uint256 toProposer, uint256 toTreasury
    );

    error InvalidAddress();
    error UnknownMarket();
    error WrongModule();
    error AlreadyDisputed();
    error NoDispute();
    error NotDisputeResolver();
    error PanelClosed();
    error PanelStillOpen();
    error NotResolved();
    error AlreadySettled();

    constructor(IPredictionRegistry registry_) {
        if (address(registry_) == address(0)) revert InvalidAddress();
        registry = registry_;
    }

    /// @notice The bond a dispute of `market` costs now.
    function bondFor(address market) public view returns (uint256) {
        MarketTypes.Terms memory t = IParimutuelMarket(market).terms();
        uint256 variable = IParimutuelMarket(market).totalStaked() * t.bondBps / BPS;
        return variable > t.minBond ? variable : t.minBond;
    }

    /// @notice Dispute `market`'s proposal, paying the bond in the market's token.
    function dispute(address market) external nonReentrant {
        if (!registry.isMarket(market)) revert UnknownMarket();
        IParimutuelMarket m = IParimutuelMarket(market);
        MarketTypes.Terms memory t = m.terms();
        if (t.disputeModule != address(this)) revert WrongModule();
        if (disputes[market].disputer != address(0)) revert AlreadyDisputed();

        uint256 bond = bondFor(market);
        uint8 proposed = m.proposedOutcome();
        disputes[market] = Dispute({
            disputer: msg.sender,
            bond: uint128(bond),
            proposedOutcome: proposed,
            panelDeadline: uint64(block.timestamp) + PANEL_WINDOW,
            panelDone: false,
            settled: false
        });
        m.markDisputed();
        t.token.safeTransferFrom(msg.sender, address(this), bond);
        emit DisputeOpened(market, msg.sender, bond, proposed);
    }

    /// @inheritdoc IDisputeModule
    function onPanelResult(address market, uint8 outcome) external {
        Dispute storage d = disputes[market];
        if (d.disputer == address(0)) revert NoDispute();
        IParimutuelMarket m = IParimutuelMarket(market);
        if (msg.sender != m.terms().disputeResolver) revert NotDisputeResolver();
        if (d.panelDone || block.timestamp > d.panelDeadline) revert PanelClosed();
        d.panelDone = true;
        bool agrees = outcome == d.proposedOutcome;
        emit PanelResult(market, outcome, agrees);
        if (agrees) {
            m.upholdProposal();
        } else {
            m.escalate();
            emit Escalated(market);
        }
    }

    /// @notice Escalate to the council when the second panel did not answer in time. Anyone may call.
    function escalate(address market) external {
        Dispute storage d = disputes[market];
        if (d.disputer == address(0)) revert NoDispute();
        if (d.panelDone) revert PanelClosed();
        if (block.timestamp <= d.panelDeadline) revert PanelStillOpen();
        d.panelDone = true;
        IParimutuelMarket(market).escalate();
        emit Escalated(market);
    }

    /// @notice Pay out the bond once the market is Final or Void. Anyone may call.
    function settleBond(address market) external nonReentrant {
        Dispute storage d = disputes[market];
        if (d.disputer == address(0)) revert NoDispute();
        if (d.settled) revert AlreadySettled();
        IParimutuelMarket m = IParimutuelMarket(market);
        MarketTypes.State s = m.state();
        if (s != MarketTypes.State.Final && s != MarketTypes.State.Void) revert NotResolved();
        d.settled = true;

        MarketTypes.Terms memory t = m.terms();
        uint256 bond = d.bond;
        // decidedOutcome, not finalOutcome: a decision for a side nobody counted on voids the market, and the dispute
        // still turns on whether that decision matched the proposal.
        bool disputerWon = m.timedOut() || m.decidedOutcome() != d.proposedOutcome;
        if (disputerWon) {
            t.token.safeTransfer(d.disputer, bond);
            emit BondSettled(market, true, bond, 0, 0);
        } else {
            uint256 toProposer = bond / 2;
            uint256 toTreasury = bond - toProposer;
            address winner = m.proposer();
            if (winner == address(0)) winner = t.treasury;
            t.token.safeTransfer(winner, toProposer);
            t.token.safeTransfer(t.treasury, toTreasury);
            emit BondSettled(market, false, 0, toProposer, toTreasury);
        }
    }
}
