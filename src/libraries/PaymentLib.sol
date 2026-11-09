// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SmartTransferLib } from "./SmartTransferLib.sol";
import { RevenueSplitLib } from "../shared/libraries/RevenueSplitLib.sol";
import { IAlignmentVault, ClaimMode } from "../interfaces/IAlignmentVault.sol";
import { IMiyaRegistry } from "../registry/interfaces/IMiyaRegistry.sol";

/// @dev The fee-token views of vault v2 (UniAlignmentVault.infer / imd).
interface IVaultFeeTokens {
    function infer() external view returns (address);
    function imd() external view returns (address);
}
import { TokenPrice } from "../factories/interfaces/TokenPrice.sol";

/// @title PaymentLib
/// @notice Multi-token sale accounting shared by the drop, 1155 and auction collections (docs/IMD-INFER-VAULT.md).
///         Every amount is kept per token (address(0) = ETH), in that token's own units; nothing is converted.
///
///         Per token, the collection owes:
///         - `unsplit`:      sale proceeds not yet split (drop, 1155: split by the permissionless `distribute`)
///         - `ownerOwed`:    the artist's share, paid only by the owner's `withdraw` (pull: a blocklisted
///                           artist never blocks a sale, a split or anyone's refund)
///         - `protocolOwed`: protocol cuts the treasury refused, retried with the next cut or `flushPendingProtocolCut`
///         - `vaultOwed`:    vault cuts the vault refused, carried by the next split or `flushPendingVaultCut`
///         - `escrow`:       anything else held for others (auction deposits, live bids, outbid refunds)
///         The collection's balance of a token is always at least the sum of these (`liabilities`).
library PaymentLib {
    address internal constant ETH = address(0);
    /// @notice Most tokens a collection can accept at once (the spec's allowlist has 7).
    uint256 internal constant MAX_TOKENS = 8;


    struct Ledger {
        address[] accepted;
        mapping(address => bool) isAccepted;
        /// @dev Every token ever accepted, append-only (bounded by the registry allowlist). withdrawAll walks it, so a
        ///      token dropped from `accepted` stays withdrawable.
        address[] known;
        mapping(address => bool) isKnown;
        mapping(address => uint256) unsplit;
        mapping(address => uint256) ownerOwed;
        mapping(address => uint256) protocolOwed;
        mapping(address => uint256) vaultOwed;
        mapping(address => uint256) escrow;
    }

    /// @notice The split terms snapshotted at launch.
    struct Terms {
        address vault;
        address treasury;
        uint16 protocolBps;
        uint16 alignmentBps;
    }

    event AcceptedTokensSet(address[] tokens);
    event ProceedsSplit(address indexed token, uint256 toOwner, uint256 toVault, uint256 toProtocol);
    event ProtocolCutParked(address indexed token, uint256 amount);
    event VaultContributionFailed(address indexed token, uint256 amount);
    event VaultContributionRetried(address indexed token, uint256 amount);
    event OwnerWithdrawn(address indexed token, address indexed to, uint256 amount);
    event VaultFeesForwarded(address indexed to, ClaimMode mode, uint256 infer, uint256 imd, uint256 eth);

    error NoTokens();
    error TooManyTokens();
    error DuplicateToken(address token);
    error TokenNotAllowed(address token);
    error TokenNotAccepted(address token);
    error ShortTransfer();
    error WrongValue();
    error NothingParked();
    error NothingToWithdraw();
    error NoFeesToClaim();
    error InvalidPrice();

    // ┌─────────────────────────┐
    // │     Accepted tokens     │
    // └─────────────────────────┘

    /// @dev Replace the accepted list. Each token must be allowlisted in the registry (ETH always is).
    function setAccepted(Ledger storage l, address registry, address[] memory tokens) internal {
        uint256 n = tokens.length;
        if (n == 0) revert NoTokens();
        if (n > MAX_TOKENS) revert TooManyTokens();
        address[] storage old = l.accepted;
        for (uint256 i; i < old.length; ++i) {
            l.isAccepted[old[i]] = false;
        }
        delete l.accepted;
        for (uint256 i; i < n; ++i) {
            address t = tokens[i];
            if (l.isAccepted[t]) revert DuplicateToken(t);
            checkAllowed(registry, t);
            l.isAccepted[t] = true;
            l.accepted.push(t);
            if (!l.isKnown[t]) {
                l.isKnown[t] = true;
                l.known.push(t);
            }
        }
        emit AcceptedTokensSet(tokens);
    }

    /// @dev Reverts unless the registry allowlists `token`. ETH is native and always allowed (the registry also
    ///      reports it as allowed), so ETH sales cost no registry call.
    function checkAllowed(address registry, address token) internal view {
        if (token == ETH) return;
        if (!IMiyaRegistry(registry).isPaymentToken(token)) revert TokenNotAllowed(token);
    }

    /// @dev A token a sale can be paid in right now: accepted by the collection and still on the allowlist (the
    ///      registry can drop a token for new sales; balances already held stay withdrawable).
    function checkUsable(Ledger storage l, address registry, address token) internal view {
        if (!l.isAccepted[token]) revert TokenNotAccepted(token);
        checkAllowed(registry, token);
    }

    /// @dev Validates a price list against the accepted tokens: non-empty, no duplicates, every token accepted.
    function checkPrices(Ledger storage l, TokenPrice[] memory prices, bool allowZero) internal view {
        uint256 n = prices.length;
        if (n == 0) revert NoTokens();
        if (n > MAX_TOKENS) revert TooManyTokens();
        for (uint256 i; i < n; ++i) {
            address t = prices[i].token;
            if (!l.isAccepted[t]) revert TokenNotAccepted(t);
            if (!allowZero && prices[i].price == 0) revert InvalidPrice();
            for (uint256 j; j < i; ++j) {
                if (prices[j].token == t) revert DuplicateToken(t);
            }
        }
    }

    // ┌─────────────────────────┐
    // │        Payments         │
    // └─────────────────────────┘

    /// @dev Take exactly `amount` of `token` from msg.sender. ETH must be msg.value == amount; an ERC-20 is pulled
    ///      with transferFrom (msg.value must be 0) and the balance delta must equal `amount`, so a fee-on-transfer
    ///      or rebasing token can never be booked for more than arrived.
    function collect(address token, uint256 amount) internal {
        if (token == ETH) {
            if (msg.value != amount) revert WrongValue();
            return;
        }
        if (msg.value != 0) revert WrongValue();
        if (amount == 0) return;
        uint256 before = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        if (SafeTransferLib.balanceOf(token, address(this)) - before != amount) revert ShortTransfer();
    }

    /// @dev Split `amount` of `token`: protocol cut to the treasury (parked if refused), vault cut plus anything
    ///      parked to the vault (parked if refused), the rest credited to the owner.
    function split(Ledger storage l, Terms memory t, address token, uint256 amount)
        internal
        returns (RevenueSplitLib.Split memory s, uint256 sentToVault)
    {
        s = RevenueSplitLib.split(amount, t.protocolBps, t.alignmentBps);
        payProtocol(l, t.treasury, token, s.protocolCut);
        sentToVault = sendOrPark(l, t.vault, token, s.vaultCut);
        l.ownerOwed[token] += s.remainder;
        emit ProceedsSplit(token, s.remainder, sentToVault, s.protocolCut);
    }

    /// @dev Pay the treasury this cut and anything parked for the token. A treasury that refuses (a blocklisted
    ///      address, a contract that reverts) is never a reason to hold up a sale: the total is parked.
    function payProtocol(Ledger storage l, address treasury, address token, uint256 amount) internal {
        uint256 total = amount + l.protocolOwed[token];
        if (total == 0) return;
        l.protocolOwed[token] = 0;
        if (!_tryTransfer(token, treasury, total)) {
            l.protocolOwed[token] = total;
            emit ProtocolCutParked(token, total);
        }
    }

    /// @dev Send `amount` plus anything parked to the vault, credited to this collection. A vault that refuses
    ///      (e.g. under its minimum) leaves the total parked for the next split. Returns what was sent.
    function sendOrPark(Ledger storage l, address vault, address token, uint256 amount) internal returns (uint256) {
        uint256 cut = amount + l.vaultOwed[token];
        if (cut == 0) return 0;
        l.vaultOwed[token] = 0;
        if (_trySendToVault(vault, token, cut)) return cut;
        l.vaultOwed[token] = cut;
        emit VaultContributionFailed(token, cut);
        return 0;
    }

    /// @dev Retry a parked vault cut, optionally topped up by the caller (msg.value for ETH, pulled for an ERC-20),
    ///      so a final cut under the vault's minimum can still reach it. Reverts if the vault refuses, returning the
    ///      top-up. Returns the amount sent.
    function flushVault(Ledger storage l, address vault, address token, uint256 topUp) internal returns (uint256) {
        uint256 pending = l.vaultOwed[token];
        if (pending == 0) revert NothingParked();
        collect(token, topUp);
        l.vaultOwed[token] = 0;
        uint256 amount = pending + topUp;
        if (token == ETH) {
            IAlignmentVault(payable(vault)).receiveContribution{ value: amount }(Currency.wrap(ETH), amount, address(this));
        } else {
            SafeTransferLib.safeApproveWithRetry(token, vault, amount);
            IAlignmentVault(payable(vault)).receiveContribution(Currency.wrap(token), amount, address(this));
        }
        emit VaultContributionRetried(token, amount);
        return amount;
    }

    /// @dev Retry a parked protocol cut; reverts if the treasury still refuses.
    function flushProtocol(Ledger storage l, address treasury, address token) internal {
        uint256 pending = l.protocolOwed[token];
        if (pending == 0) revert NothingParked();
        l.protocolOwed[token] = 0;
        if (token == ETH) SafeTransferLib.safeTransferETH(treasury, pending);
        else SafeTransferLib.safeTransfer(token, treasury, pending);
    }

    /// @dev Pay `to` the owner's balance of `token`. Returns the amount (0 if none).
    function payOwner(Ledger storage l, address token, address to, address weth) internal returns (uint256 amount) {
        amount = l.ownerOwed[token];
        if (amount == 0) return 0;
        l.ownerOwed[token] = 0;
        payOut(token, to, amount, weth);
        emit OwnerWithdrawn(token, to, amount);
    }

    /// @dev ETH goes with SmartTransferLib (WETH fallback for wallets that refuse ETH); an ERC-20 with safeTransfer.
    function payOut(address token, address to, uint256 amount, address weth) internal {
        if (amount == 0) return;
        if (token == ETH) SmartTransferLib.smartTransferETH(to, amount, weth);
        else SafeTransferLib.safeTransfer(token, to, amount);
    }

    // ┌─────────────────────────┐
    // │       Vault fees        │
    // └─────────────────────────┘

    /// @dev Claim this collection's vault fees in `mode` and forward everything the claim paid in (INFER, IMD, ETH)
    ///      to `to`, measured by balance deltas. With `requirePaid`, reverts NoFeesToClaim if a TOKENS or ETH claim
    ///      paid nothing (a REINVEST claim pays nothing out by design).
    function claimVaultFees(
        address vault,
        ClaimMode mode,
        uint256 minEthOut,
        address to,
        address weth,
        bool requirePaid
    )
        internal
        returns (uint256 inferOut, uint256 imdOut, uint256 ethOut)
    {
        // The vault's own fee tokens (INFER and IMD on mainnet; other tokens elsewhere). A vault without these views
        // pays ETH only.
        address inferToken = _feeToken(vault, IVaultFeeTokens.infer.selector);
        address imdToken = _feeToken(vault, IVaultFeeTokens.imd.selector);
        uint256 i0 = SafeTransferLib.balanceOf(inferToken, address(this));
        uint256 m0 = SafeTransferLib.balanceOf(imdToken, address(this));
        uint256 e0 = address(this).balance;
        IAlignmentVault(payable(vault)).claimFees(mode, minEthOut);
        inferOut = SafeTransferLib.balanceOf(inferToken, address(this)) - i0;
        imdOut = SafeTransferLib.balanceOf(imdToken, address(this)) - m0;
        ethOut = address(this).balance - e0;
        if (requirePaid && inferOut == 0 && imdOut == 0 && ethOut == 0 && mode != ClaimMode.REINVEST) {
            revert NoFeesToClaim();
        }
        if (inferOut != 0) SafeTransferLib.safeTransfer(inferToken, to, inferOut);
        if (imdOut != 0) SafeTransferLib.safeTransfer(imdToken, to, imdOut);
        if (ethOut != 0) SmartTransferLib.smartTransferETH(to, ethOut, weth);
        emit VaultFeesForwarded(to, mode, inferOut, imdOut, ethOut);
    }

    // ┌─────────────────────────┐
    // │          Views          │
    // └─────────────────────────┘

    function liabilities(Ledger storage l, address token) internal view returns (uint256) {
        return l.unsplit[token] + l.ownerOwed[token] + l.protocolOwed[token] + l.vaultOwed[token] + l.escrow[token];
    }

    /// @dev What this contract holds of `token` beyond what it owes (royalties, direct transfers).
    function untracked(Ledger storage l, address token) internal view returns (uint256) {
        uint256 bal = token == ETH ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));
        uint256 owed = liabilities(l, token);
        return bal > owed ? bal - owed : 0;
    }

    /// @dev Price of `token` in a price list; `found` is false if the list doesn't price it.
    function priceIn(TokenPrice[] storage prices, address token) internal view returns (bool found, uint256 price) {
        for (uint256 i; i < prices.length; ++i) {
            if (prices[i].token == token) return (true, prices[i].price);
        }
    }

    // ┌─────────────────────────┐
    // │        Internals        │
    // └─────────────────────────┘

    /// @dev The vault's fee token from `selector` (infer() / imd()), or address(0) if it has none.
    function _feeToken(address vault, bytes4 selector) private view returns (address t) {
        (bool ok, bytes memory ret) = vault.staticcall(abi.encodeWithSelector(selector));
        if (ok && ret.length >= 32) t = abi.decode(ret, (address));
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        if (token == ETH) return SafeTransferLib.trySafeTransferETH(to, amount, SafeTransferLib.GAS_STIPEND_NO_GRIEF);
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok) return false;
        if (ret.length == 0) return token.code.length != 0;
        return ret.length >= 32 && abi.decode(ret, (uint256)) == 1;
    }

    function _trySendToVault(address vault, address token, uint256 amount) private returns (bool) {
        if (token == ETH) {
            try IAlignmentVault(payable(vault)).receiveContribution{ value: amount }(
                Currency.wrap(ETH), amount, address(this)
            ) {
                return true;
            } catch {
                return false;
            }
        }
        SafeTransferLib.safeApproveWithRetry(token, vault, amount);
        try IAlignmentVault(payable(vault)).receiveContribution(Currency.wrap(token), amount, address(this)) {
            return true;
        } catch {
            SafeTransferLib.safeApprove(token, vault, 0);
            return false;
        }
    }
}
