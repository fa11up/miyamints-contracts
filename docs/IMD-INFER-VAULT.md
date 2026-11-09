# Design: multi-token sales, aligned to the INFER/IMD pool

Status: agreed decisions, built on branch design/imd-infer-vault, not deployed (2026-11-08). Mainnet (chain 1) only.
Revised 2026-11-08: conversions run keeper-built aggregator calldata (0x, zRouter fallback) instead of a route table.

## Decisions

| | Decision |
|---|---|
| Payment tokens | ETH, IMD, INFER, USDC, imdUSD, cbBTC, WBTC |
| Prices | The artist sets a price per token they accept (no exchange rates in the contracts) |
| Artist revenue | Collected exactly as paid, per token. No conversions |
| Protocol fee | Taken in the token paid (1%), collected per token by the treasury |
| Vault share | Taken in the token paid, sent to the vault as is; the vault turns everything into INFER/IMD liquidity |
| Auctions | One currency per auction, chosen by the artist or curator; bids, refunds and the deposit in that currency |
| Vault fee claims | Default: take as tokens (INFER + IMD). Also: take as ETH, or reinvest |
| Chains | Mainnet only for now |
| Keeper batch | Minimum 0.1 ETH of value, adjusted for gas cost |
| Conversion swaps | On chain in the vault, along aggregator calldata from the keeper: 0x (AllowanceHolder, taker = the vault), zRouter as the fallback the keeper builds itself. Allowlisted targets only |

## Tokens (mainnet, read from chain 2026-11-08)

| Token | Address | Decimals |
|---|---|---|
| ETH | native (`address(0)`) | 18 |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` (BridgedFP: plain ERC-20, no fee, no pause) | 18 |
| INFER | `0x53d0eA0A685220718Dc6a0a6e4617194C6F37921` | 18 |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 |
| imdUSD | `0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25` | 18 |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 8 |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` | 8 |

The registry keeps the allowlist (`isPaymentToken(token)`), owner-managed. Collections refuse anything not on it.
USDC and WBTC have admin blocklists: a blocklisted recipient makes a transfer revert. Payouts are pull-based (the
artist withdraws), so a blocklist never blocks a sale or another person's refund.

## The pools the vault uses (v4 liquidity read 2026-11-08)

| Pool | Key | Liquidity |
|---|---|---|
| **INFER/IMD** (the alignment pool) | INFER (c0) / IMD (c1), fee 12500, spacing 60, hook `0x784F…6000` (`PoolInitializationGuard`: beforeInitialize only) | 7.62e23 |
| IMD/ETH | ETH / IMD, fee 10000, spacing 200, no hook | 9.73e21 |
| imdUSD/IMD | imdUSD / IMD, fee 3000, spacing 60, no hook | 2.73e21 |
| ETH/USDC | fee 500, spacing 10, no hook | 1.54e17 |
| ETH/WBTC | fee 500, spacing 10, no hook | 1.29e17 |
| cbBTC | v4 ETH/cbBTC is thin (3000/60: 1.28e14); v3 cbBTC/WETH 0.3% `0x15aA…7C3b` is deeper (1.04e15) | |

## Conversions (to IMD; INFER and IMD need none)

The keeper brings the swap for each token as calldata for an allowlisted target: **0x** first (it calls the 0x API off
chain with `taker` = the vault and gets AllowanceHolder calldata), **zRouter** as the fallback it builds itself on the
pools below. The vault runs each call itself; nothing leaves it except through these calls.

| Paid in | Swap (to the vault) | zRouter fallback pool |
|---|---|---|
| IMD | none | |
| INFER | none: used as the INFER side directly | |
| imdUSD | -> IMD | imdUSD/IMD (v4 3000/60) |
| USDC | -> ETH, joins the batch's ETH leg | ETH/USDC (v4 500/10) |
| WBTC | -> ETH, joins the batch's ETH leg | ETH/WBTC (v4 500/10) |
| cbBTC | -> ETH, joins the batch's ETH leg | cbBTC/WETH (v3 0.3%, zRouter unwraps) |
| ETH (the leg) | all the batch's ETH -> IMD in one swap | IMD/ETH (v4 10000/200), `swapAmount` 0 = all of msg.value |
| IMD -> INFER (the split) | the vault itself, through `PoolManager.unlock` | INFER/IMD (v4, hooked; no router can route a hooked pool) |
| IMD -> ETH (claims as ETH) | the vault, through zRouter `swapV4` on the factory's `ethPool` | IMD/ETH (v4 10000/200) |

