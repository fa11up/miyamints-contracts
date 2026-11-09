// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 * @title PendingLedger
 * @notice Per-token book of the vault's pending contributions, converted pro rata: a conversion of `amount` out of a
 *         token's `pending` converts the same fraction (amount / pending) of every benefactor's pending balance in that
 *         token, and pays the shares it made to them in proportion. Each benefactor's balance, shares and the fees
 *         those shares earned since they were made are worked out lazily, in O(1) per (benefactor, token), whatever
 *         the number of benefactors or conversions in between.
 * @dev The product-and-sum scheme of Liquity's stability pool, per token:
 *      - `p` is the running product of (remaining / pending) over the token's conversions (PRECISION at the start of an
 *        epoch). A benefactor that booked `amount` when the product was `p0` has `amount * p / p0` pending now.
 *      - `sums.s` accumulates `shares * p / pending` per conversion (the shares one unit booked at p = 1 earns), so the
 *        benefactor's shares are `amount * (s - s0) / p0`.
 *      - `sums.sa[i]` accumulates `shares * p / pending * acc_i / ACC` per conversion (acc_i = the vault's fee index i at
 *        that conversion, where the new shares start earning). The fees the benefactor's not-yet-collected shares
 *        earned are `amount / p0 * ((s - s0) * acc_i / ACC - (sa_i - sa0_i))`: each conversion's shares times the
 *        index growth since that conversion, never the fees from before it.
 *      - Converting everything that is pending starts a new epoch (p back to PRECISION). When `p` would drop under
 *        P_MIN it is multiplied by SCALE and the scale goes up one; a balance spans at most two scales (the one it was
 *        booked in and the next). What would be left after a second scale change (under 1e-9 of the balance) is
 *        dropped, as is a remainder too small for one rescale (under P_MIN / (p * SCALE) of the token's pending: 1e-18
 *        for a fresh pool; the epoch restarts): that dust stays in the
 *        vault's pending total, unowned. Balances are exact to 1 part in P_MIN (1e9) per conversion.
 *      Magnitudes (why PRECISION is 1e18, as in Liquity): `s` grows by shares * p / pending, so a dust pending that
 *      gets a large batch's shares makes it large, and `sa` multiplies it by the fee index. With p <= 1e18, a 1-wei
 *      pending earning 1e30 shares at a fee index of 1e40 (fees of 1e4 per share) still fits 256 bits with room.
 *      Rounding always favours the vault: balances, shares and fees round down, `sa` rounds up. So per token the
 *      benefactors' balances never add up to more than what is pending, and their shares and fees never to more than
 *      what was made and distributed.
 *      External functions on storage pointers: the vault calls them by DELEGATECALL (a linked library), which keeps
 *      this code out of the vault's own bytecode.
 */
