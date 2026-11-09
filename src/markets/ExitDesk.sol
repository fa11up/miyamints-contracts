// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IExitDesk, IPegPriceFeed, IPredictionRegistry } from "./interfaces/IMarkets.sol";
import { UsdcDoor } from "./UsdcDoor.sol";

/**
 * @title ExitDesk
 * @notice Buys imdUSD back for USDC at exactly 1:1, under three limits:
 *         - only while the price feed reports imdUSD below PAY_BELOW ($0.995) and the reading is fresh (above
 *           that, the market itself is a near-par exit);
 *         - per wallet, only up to the USDC that wallet staked through the UsdcDoor, minus what the desk has
 *           already paid it. imdUSD bought below the peg elsewhere earns no credit, which caps the
 *           "buy below the peg, bet both sides, cash out at $1" arbitrage at a wallet's own door deposits;
 *         - globally, the registry refuses any new stake that would take open interest above this desk's
 *           USDC balance, and the owner cannot withdraw USDC below the open interest.
 *
 *         The owner (a multisig) funds the desk, may withdraw the imdUSD the desk bought, and may withdraw USDC
 *         only above the cover the open interest needs. It cannot touch stakes, which live in the markets.
 */
contract ExitDesk is Ownable, ReentrancyGuard, IExitDesk {
    using SafeTransferLib for address;

    uint256 public constant PAY_BELOW = 0.995e18;
    /// @dev imdUSD has 18 decimals, USDC 6.
    uint256 public constant SCALE = 1e12;
    uint64 public constant MAX_PRICE_AGE_CAP = 1 days;

    IPredictionRegistry public immutable registry;
    address public immutable usdc;
    address public immutable imd;
    UsdcDoor public immutable door;

    IPegPriceFeed public priceFeed;
    uint64 public maxPriceAge;

    /// @notice USDC (6 decimals) the desk has paid each wallet.
    mapping(address wallet => uint256) public paidUsdc;

    event CashedOut(address indexed wallet, uint256 imdIn, uint256 usdcOut);
    event Funded(address indexed from, uint256 usdcAmount);
    event PriceFeedSet(address feed, uint64 maxPriceAge);
    event UsdcWithdrawn(address indexed to, uint256 amount);
    event ImdWithdrawn(address indexed to, uint256 amount);

    error InvalidAddress();
    error ZeroAmount();
    error DeskClosed();
    error ExceedsCredit(uint256 requested, uint256 credit);
    error InsufficientUsdc();
    error BelowCover(uint256 remaining, uint256 cover);
    error InvalidPriceAge();

    constructor(
        address owner_,
        IPredictionRegistry registry_,
        address usdc_,
        address imd_,
        UsdcDoor door_,
        IPegPriceFeed priceFeed_,
        uint64 maxPriceAge_
    ) {
        if (
            address(registry_) == address(0) || usdc_ == address(0) || imd_ == address(0)
                || address(door_) == address(0)
        ) revert InvalidAddress();
        _initializeOwner(owner_);
        registry = registry_;
        usdc = usdc_;
        imd = imd_;
        door = door_;
        _setPriceFeed(priceFeed_, maxPriceAge_);
    }

    // ── views ───────────────────────────────────────────────────────────────

    /// @inheritdoc IExitDesk
    function capacity() public view returns (uint256) {
        return usdc.balanceOf(address(this)) * SCALE;
    }

    /// @notice USDC (6 decimals) `wallet` may still take from the desk.
    function creditOf(address wallet) public view returns (uint256) {
        uint256 deposited = door.depositedUsdc(wallet);
        uint256 paid = paidUsdc[wallet];
        return deposited > paid ? deposited - paid : 0;
    }

    /// @notice Whether the desk is paying: a fresh price below PAY_BELOW.
    function isOpen() public view returns (bool) {
        (uint256 price, uint64 updatedAt) = priceFeed.latestPrice();
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) return false;
        return price < PAY_BELOW;
    }

    /// @notice USDC (6 decimals) the open interest needs the desk to hold, rounded up.
    function requiredCover() public view returns (uint256) {
        uint256 oi = registry.openInterest();
        return (oi + SCALE - 1) / SCALE;
    }

    // ── paying ──────────────────────────────────────────────────────────────

    /// @notice Sell `usdcOut * 1e12` imdUSD to the desk for `usdcOut` USDC.
    function cashOut(uint256 usdcOut) external nonReentrant {
        if (usdcOut == 0) revert ZeroAmount();
        if (!isOpen()) revert DeskClosed();
        uint256 credit = creditOf(msg.sender);
        if (usdcOut > credit) revert ExceedsCredit(usdcOut, credit);
        if (usdcOut > usdc.balanceOf(address(this))) revert InsufficientUsdc();
        paidUsdc[msg.sender] += usdcOut;
        uint256 imdIn = usdcOut * SCALE;
        imd.safeTransferFrom(msg.sender, address(this), imdIn);
        usdc.safeTransfer(msg.sender, usdcOut);
        emit CashedOut(msg.sender, imdIn, usdcOut);
    }

    /// @notice Add USDC to the desk. Anyone may fund it.
    function fund(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    // ── owner ───────────────────────────────────────────────────────────────

    function setPriceFeed(IPegPriceFeed feed, uint64 maxPriceAge_) external onlyOwner {
        _setPriceFeed(feed, maxPriceAge_);
    }

    /// @notice Withdraw USDC, never below the cover the current open interest needs.
    function withdrawUsdc(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        uint256 bal = usdc.balanceOf(address(this));
        if (amount > bal) revert InsufficientUsdc();
        uint256 cover = requiredCover();
        if (bal - amount < cover) revert BelowCover(bal - amount, cover);
        usdc.safeTransfer(to, amount);
        emit UsdcWithdrawn(to, amount);
    }

    /// @notice Withdraw imdUSD the desk bought.
    function withdrawImd(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        imd.safeTransfer(to, amount);
        emit ImdWithdrawn(to, amount);
    }

    function _setPriceFeed(IPegPriceFeed feed, uint64 maxPriceAge_) internal {
        if (address(feed) == address(0)) revert InvalidAddress();
        if (maxPriceAge_ == 0 || maxPriceAge_ > MAX_PRICE_AGE_CAP) revert InvalidPriceAge();
        priceFeed = feed;
        maxPriceAge = maxPriceAge_;
        emit PriceFeedSet(address(feed), maxPriceAge_);
    }
}