Each token's swap outputs ETH or IMD. Every token swapped to ETH joins the batch's ETH: the vault then sends ALL of a
batch's ETH (pending ETH net of the keeper reward, plus those outputs) to IMD in one swap (the ETH leg) and shares its
output pro rata to each token's ETH in, so the order tokens are listed in changes nothing (as long as no two tokens'
swaps share a pool, which the keeper keeps so). A token swapped to IMD (imdUSD) is valued by its own IMD out.

The guards on every keeper swap (`VaultSwaps`), since the calldata is the keeper's:

- the target is on the vault factory's allowlist (`setSwapTarget`, owner = a Safe; EOAs, the tokens, the PoolManager
  and the registry are refused), checked live on each call; the keeper can't add one;
- the vault approves exactly the amount in to the target, and resets the approval to 0 after the call;
- an ERC-20 input's balance must drop by exactly the amount in: a partial fill, an over-pull or a refund of unspent
  input reverts (`InputMismatch`); ETH in is sent as exactly the amount, as value;
- the vault's balance of `tokenOut` (ETH or IMD; the leg's must be IMD) must rise by at least `minOut`, which must be
  non-zero (`ZeroFloor`, `InsufficientOutput`);
- nonReentrant throughout; ETH arriving during a swap is never booked as a contribution;
- after the batch, everything owed (fees, protocol cut, every pending token) is still held, or the call reverts.

ETH the leg hands back (a refund, a router's stray balance) is ETH beyond what is owed: dust for the holders before the
batch, as before. The minimum per ERC-20 contribution (`minContribution`, 0 = none; deployed at ~0.001 ETH worth each:
USDC 2, IMD 1, INFER 3,500, imdUSD 3, WBTC/cbBTC 3,000 sats) lives in the vault factory too. The keeper supplies
`minOut` for every swap and for the leg from live quotes, through a private mempool. No on-chain price reference exists
for these pools (v4 has no TWAP), so the keeper floors are the protection, as today.

## Sale flow (collections)

- A collection has an `acceptedTokens` list and a price per token (`priceOf[token]`), set by the owner; each must be on
  the registry allowlist. Phases (drops) and editions (1155) carry a price per token the same way.
- `mint(qty, token, maxCost)`: ETH via `msg.value`; ERC-20 via `transferFrom` of exactly `price * qty` (fee-on-transfer
  tokens are not on the allowlist; the contract still checks the balance delta and reverts if short).
- The split happens per token, as today for ETH: protocol cut -> treasury balance for that token (pull); vault share ->
  `vault.receiveContribution(token, amount, address(this))`; the rest -> the collection's balance for that token.
- `withdraw(token)` pays the owner that token's balance. `withdrawAll()` loops the accepted tokens.
- Music editions with a rising price (LIMITED_DYNAMIC): each token's price rises by the same rule.
- Auctions: `currency` fixed at creation (artist or curator chooses). The deposit, every bid, outbid refunds, the
  settle split and the unsold reclaim are all in that currency. ETH auctions keep today's behaviour exactly.
- Refunds of outbid bidders: ETH keeps `forceSafeTransferETH`; ERC-20 refunds are pull-based (credited, claimed by
  the bidder) so a blocklisted or reverting bidder can never stop a higher bid.

## Vault

### Contributions and batches

- `receiveContribution(Currency currency, uint256 amount, address benefactor)`: accepts ETH (at least 0.001) or any
  token on the registry allowlist (at least its `minContribution`; no route needed); books the benefactor's pending
  balance in that token and the vault's `pendingByToken[token]`. The registry allows at most 15 ERC-20s, so ETH and
  every allowed token fit the vault's 16 distinct pending tokens.
- `convertAndAddLiquidity(ConvertParams)` (keeper only) converts one batch: any non-empty subset of the pending tokens
  (no duplicates, any order), exactly `amounts[i]` of each (0 < amount <= pending). Unlisted tokens, and whatever
  arrived after the keeper read the amounts, stay pending for a later batch, so a contribution landing mid-flight can't
  break the call.
  1. Take the amounts out of pending. Keeper reward from the ETH converted (0.0012 ETH, capped at 1% of it); 0 if no
     ETH is converted.
  2. Each listed token through its keeper swap (`swaps[i]`, guarded as above): to IMD (imdUSD) gives its IMD; to ETH
     (USDC, WBTC, cbBTC) gives ETH. Then ONE ETH -> IMD swap (`ethLeg`) for all the batch's ETH (converted ETH net of
     the reward + those swaps' ETH), floored by its `minOut`; each token's IMD value is the leg's output times its
     share of the ETH in. IMD counts as is; INFER at the realized rate of step 3.
  3. Swap the balanced part of the free IMD/INFER (beyond fees owed and beyond what is still pending) in the INFER/IMD
     pool (vault-side swap), floor from the keeper.
  4. Add INFER + IMD full range (spacing 60) to the vault's single INFER/IMD position. Leftover stays for next batch.
  5. Issue shares: the batch's shares (its own share of the added liquidity, at the share price before the add;
     INFER/IMD left from earlier batches or sent in is added too but raises every holder's share) are split across its
     tokens by realized IMD value; each token's part goes to
     that token's benefactors pro rata to their pending balance in it (each balance converts by amount / pending),
     from the fee indexes as they stand after step 1's fee collection (`PendingLedger`: O(1) per benefactor and token,
     collected lazily). A benefactor with several tokens pending, some converted, gets exactly the shares of what was
     converted and keeps the rest pending.
