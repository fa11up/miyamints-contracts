// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPegPriceFeed, IUsdcSwapper } from "../../../src/markets/interfaces/IMarkets.sol";
import { MarketMockToken } from "./MarketMockTokens.sol";

/// @notice Swaps USDC for freshly minted mock imdUSD at a settable rate (imdUSD per USDC, 1e18 = 1:1),
///         minus a settable toll in bps (the above-peg toll a real door must quote).
contract MockUsdcSwapper is IUsdcSwapper {
    MarketMockToken public immutable usdc;
    MarketMockToken public immutable imd;
    uint256 public rate = 1e18;
    uint256 public tollBps;

    constructor(MarketMockToken usdc_, MarketMockToken imd_) {
        usdc = usdc_;
        imd = imd_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setToll(uint256 tollBps_) external {
        tollBps = tollBps_;
    }

    function quoteUsdcForImd(uint256 usdcIn) public view returns (uint256) {
        uint256 gross = usdcIn * 1e12 * rate / 1e18;
        return gross - gross * tollBps / 10_000;
    }

    function swapUsdcForImd(uint256 usdcIn, uint256 minImdOut, address recipient) external returns (uint256 out) {
        out = quoteUsdcForImd(usdcIn);
        require(out >= minImdOut, "slippage");
        usdc.transferFrom(msg.sender, address(this), usdcIn);
        imd.mint(recipient, out);
    }
}

/// @notice imdUSD price feed with a settable price and timestamp.
contract MockPegPriceFeed is IPegPriceFeed {
    uint256 public price = 1e18;
    uint64 public updatedAt;

    constructor() {
        updatedAt = uint64(block.timestamp);
    }

    function set(uint256 price_, uint64 updatedAt_) external {
        price = price_;
        updatedAt = updatedAt_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
        updatedAt = uint64(block.timestamp);
    }

    function latestPrice() external view returns (uint256, uint64) {
        return (price, updatedAt);
    }
}

/// @notice A resolver stand-in for state-machine tests: forwards whatever it is told, like a verified panel.
contract MockMarketResolver {
    function propose(address market, uint8 outcome, uint64 attestedStart) external {
        IMockMarket(market).propose(outcome, attestedStart, msg.sender);
    }

    function panel(address disputeModule, address market, uint8 outcome) external {
        IMockDispute(disputeModule).onPanelResult(market, outcome);
    }
}

interface IMockMarket {
    function propose(uint8 outcome, uint64 attestedStart, address proposer_) external;
}

interface IMockDispute {
    function onPanelResult(address market, uint8 outcome) external;
}
