// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MarketTypes
 * @notice Types shared by the prediction-market contracts.
 * @dev Outcome numbering: outcomes are 1-based (1..outcomeCount) and 0 always means VOID, so a resolver,
 *      the council and the market all speak the same "code" language as the oracle question.
 */
library MarketTypes {
    uint8 internal constant VOID = 0;
    uint8 internal constant MAX_OUTCOMES = 8;

    /// @dev Plane answer types (EIP-712 `answerType` field): bool = 0, address = 1, bytes32 = 2, uint256 = 3.
    uint8 internal constant ANSWER_BOOL = 0;
    uint8 internal constant ANSWER_UINT256 = 3;

    /// @dev `Locked` is never stored: a market reads as Locked once `lockAt` has passed while it is still Open.
    enum State {
        Open,
        Locked,
        Proposed,
        Disputed,
        Escalated,
        Final,
        Void
    }

    /// @dev How an attested answer becomes an outcome.
    ///      Coded: the answer is a code; `codeMap[code]` is the outcome (0 = VOID).
    ///      Bool: true -> outcome 1, false -> outcome 2.
    ///      Threshold: answer > threshold -> outcome 1 ("over"), otherwise outcome 2 ("under").
    enum AnswerMode {
        Coded,
        Bool,
        Threshold
    }

    /// @notice Rake legs, each in basis points of the LOSING side. The rake is their sum.
    struct RakeSplit {
        uint16 treasuryBps;
        uint16 creatorBps;
        uint16 resolverBps;
        uint16 insuranceBps;
    }

    /// @notice A market template: a fixed question document with typed slots, and how its answer maps to outcomes.
    /// @dev `parts` interleave with the slots: parts[0] slot[0] parts[1] ... slot[n-1] parts[n]. The assembled
    ///      document is the canonical question JSON up to and including `,"window":{"fromBlock":`, the same
    ///      prefix shape the oracle core splices the signed window into. `startParts` (optional, same slots) is
    ///      a second question asking for the event's official start time in unix seconds; when present the
    ///      market locks on the source clock.
    struct Template {
        string name;
        bytes[] parts;
        bytes[] startParts;
        uint8 slotCount;
        uint8 outcomeCount;
        AnswerMode answerMode;
        uint8 answerType;
        bytes codeMap;
        uint64 dataChainId;
        uint32 disputeWindow;
        uint32 minLockGap;
        bool active;
    }

    /// @notice Everything a market needs, fixed at creation. Registry changes never reach an existing market.
    struct Terms {
        address token;
        address registry;
        address creator;
        address door;
        address eligibility;
        address resolver;
        address disputeResolver;
        address disputeModule;
        address council;
        address treasury;
        address resolverBudget;
        address insurance;
        RakeSplit rake;
        uint128 perWalletCap;
        uint128 perMarketCap;
        uint128 minStake;
        uint128 minBond;
        uint16 bondBps;
        uint128 creatorBond;
        uint64 lockAt;
        uint64 resolveAfter;
        uint32 lockMargin;
        uint32 disputeWindow;
        bytes32 questionHash;
        bytes32 startQuestionHash;
        uint64 dataChainId;
        uint8 answerType;
        AnswerMode answerMode;
        uint8 outcomeCount;
        uint256 threshold;
        bytes codeMap;
    }

    /// @notice A short-lived KYC/geo eligibility pass, signed off chain by the eligibility signer.
    struct EligibilityPass {
        address wallet;
        uint64 issuedAt;
        uint64 expiresAt;
    }
}
