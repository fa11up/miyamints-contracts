// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MarketTypes } from "./MarketTypes.sol";
import { IParimutuelMarket, IPredictionRegistry, IUsdcSwapper } from "./interfaces/IMarkets.sol";

/**
 * @title UsdcDoor
 * @notice Lets a USDC holder stake in an imdUSD market in one transaction: pull USDC, swap it to imdUSD at
 *         market through the swapper (which quotes any toll above the peg), and stake the proceeds for the
 *         caller through the market's `stakeFor`. Below the peg a USDC user receives more than one imdUSD per
 *         USDC, so they are not disadvantaged.
 *
 *         The door records each wallet's USDC deposited. The ExitDesk pays USDC back only up to that figure
 *         (net of what it already paid), which is what stops "buy imdUSD below the peg, cash out at $1".
 *
 *         No owner. The door never holds funds between transactions.
 */
contract UsdcDoor is ReentrancyGuard {
    using SafeTransferLib for address;

    IPredictionRegistry public immutable registry;
    address public immutable usdc;
    address public immutable imd;
    IUsdcSwapper public immutable swapper;

    /// @notice USDC (6 decimals) each wallet has staked through the door, gross.
    mapping(address wallet => uint256) public depositedUsdc;

    event DoorStake(
        address indexed user, address indexed market, uint8 indexed outcome, uint256 usdcIn, uint256 imdStaked
    );

    error InvalidAddress();
    error UnknownMarket();
    error ZeroAmount();
    error InsufficientOutput(uint256 imdOut, uint256 minImdOut);

    constructor(IPredictionRegistry registry_, address usdc_, address imd_, IUsdcSwapper swapper_) {
        if (
            address(registry_) == address(0) || usdc_ == address(0) || imd_ == address(0)
                || address(swapper_) == address(0)
        ) revert InvalidAddress();
        registry = registry_;
        usdc = usdc_;
        imd = imd_;
        swapper = swapper_;
    }

    /// @notice imdUSD a stake of `usdcIn` would buy now (toll included).
    function quote(uint256 usdcIn) external view returns (uint256) {
        return swapper.quoteUsdcForImd(usdcIn);
    }

    /// @notice Swap `usdcIn` USDC to imdUSD and stake it on `outcome` for the caller.
    function stake(
        address market,
        uint8 outcome,
        uint256 usdcIn,
        uint256 minImdOut,
        MarketTypes.EligibilityPass calldata pass,
        bytes calldata sig
    ) external nonReentrant returns (uint256 imdOut) {
        if (!registry.isMarket(market)) revert UnknownMarket();
        if (usdcIn == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        usdc.safeApprove(address(swapper), usdcIn);
        uint256 before = imd.balanceOf(address(this));
        swapper.swapUsdcForImd(usdcIn, minImdOut, address(this));
        imdOut = imd.balanceOf(address(this)) - before;
        if (imdOut < minImdOut || imdOut == 0) revert InsufficientOutput(imdOut, minImdOut);

        depositedUsdc[msg.sender] += usdcIn;
        imd.safeApprove(market, imdOut);
        IParimutuelMarket(market).stakeFor(msg.sender, outcome, imdOut, pass, sig);
        emit DoorStake(msg.sender, market, outcome, usdcIn, imdOut);
    }
}
