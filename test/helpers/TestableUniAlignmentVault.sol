// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {UniAlignmentVault} from "../../src/vaults/uni/UniAlignmentVault.sol";
import {LiquidityAmounts} from "../../src/libraries/v4/LiquidityAmounts.sol";
import {MockToken} from "../vaults/mocks/VaultMocks.sol";

/// @notice Vault v2 with the alignment pool simulated in place of PoolManager (no v4 needed): a fixed price
///         (`setMockPool`), swaps at that price minus the pool fee, LP adds that take what the liquidity needs, and fees
///         the test accrues (`accrueFees`) paid on the next position change. INFER and IMD must be MockTokens.
///         The real PoolManager path is covered by the mainnet fork tests (test/fork/).
contract TestableUniAlignmentVault is UniAlignmentVault {
    address internal constant SINK = address(0xdead);
    uint256 internal constant MQ96 = 1 << 96;

    uint160 public mockSqrtP;
    uint128 public mockPoolL;
    uint256 public pendingFee0;
    uint256 public pendingFee1;

    function setMockPool(uint160 sqrtPriceX96, uint128 otherLiquidity) external {
        mockSqrtP = sqrtPriceX96;
        mockPoolL = otherLiquidity;
    }

    /// @notice Fees in currency0 / currency1 the position will have earned at its next change.
    function accrueFees(uint256 fees0, uint256 fees1) external {
        pendingFee0 += fees0;
        pendingFee1 += fees1;
    }

    function _poolState() internal view override returns (uint160, uint128) {
        return (mockSqrtP, mockPoolL + uint128(totalLPUnits));
    }

    function _poolSwap(bool zeroForOne, uint256 amountIn) internal override returns (uint256 out) {
        if (amountIn == 0) return 0;
        uint256 afterFee = amountIn * (1e6 - _poolKey.fee) / 1e6;
        uint256 s = mockSqrtP;
        out = zeroForOne
            ? FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(afterFee, s, MQ96), s, MQ96)
            : FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(afterFee, MQ96, s), MQ96, s);
        address tIn = Currency.unwrap(zeroForOne ? _poolKey.currency0 : _poolKey.currency1);
        address tOut = Currency.unwrap(zeroForOne ? _poolKey.currency1 : _poolKey.currency0);
        SafeTransferLib.safeTransfer(tIn, SINK, amountIn);
        MockToken(tOut).mint(address(this), out);
    }

    function _poolModify(int256 liquidityDelta)
        internal
        override
        returns (uint256 used0, uint256 used1, uint256 fees0, uint256 fees1)
    {
        if (liquidityDelta > 0) {
            (used0, used1) = LiquidityAmounts.getAmountsForLiquidity(
                mockSqrtP,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                uint128(uint256(liquidityDelta))
            );
            if (used0 != 0) SafeTransferLib.safeTransfer(Currency.unwrap(_poolKey.currency0), SINK, used0);
            if (used1 != 0) SafeTransferLib.safeTransfer(Currency.unwrap(_poolKey.currency1), SINK, used1);
        }
        (fees0, fees1) = (pendingFee0, pendingFee1);
        (pendingFee0, pendingFee1) = (0, 0);
        if (fees0 != 0) MockToken(Currency.unwrap(_poolKey.currency0)).mint(address(this), fees0);
        if (fees1 != 0) MockToken(Currency.unwrap(_poolKey.currency1)).mint(address(this), fees1);
    }
}