- Shares are never redeemable for liquidity (permanent), only for fees, as today.

### Fees and claims

- The position earns INFER and IMD. Two accumulators (`accInferPerShare`, `accImdPerShare`) with per-benefactor
  checkpoints; 1% of each goes to the protocol (`withdrawProtocolFees(token)`). ETH dust keeps an ETH accumulator.
- `claimFees(ClaimMode mode, uint256 minEthOut)`, paid to the benefactor or its delegate:
  - `TOKENS` (default): send INFER and IMD.
  - `ETH`: swap the claim INFER -> IMD (vault-side) -> ETH (zRouter `swapV4` on the factory's `ethPool`, default
    10000/200, under the same balance guards), check `minEthOut` (non-zero), send ETH.
  - `REINVEST`: add the claim's INFER + IMD to the position and issue shares at the current share price.
- Collections: `claimVaultFees(mode, minEthOut)` (owner only) forwards whatever the vault pays to `owner()`.

## Interfaces (fixed for the build)

```solidity
enum ClaimMode { TOKENS, ETH, REINVEST }

// IAlignmentVault (v2)
function receiveContribution(Currency currency, uint256 amount, address benefactor) external payable;
function pendingOf(address benefactor, address token) external view returns (uint256); // after any partial conversions
function claimFees(ClaimMode mode, uint256 minEthOut) external returns (uint256 inferOut, uint256 imdOut, uint256 ethOut);
function claimable(address benefactor) external view returns (uint256 infer, uint256 imd, uint256 eth);

// UniAlignmentVault: keeper only
struct SwapCall {            // src/vaults/uni/IVaultConfig.sol
    address target;          // allowlisted swap target (0x AllowanceHolder or zRouter); also the approval spender
    address tokenOut;        // ETH (address(0)) or IMD only
    bytes data;              // calldata for target (value = amount in when the token is ETH)
    uint256 minOut;          // the vault's balance of tokenOut must rise by at least this; must be > 0
}
struct ConvertParams {
    address[] tokens;        // non-empty subset of openBatchTokens(), no duplicates, any order
    uint256[] amounts;       // per token: exactly this much converts, 0 < amount <= pendingByToken(token)
    SwapCall[] swaps;        // one per token; ignored (may be empty) for ETH, IMD, INFER
    SwapCall ethLeg;         // the batch's single ETH -> IMD swap (tokenOut IMD); required when any ETH reaches it
    uint256 minSplitOut;     // the INFER/IMD balancing swap's total output (non-zero if it swaps)
    uint256 deadline;
}
function convertAndAddLiquidity(ConvertParams calldata p) external returns (uint256 sharesIssued);
function openBatchTokens() external view returns (address[] memory); // tokens with something pending, any order
function config() external view returns (address);                  // the vault factory (IVaultConfig)
event TokenConverted(uint256 indexed batchId, address indexed token, uint256 amountIn, uint256 imdValue);
event EthLegSwapped(uint256 indexed batchId, uint256 ethIn, uint256 imdOut);
error SwapTargetNotAllowed(address target); error BadSwapOutput(); error InputMismatch();
error InsufficientOutput(); error ZeroFloor(); error Insolvent(address token);

// UniAlignmentVaultFactory (IVaultConfig, owner = Safe)
function setSwapTarget(address target, bool allowed) external;          // refuses EOAs, INFER, IMD, PoolManager, registry
function isSwapTarget(address target) external view returns (bool);
event SwapTargetSet(address indexed target, bool allowed);
function setEthPool(uint24 fee, int24 tickSpacing) external;            // default 10000 / 200
function ethPool() external view returns (uint24 fee, int24 tickSpacing);
function setMinContribution(address token, uint256 amount) external;    // ERC-20s; 0 = none
function minContribution(address token) external view returns (uint256);

// Registry
function isPaymentToken(address token) external view returns (bool);
function setPaymentToken(address token, bool allowed) external; // onlyOwner; at most 15 ERC-20s (TooManyPaymentTokens)

// Collections (drop, 1155, auction)
function acceptedTokens() external view returns (address[] memory);
function withdraw(address token) external;              // onlyOwner; address(0) = ETH
function claimVaultFees(ClaimMode mode, uint256 minEthOut) external; // onlyOwner
```