library PendingLedger {
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant P_MIN = 1e9;
    uint256 internal constant SCALE = 1e9;
    uint256 internal constant ACC = 1e36;

    struct Sums {
        uint256 s;
        uint256[3] sa;
    }

    /// @dev One token's pool. `p == 0` reads as PRECISION (a token never converted).
    struct Pool {
        uint128 p;
        uint64 epoch;
        uint64 scale;
        mapping(uint256 epochScale => Sums) sums;
    }

    /// @dev One benefactor's balance in one token: what it was at the snapshot, and the pool's state then.
    struct Record {
        uint128 amount;
        uint128 p;
        uint64 epoch;
        uint64 scale;
        uint256 s;
        uint256[3] sa;
    }

    // ── views ───────────────────────────────────────────────────────────────

    /// @notice What `r` has pending now.
    function pendingOf(Pool storage pool, Record storage r) external view returns (uint256) {
        return _pending(pool, r);
    }

    /// @notice What `r` has earned since its snapshot, not yet collected: shares, the fees those shares earned up to the
    ///         fee indexes `acc`, and what is still pending.
    function accrued(Pool storage pool, Record storage r, uint256[3] memory acc)
        external
        view
        returns (uint256 shares, uint256[3] memory fees, uint256 pending)
    {
        (shares, fees) = _earned(pool, r, acc);
        pending = _pending(pool, r);
    }

    // ── writes ──────────────────────────────────────────────────────────────

    /// @notice Collect what `r` earned since its snapshot (returned, for the vault to credit), and snapshot it again at
    ///         the pool's current state with what is still pending. A record with nothing left is deleted.
    function settle(Pool storage pool, Record storage r, uint256[3] memory acc)
        external
        returns (uint256 shares, uint256[3] memory fees, uint256 pending)
    {
        if (r.amount == 0) return (0, fees, 0);
        uint256 p = _p(pool);
        if (r.epoch == pool.epoch && r.scale == pool.scale && r.p == p) return (0, fees, r.amount); // unchanged
        (shares, fees) = _earned(pool, r, acc);
        pending = _pending(pool, r);
        if (pending == 0) {
            _clear(r);
        } else {
            _snapshot(pool, r, pending, p);
        }
    }

    /// @notice Book `amount` more for `r`. The record must be current (just settled) or empty.
    function add(Pool storage pool, Record storage r, uint256 amount) external {
        _snapshot(pool, r, uint256(r.amount) + amount, _p(pool));
    }

    /// @notice A conversion of `amount` out of `pending` (the token's pending total before it) that made `shares`;
    ///         `acc` are the fee indexes the new shares earn from.
    function convert(Pool storage pool, uint256 pending, uint256 amount, uint256 shares, uint256[3] memory acc)
        external
    {
        uint256 p = _p(pool);
        Sums storage z = pool.sums[_key(pool.epoch, pool.scale)];
        uint256 ds = FixedPointMathLib.fullMulDiv(shares, p, pending);
        if (ds != 0) {
            z.s += ds;
            for (uint256 i; i < 3; ++i) {
                if (acc[i] != 0) z.sa[i] += FixedPointMathLib.fullMulDivUp(ds, acc[i], ACC);
            }
        }
        uint256 rem = pending - amount;
        uint256 np = rem == 0 ? 0 : FixedPointMathLib.fullMulDiv(p, rem, pending);
        if (np != 0 && np < P_MIN) {
            np = FixedPointMathLib.fullMulDiv(p * SCALE, rem, pending);
            if (np >= P_MIN) {
                ++pool.scale;
            } else {
                np = 0; // a remainder too small to rescale: dust, the epoch restarts
            }
        }
        if (np == 0) {
            ++pool.epoch;
            pool.scale = 0;
            pool.p = uint128(PRECISION);
        } else {
            pool.p = uint128(np);
        }
    }

    // ── internals ───────────────────────────────────────────────────────────

    function _p(Pool storage pool) private view returns (uint256) {
        uint256 p = pool.p;
        return p == 0 ? PRECISION : p;
    }

    function _key(uint64 epoch, uint64 scale) private pure returns (uint256) {
        return (uint256(epoch) << 64) | scale;
    }

    function _pending(Pool storage pool, Record storage r) private view returns (uint256) {
        uint256 amount = r.amount;
        if (amount == 0 || r.epoch != pool.epoch) return 0;
        uint256 p = _p(pool);
        if (pool.scale == r.scale) return FixedPointMathLib.fullMulDiv(amount, p, r.p);
        if (pool.scale == r.scale + 1) return FixedPointMathLib.fullMulDiv(amount, p, uint256(r.p) * SCALE);
        return 0;
    }

    function _earned(Pool storage pool, Record storage r, uint256[3] memory acc)
        private
        view
        returns (uint256 shares, uint256[3] memory fees)
    {
        uint256 amount = r.amount;
        if (amount == 0) return (0, fees);
        uint256 p0 = r.p;
        Sums storage a = pool.sums[_key(r.epoch, r.scale)];
        Sums storage b = pool.sums[_key(r.epoch, r.scale + 1)];
        uint256 ds1 = a.s - r.s;
        uint256 ds2 = b.s;
        shares = FixedPointMathLib.fullMulDiv(amount, ds1, p0);
        if (ds2 != 0) shares += FixedPointMathLib.fullMulDiv(amount, ds2, p0 * SCALE);
        for (uint256 i; i < 3; ++i) {
            fees[i] = _fee(amount, p0, ds1, a.sa[i] - r.sa[i], acc[i]);
            if (ds2 != 0) fees[i] += _fee(amount, p0 * SCALE, ds2, b.sa[i], acc[i]);
        }
    }

    /// @dev amount / div * (ds * acc / ACC - dsa), rounded down, never negative.
    function _fee(uint256 amount, uint256 div, uint256 ds, uint256 dsa, uint256 acc) private pure returns (uint256) {
        if (ds == 0) return 0;
        uint256 x = FixedPointMathLib.fullMulDiv(ds, acc, ACC);
        return x > dsa ? FixedPointMathLib.fullMulDiv(amount, x - dsa, div) : 0;
    }

    function _snapshot(Pool storage pool, Record storage r, uint256 amount, uint256 p) private {
        Sums storage z = pool.sums[_key(pool.epoch, pool.scale)];
        r.amount = SafeCastLib.toUint128(amount);
        r.p = uint128(p);
        r.epoch = pool.epoch;
        r.scale = pool.scale;
        r.s = z.s;
        r.sa = z.sa;
    }

    function _clear(Record storage r) private {
        r.amount = 0;
        r.p = 0;
        r.epoch = 0;
        r.scale = 0;
        r.s = 0;
        delete r.sa;
    }
}
