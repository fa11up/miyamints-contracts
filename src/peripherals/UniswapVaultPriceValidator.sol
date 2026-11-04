// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import {IVaultPriceValidator} from "../interfaces/IVaultPriceValidator.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "../libraries/v4/LiquidityAmounts.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

// ========== External Protocol Interfaces ==========

/// @notice Uniswap V2 Factory interface
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Uniswap V2 Pair interface
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Uniswap V3 Factory interface
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Uniswap V3 Pool interface
interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

contract UniswapVaultPriceValidator is IVaultPriceValidator {
    using StateLibrary for IPoolManager;

    error PriceDeviationTooHigh();

    address public immutable weth;
    /// @notice WETH a V2 pair must hold before its price is used as a reference (same floor as the V2-only route).
    uint256 private constant Q96 = 1 << 96;
    uint256 public constant MIN_REFERENCE_WETH = 10 ether;

    address public immutable v2Factory;
    address public immutable v3Factory;
    address public immutable poolManager;
    uint256 public immutable maxPriceDeviationBps;
    /// @notice TWAP window used for V3 price queries. Defaults to 30 minutes.
    uint32 public immutable twapSecondsAgo;

    constructor(
        // slither-disable-next-line missing-zero-check
        address _weth,
        // slither-disable-next-line missing-zero-check
        address _v2Factory,
        // slither-disable-next-line missing-zero-check
        address _v3Factory,
        // slither-disable-next-line missing-zero-check
        address _poolManager,
        uint256 _maxPriceDeviationBps,
        uint32 _twapSecondsAgo
    ) {
        weth = _weth;
        v2Factory = _v2Factory;
        v3Factory = _v3Factory;
        poolManager = _poolManager;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        twapSecondsAgo = _twapSecondsAgo == 0 ? 1800 : _twapSecondsAgo;
    }

    // --- IVaultPriceValidator ---

    /// @inheritdoc IVaultPriceValidator
    function quoteEthForTokens(address token, uint256 tokenAmount) external view override returns (uint256) {
        if (tokenAmount == 0) return 0;

        // Prefer V3 TWAP — most manipulation-resistant
        (, uint256 priceV3, ) = _getV3PriceAndLiquidity(token);
        if (priceV3 > 0) {
            return (tokenAmount * priceV3) / 1e18;
        }

        // Fall back to V2 spot price (acceptable for low-frequency fee conversion)
        (, uint256 priceV2, , ) = _getV2PriceAndReserves(token);
        if (priceV2 > 0) {
            return (tokenAmount * priceV2) / 1e18;
        }

        return 0;
    }

    /// @dev The vault only ever swaps through its own v4 pool, so other pools can only serve as price references.
    function validatePrice(address token, uint256) external view override {
        (bool hasV2Pool, uint256 priceV2, uint112 reserveWETH, ) = _getV2PriceAndReserves(token);
        (bool hasV3Pool, uint256 priceV3, ) = _getV3PriceAndLiquidity(token);

        // A V2 pair only counts as a price reference once it holds real liquidity. Anyone can create a dust pair for
        // any token for almost nothing; trusting its price would let them block every conversion for that token.
        if (hasV2Pool && reserveWETH >= MIN_REFERENCE_WETH && hasV3Pool) {
            (bool isAcceptable, ) = _checkPriceDeviation(priceV2, priceV3);
            if (!isAcceptable) revert PriceDeviationTooHigh();
        }
    }

    // slither-disable-next-line unused-return
    function calculateSwapProportion(
        address, /* token */
        int24 tickLower,
        int24 tickUpper,
        address _poolManager,
        bytes32 poolId
    ) external view override returns (uint256 proportionToSwap) {
        // If no LP position yet (zero ticks), use balanced 50:50 entry
        if (tickLower == 0 && tickUpper == 0) {
            return 5e17; // 50%
        }

        // Skip calculation if poolManager has no code (mock address)
        if (_poolManager.code.length == 0) {
            return 5e17;
        }

        // Get current V4 pool spot price
        (uint160 sqrtPriceX96, , ,) = StateLibrary.getSlot0(IPoolManager(_poolManager), PoolId.wrap(poolId));

        if (sqrtPriceX96 == 0) {
            return 5e17;
        }

        (bool spotValid, uint256 spotProportion) = _computeProportionFromSqrtPrice(sqrtPriceX96, tickLower, tickUpper);
        if (!spotValid) {
            return 5e17;
        }

        // A full-range position holds equal value on both sides, so this is about 50%. The band limits what a moved
        // spot price can do to the split. No other pool can veto a conversion: floors are the keeper's job.
        if (spotProportion < 35e16) spotProportion = 35e16;
        if (spotProportion > 65e16) spotProportion = 65e16;

        return spotProportion;
    }

    /// @dev The share of a batch to swap into the token: the token side's share of the position's value at this price.
    ///      Returns (false, 0) when the position would hold nothing at this price.
    ///      The token amount is converted to ETH value first: the two amounts are in different units.
    function _computeProportionFromSqrtPrice(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        private
        pure
        returns (bool valid, uint256 proportion)
    {
        (uint256 ethAmount, uint256 tokenAmount) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            1e18
        );
        uint256 tokenValue = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(tokenAmount, Q96, sqrtPriceX96), Q96, sqrtPriceX96
        );
        uint256 total = ethAmount + tokenValue;
        if (total == 0) return (false, 0);
        return (true, (tokenValue * 1e18) / total);
    }

    /// @dev Raw price scaled by 1e18. Cannot overflow: sqrtScaled fits 112 bits, and fullMulDiv handles the rest.
    function _rawPrice(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 sqrtScaled = uint256(sqrtPriceX96) >> 48;
        return FixedPointMathLib.fullMulDiv(sqrtScaled * sqrtScaled, 1e18, 1 << 96);
    }

    /// @dev A pool only counts as a price reference with real ETH depth at its current price. Anyone can create a pool
    ///      with 1 wei of liquidity at any price; trusting it would let them block every conversion for that token.
    function _hasReferenceDepth(uint160 sqrtPriceX96, uint128 liquidity, bool ethIsCurrency0)
        private
        pure
        returns (bool)
    {
        uint256 virtualEth = ethIsCurrency0
            ? FixedPointMathLib.fullMulDiv(liquidity, Q96, sqrtPriceX96)
            : FixedPointMathLib.fullMulDiv(liquidity, sqrtPriceX96, Q96);
        return virtualEth >= MIN_REFERENCE_WETH;
    }

    // --- private helpers (moved verbatim from vault) ---

    // slither-disable-next-line unused-return
    function _getV2PriceAndReserves(address token)
        private
        view
        returns (
            bool hasV2Pool,
            uint256 priceV2,
            uint112 reserveWETH,
            uint112 reserveToken
        )
    {
        if (v2Factory.code.length == 0) {
            return (false, 0, 0, 0);
        }

        address pair = IUniswapV2Factory(v2Factory).getPair(weth, token);

        if (pair == address(0)) {
            return (false, 0, 0, 0);
        }

        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();

        if (reserve0 == 0 || reserve1 == 0) {
            return (false, 0, 0, 0);
        }

        address token0 = IUniswapV2Pair(pair).token0();
        bool wethIsToken0 = (token0 == weth);

        if (wethIsToken0) {
            reserveWETH = reserve0;
            reserveToken = reserve1;
            priceV2 = (uint256(reserve0) * 1e18) / uint256(reserve1);
        } else {
            reserveWETH = reserve1;
            reserveToken = reserve0;
            priceV2 = (uint256(reserve1) * 1e18) / uint256(reserve0);
        }

        hasV2Pool = true;
    }

    // slither-disable-next-line calls-loop,unused-return
    function _queryV3PoolForFee(address token, uint24 feeTier)
        private
        view
        returns (
            bool success,
            uint256 price,
            uint128 poolLiquidity
        )
    {
        if (v3Factory.code.length == 0) {
            return (false, 0, 0);
        }

        address pool = IUniswapV3Factory(v3Factory).getPool(weth, token, feeTier);

        if (pool == address(0)) {
            return (false, 0, 0);
        }

        // Verify pool is not locked (reentrancy guard) and has liquidity via slot0/liquidity.
        // We read liquidity for the depth check but derive price from the TWAP, not slot0.
        uint160 spotSqrtPriceX96;
        try IUniswapV3Pool(pool).slot0() returns (
            uint160 sqrtPriceX96,
            int24,
            uint16,
            uint16,
            uint16,
            uint8,
            bool unlocked
        ) {
            if (!unlocked) {
                return (false, 0, 0);
            }
            spotSqrtPriceX96 = sqrtPriceX96;
        } catch {
            return (false, 0, 0);
        }

        try IUniswapV3Pool(pool).liquidity() returns (uint128 liq) {
            if (liq == 0) {
                return (false, 0, 0);
            }
            poolLiquidity = liq;
        } catch {
            return (false, 0, 0);
        }

        address token0 = IUniswapV3Pool(pool).token0();
        if (!_hasReferenceDepth(spotSqrtPriceX96, poolLiquidity, token0 == weth)) {
            return (false, 0, 0);
        }
        // A one-tick position reaches that virtual depth with dust, so it must also hold real WETH.
        try IERC20Balance(weth).balanceOf(pool) returns (uint256 held) {
            if (held < MIN_REFERENCE_WETH) return (false, 0, 0);
        } catch {
            return (false, 0, 0);
        }

        // Derive price from TWAP to prevent flash-loan manipulation of the deviation check.
        // observe() reverts if the pool has insufficient observation history (cardinality == 1
        // or window older than oldest stored observation). In that case we skip the cross-check
        // for this pool rather than falling back to the manipulable spot price.
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSecondsAgo;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int24 meanTick = int24(delta / int56(uint56(twapSecondsAgo)));
            // Round toward negative infinity when remainder is negative (standard V3 TWAP rounding)
            if (delta < 0 && (delta % int56(uint56(twapSecondsAgo)) != 0)) meanTick--;

            uint256 rawPrice = _rawPrice(TickMath.getSqrtPriceAtTick(meanTick));

            if (token0 == weth) {
                if (rawPrice == 0) return (false, 0, 0);
                price = (1e18 * 1e18) / rawPrice;
            } else {
                price = rawPrice;
            }

            return (true, price, poolLiquidity);
        } catch {
            // Pool exists and has liquidity but TWAP window is unavailable (new pool or
            // observation cardinality not yet expanded). Skip this pool for the cross-check.
            return (false, 0, 0);
        }
    }

    function _getV3PriceAndLiquidity(address token)
        private
        view
        returns (
            bool hasV3Pool,
            uint256 priceV3,
            uint128 liquidity
        )
    {
        uint24[3] memory feeTiers = [uint24(3000), uint24(500), uint24(10000)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            (bool success, uint256 price, uint128 liq) = _queryV3PoolForFee(token, feeTiers[i]);

            if (success) {
                return (true, price, liq);
            }
        }

        return (false, 0, 0);
    }

    function _checkPriceDeviation(uint256 price1, uint256 price2)
        private
        view
        returns (bool isAcceptable, uint256 deviation)
    {
        if (price1 == 0 || price2 == 0) {
            return (false, 0);
        }

        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 avg = (price1 + price2) / 2;

        deviation = (diff * 10000) / avg;

        isAcceptable = deviation <= maxPriceDeviationBps;
    }
}
