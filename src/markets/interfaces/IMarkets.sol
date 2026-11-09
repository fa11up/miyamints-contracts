// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MarketTypes } from "../MarketTypes.sol";

/// @notice A source of market results. `outcome` 0 means VOID; `attestedStart` is 0 when not applicable.
interface IResolver {
    function result(address market) external view returns (bool answered, uint8 outcome, uint64 attestedStart);
}

/// @notice The slice of PredictionRegistry that markets, the door and the desk call.
interface IPredictionRegistry {
    function isMarket(address market) external view returns (bool);
    function openInterest() external view returns (uint256);
    function onStake(uint256 amount) external;
    function onRelease(uint256 amount) external;
}

/// @notice Verifies eligibility passes. Reverts when the pass does not admit `wallet`.
interface IEligibilityGate {
    function check(address wallet, MarketTypes.EligibilityPass calldata pass, bytes calldata sig) external view;
}

/// @notice Swaps USDC for imdUSD at market. Implementations must quote any toll above the peg.
interface IUsdcSwapper {
    function quoteUsdcForImd(uint256 usdcIn) external view returns (uint256 imdOut);
    function swapUsdcForImd(uint256 usdcIn, uint256 minImdOut, address recipient) external returns (uint256 imdOut);
}

/// @notice imdUSD's USD price, 1e18 = $1.
interface IPegPriceFeed {
    function latestPrice() external view returns (uint256 price, uint64 updatedAt);
}

/// @notice The USDC exit. `capacity` is its USDC balance scaled to 18 decimals.
interface IExitDesk {
    function capacity() external view returns (uint256);
}

/// @notice The hooks DisputeModule exposes to resolvers.
interface IDisputeModule {
    function onPanelResult(address market, uint8 outcome) external;
}

/// @notice The market surface used by the factory, resolvers, the dispute module, the council and the door.
interface IParimutuelMarket {
    function initialize(MarketTypes.Terms calldata terms, address[] calldata denied) external;
    function terms() external view returns (MarketTypes.Terms memory);
    function state() external view returns (MarketTypes.State);
    function totalStaked() external view returns (uint256);
    function proposedOutcome() external view returns (uint8);
    function proposer() external view returns (address);
    function finalOutcome() external view returns (uint8);
    function decidedOutcome() external view returns (uint8);
    function timedOut() external view returns (bool);
    function outcomeForAnswer(uint256 answer) external view returns (uint8);
    function stakeFor(
        address user,
        uint8 outcome,
        uint256 amount,
        MarketTypes.EligibilityPass calldata pass,
        bytes calldata sig
    ) external;
    function propose(uint8 outcome, uint64 attestedStart, address proposer_) external;
    function markDisputed() external;
    function upholdProposal() external;
    function escalate() external;
    function councilResolve(uint8 outcome) external;
    function slashCreator() external;
}