## Keeper (an off-chain service)

- Watches each vault's pending value per token; converts when the batch is worth at least 0.1 ETH and gas is under the
  ceiling (both config), each included token at exactly the amount it read.
- Per token, gets a 0x quote (AllowanceHolder, `taker` = the vault, sell exactly the amount) or, when 0x has no route
  or fails, builds zRouter calldata on the table's pool; the leg likewise, built to sell its whole msg.value (zRouter
  `swapAmount` 0; for 0x, quoted for the expected ETH). Sets each `minOut` from the quote less a slippage margin (the
  leg's after its feeding swaps'), simulates the whole call, then sends through a private RPC. Guard rails: kill switch, gas ceiling, ETH floor, spend ledger, unknown-outcome handling.
- Leaves a token out (it stays pending) when no target quotes it, its price impact is over `MAX_IMPACT_BPS` (3%), or,
  for USD tokens (USDC, imdUSD), it pays more than `MAX_REFERENCE_DEVIATION_BPS` (3%) under 1 USD priced through
  ETH/USDC and IMD/ETH. Floors only protect against slippage from the live quote; the reference catches a pool that is
  far off market (2026-11-08: imdUSD/IMD sits at IMD = 4.17 imdUSD vs ~2.47 at market, its only liquidity out of
  range). If the ETH leg is over the impact limit, its largest inputs are left out until it is not.

## App

- **Mint and bid**: a token picker with the artist's accepted tokens and their prices; approve (or permit) for ERC-20s;
  "Pay with another token" swaps into one of the accepted tokens first via 0x, when the buyer holds none of them.
- **Launch**: accepted tokens and a price per token; for auctions, one currency.
- **Manage**: balances per token with Withdraw; vault fees claimable in INFER and IMD with the three claim modes.
- **Copy**: what the vault share becomes, per-token prices, that artists collect each token as paid.

## Test plan

- Unit, per collection type and per token (ETH, 6-decimal, 8-decimal, 18-decimal): payment, split, withdraw, refunds,
  dynamic price, phases; auctions in ETH and in an ERC-20, outbid refunds (push for ETH, pull for ERC-20), settle,
  reclaim.
- Vault: each token's swap, every guard on the keeper's calldata (a failing case each: zero floor, unlisted target,
  wrong output, under-delivery, output sent elsewhere, partial pull, over-pull, refunded input, reentry, a target
  touching another pending token), realized-rate share issuance across mixed batches and every order, two-token
  accumulators, the three claim modes, reinvest share pricing, protocol cut per token, leftovers, dust.
- Invariants: no balance owed beyond what is held, per token; shares and fees per share never decrease.
- Fork tests against the real pools: every token through zRouter calldata, the AllowanceHolder flow with a Settler
  stand-in, a mixed batch, order independence, a subset batch, each claim mode.
- `/audit-suite contracts`, then an independent review before mainnet.

## Risks

- **Scope**: every collection's payment code changes; the ETH-only hardening has to be redone per token.
- **Vault exposure** to IMD and INFER; two-hop conversions cost pool fees on the swapped part.
- **Thin pools**: cbBTC and small pools; the keeper sizes batches and picks the route per batch (0x, or zRouter).
- **Keeper-chosen calldata**: bounded by the guards above; within them a dishonest keeper can still sell a batch at
  its own floors (AUDIT-NOTES.md, vault v2).
- **Token admin powers**: USDC/WBTC blocklists, cbBTC custody; handled by pull payouts, and the allowlist can drop a
  token for new sales (existing balances stay withdrawable).
