# Design: bonding-curve editions (mint, burn, trade)

Status: proposal (2026-11-08). Builds on the multi-token editions in IMD-INFER-VAULT.md; code starts after that lands.
Nothing here is built or deployed. Mainnet only.

## Idea

An ERC-1155 edition (music first, any media after) can be launched as a **curve edition**: the next copy's price rises
with supply along a curve, every copy can be **burned** back to the edition's reserve at any time, and copies trade on
public markets (OpenSea) like any ERC-1155. The pattern is EulerBeats' (read from its verified contracts:
`getPrintPrice`, `getBurnPrice`; Genesis 90% reserve / 8% original holder / 2% project, Enigma 84% burn), without the
generative part.

## Agreed

| | Decision |
|---|---|
| Spread | 10% of the mint price by default: the burn pays back 90% of the top copy's price |
| Spread split | 6% of price to the **master holder**, 3% to the **vault** (becomes INFER/IMD liquidity), 1% to the **protocol** |
| Currency | One per edition, from the payment allowlist (ETH, IMD, INFER, USDC, imdUSD, cbBTC, WBTC); the reserve is held in it |
| Markets | Copies and the master are plain ERC-1155 tokens: listable and tradable anywhere |

## Pieces

- **Copies**: token id per edition, supply `s`. Mint the next copy at `P(s+1)`; burn one at `burnPrice(s) = r * P(s)`,
  with `r = 1 - spread` (0.90 by default).
- **Master**: one extra token per curve edition (supply exactly 1), minted to the artist at creation. Whoever holds it
  earns the master share (6% of every mint price). Transferable, so an edition's income stream can be bought and sold.
  ERC-2981 royalties on secondary sales of the copies point at the current master holder.
- **Reserve**: per edition, in the edition's currency, inside the collection contract. No owner, vault, factory or
  registry function can move it. Only `burn` pays out of it.

## Curves (integer maths, fixed at creation)

Two shapes, chosen at launch, both computed exactly so the same inputs always give the same price:

- **Exponential**: `P(n) = P1 * (1 + g)^(n - 1)`, `g` in basis points per copy (via `rpow` in 1e18 fixed point).
- **Linear**: `P(n) = P1 + k * (n - 1)`.

Limits, checked at creation: `maxSupply` 1 to 10,000; `g` up to 500 bps (5% per copy); the creation reverts if
`P(maxSupply)` overflows or exceeds a cap per currency (e.g. 1,000 ETH-equivalent configured per token in the registry);
spread between 5% and 30%.

## Flows

**Mint** `mintCurve(editionId, qty, maxCost)`:
1. Cost = `sum P(s+1 .. s+qty)`; revert if over `maxCost` (front-running guard).
2. Take payment in the edition's currency (ETH `msg.value` exact; ERC-20 `transferFrom` with a balance-delta check).
3. Per copy: `reserve += r * P(i)`; master share `0.06 * P(i)` credited to the **current master holder** (pull);
   vault share `0.03 * P(i)` sent with `vault.receiveContribution(currency, …, this)`; protocol `0.01 * P(i)` booked for the
   treasury (pull). Rounding dust goes to the reserve, never out of it.
4. Mint `qty` copies; `s += qty`.

**Burn** `burnCurve(editionId, qty, minPayout, minSupply)`:
1. Revert if `s < minSupply` or the payout is under `minPayout` (front-running guard).
2. Payout = `sum r * P(s .. s-qty+1)` (the top copies come off the curve, highest first).
3. `reserve -= payout`; burn `qty` from the caller; `s -= qty`; pay the caller.

**Claims**: master holders call `claimMasterEarnings(currency)`; the treasury pulls its share; vault fees follow the
vault's own claim modes.

## Solvency invariant

For every edition: `reserve == sum_{i=1..s} r * P(i)` (plus rounding dust, which only ever adds). Each mint adds exactly
`r * P(s+1)` and each burn removes exactly `r * P(s)` for the top copy, so the reserve can always pay every copy back down
to zero. Proven with fuzzed sequences of mints, burns and transfers per curve shape and currency decimals.

## Alignment rule

The registry's `minAlignmentBps` (10%) applies to what the protocol earns from a sale. For a curve edition that is the
spread, not the price (the reserve is the buyer's money held for the burn). The vault gets 30% of the spread, above the
minimum. The protocol fee is 1% of price, as for other sales.

## Markets

- The burn price is a floor: nobody sells below what the reserve pays, and anyone can buy under it and burn at a
  profit, which pulls market prices back up.
- The next mint price is a soft ceiling: above it, buyers mint instead.
- Market prices settle between the two; traders arbitrage both sides. A mint-then-burn round trip loses the spread, so
  flash loops never profit.

## Contracts

- `ERC1155Instance`: a new edition type `CURVE` beside `OPEN`, `LIMITED_FIXED` and `LIMITED_DYNAMIC`, with the per-edition
  reserve, master token id, curve parameters, `mintCurve`, `burnCurve`, `claimMasterEarnings`, ERC-2981 to the master holder.
- A pure `CurveMath` library (both shapes, sums, limits) so pricing is testable on its own.
- `ERC1155Factory`: accepts curve parameters at `addEdition`; validates limits against the registry.
- Registry: price cap per currency for curve validation.

## App

- **Launch**: "Curve edition" option: currency, shape, start price, growth, max supply, spread (default 10%), with a
  live chart of mint and burn prices and the 6/3/1 split.
- **Edition page**: chart with the current supply marked, Mint (next price, quantity, max cost) and Burn (payout,
  minimum), the master holder and their earnings, OpenSea links for copies and the master.
- **Manage**: master earnings per currency with Claim; reserve shown read-only.

## Test plan

- `CurveMath`: exact prices and sums, both shapes, limits, overflow refusals.
- Edition: mint and burn per currency decimals; slippage guards; master transfer mid-way (earnings go to whoever held
  it at each mint); royalties to the master holder; burning to zero empties the reserve exactly.
- Invariant fuzz: the solvency invariant under random mints, burns, transfers, master sales.
- Fork tests with the real vault routes for the 3% share; `/audit-suite`; independent review.

## Risks

- **Regulatory**: redeemable tokens sold for speculation can raise securities questions in some places; worth a legal
  read before launch.
- **Exponential growth**: limited by the caps above; the chart makes the late prices visible to buyers.
- **Thin currencies**: an edition priced in a thin token is still solvent (the reserve is in that token), but its
  market may be illiquid.
- **Front-running**: covered by `maxCost`, `minPayout` and `minSupply`.
