// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IVaultConfig, IzRouter, SwapCall} from "./IVaultConfig.sol";

/**
 * @title VaultSwaps
 * @notice UniAlignmentVault's guarded aggregator calls and the balancing-swap math, as a linked library: the vault calls
 *         it by DELEGATECALL, so every call, approval and balance is the vault's own (and its receive() sees the same
 *         transient "collecting" flag), while this code stays out of the vault's bytecode (EIP-170).
 * @dev Errors carry the vault's names and so the vault's selectors.
 *      A swap's calldata is chosen by the keeper. What bounds it (docs/IMD-INFER-VAULT.md, AUDIT-NOTES.md):
 *      - the target is allowlisted in the vault factory (Safe-owned; EOAs refused), checked live on every call;
 *      - the vault approves exactly the amount in to the target, and resets the approval to 0 after the call;
 *      - an ERC-20 input's balance must drop by exactly the amount in (a partial fill, an over-pull or a refund of
 *        unspent input reverts); an ETH input is sent as exactly the amount in, as value;
 *      - the output token's balance must rise by at least `minOut`, which must be non-zero;
 *      - the vault is nonReentrant throughout, and receive() books nothing while a swap runs;
 *      - after the batch the vault checks it still holds everything it owes, in every token.
 */
library VaultSwaps {
    error SwapTargetNotAllowed(address target);
    error BadSwapOutput();
    error InputMismatch();
    error InsufficientOutput();
    error ZeroFloor();

    address internal constant ETH = address(0);
    uint256 private constant Q96 = 1 << 96;
    /// @dev = UniAlignmentVault._COLLECTING_SLOT: set while a swap pays the vault, so receive() books nothing.
    uint256 private constant _COLLECTING_SLOT = 0x9fffd68a8e82dadd8810fe84758545b0fb4c40f84b514ef129e417c2e244d1a1;

    /// @dev Run one keeper swap of exactly `amountIn` of `tokenIn` (ETH or an ERC-20) through an allowlisted target.
    ///      `legOnly`: the batch's ETH leg, whose output must be IMD; any other swap may output ETH or IMD.
    function swap(IVaultConfig config, SwapCall memory s, address tokenIn, uint256 amountIn, address imd, bool legOnly)
        external
        returns (uint256)
    {
        if (!config.isSwapTarget(s.target)) revert SwapTargetNotAllowed(s.target);
        if (s.tokenOut != imd && (legOnly || s.tokenOut != ETH)) revert BadSwapOutput();
        return _exec(s.target, tokenIn, amountIn, s.tokenOut, s.data, s.minOut);
    }

    /// @dev An ETH-mode claim's IMD -> ETH: zRouter.swapV4 on the factory's IMD/ETH pool, under the same guards.
    function imdToEth(address zRouter, IVaultConfig config, address imd, uint256 amountIn, uint256 minOut)
        external
        returns (uint256)
    {
        (uint24 fee, int24 tickSpacing) = config.ethPool();
        bytes memory data = abi.encodeCall(
            IzRouter.swapV4, (address(this), false, fee, tickSpacing, imd, ETH, amountIn, 0, block.timestamp)
        );
        return _exec(zRouter, imd, amountIn, ETH, data, minOut);
    }

    // slither-disable-next-line arbitrary-send-eth,low-level-calls
    function _exec(address target, address tokenIn, uint256 amountIn, address tokenOut, bytes memory data, uint256 minOut)
        private
        returns (uint256 amountOut)
    {
        if (minOut == 0) revert ZeroFloor();
        uint256 outBefore = _balanceOf(tokenOut);
        uint256 inBefore;
        uint256 value;
        if (tokenIn == ETH) {
            value = amountIn;
        } else {
            inBefore = _balanceOf(tokenIn);
            SafeTransferLib.safeApproveWithRetry(tokenIn, target, amountIn);
        }

        // Outputs and refunds paid in ETH land in receive(): not contributions.
        _setCollecting(true);
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        _setCollecting(false);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        if (tokenIn != ETH) {
            SafeTransferLib.safeApprove(tokenIn, target, 0);
            if (_balanceOf(tokenIn) + amountIn != inBefore) revert InputMismatch();
        }
        uint256 outAfter = _balanceOf(tokenOut);
        amountOut = outAfter > outBefore ? outAfter - outBefore : 0;
        if (amountOut < minOut) revert InsufficientOutput();
    }

    /// @dev How much of the side in excess to swap so what is left pairs at the pool's ratio after the swap has moved
    ///      its price: the single-sided add formula on the excess against the pool's virtual reserve of that token.
    ///      Returns the direction (true = INFER -> IMD), the amount, and the excess.
    function splitAmount(
        uint256 amtInfer,
        uint256 amtImd,
        uint160 sqrtP,
        uint128 poolL,
        bool inferIsCurrency0,
        uint24 fee
    ) external pure returns (bool inferToImd, uint256 swapAmount, uint256 excess) {
        (uint256 a0, uint256 a1) = inferIsCurrency0 ? (amtInfer, amtImd) : (amtImd, amtInfer);
        bool zeroForOne;
        uint256 reserve;
        (zeroForOne, excess, reserve) = _excess(a0, a1, sqrtP, poolL);
        swapAmount = _balancedSwap(excess, reserve, fee);
        inferToImd = zeroForOne == inferIsCurrency0;
    }

    /// @dev The side in excess (zeroForOne = currency0 in excess), by how much, and the pool's virtual reserve of it.
    function _excess(uint256 a0, uint256 a1, uint160 sqrtP, uint128 poolL)
        private
        pure
        returns (bool zeroForOne, uint256 excess, uint256 reserve)
    {
        // Value of a0 in token1 units: a0 * P, P = (sqrtP / 2^96)^2.
        uint256 a0In1 = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(a0, sqrtP, Q96), sqrtP, Q96);
        if (a1 > a0In1) {
            excess = a1 - a0In1; // token1 in excess: swap token1 -> token0
            reserve = FixedPointMathLib.fullMulDiv(poolL, sqrtP, Q96);
        } else {
            uint256 a1In0 = FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(a1, Q96, sqrtP), Q96, sqrtP);
            excess = a0 > a1In0 ? a0 - a1In0 : 0;
            reserve = FixedPointMathLib.fullMulDiv(poolL, Q96, sqrtP);
            zeroForOne = true;
        }
    }

    /// @dev Bounded by the no-price-impact answer, amount / (2 - fee), which also covers depth too large to compute.
    function _balancedSwap(uint256 amount, uint256 reserve, uint24 fee) private pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 afterFee = 1e6 - fee;
        uint256 feeTerm = 2e6 - fee;
        uint256 bound = FixedPointMathLib.fullMulDiv(amount, 1e6, feeTerm);
        if (reserve == 0 || reserve > 1e30 || amount > 1e30) return bound;
        uint256 root = FixedPointMathLib.sqrt(reserve * (reserve * feeTerm * feeTerm + 4 * afterFee * 1e6 * amount));
        uint256 base = reserve * feeTerm;
        uint256 balanced = root > base ? (root - base) / (2 * afterFee) : 0;
        return balanced < bound ? balanced : bound;
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == ETH ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));
    }

    function _setCollecting(bool collecting) private {
        assembly ("memory-safe") {
            tstore(_COLLECTING_SLOT, collecting)
        }
    }
}
