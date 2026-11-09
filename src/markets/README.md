# Prediction markets (testnet)

Parimutuel prediction markets denominated in imdUSD. Each market comes from a fixed question template, an AI-swarm
oracle panel resolves it, and disputes go first to a second panel and then to a small human council that can only
pick a coded outcome or VOID.

> **NOT FOR MAINNET.** This code is for testnets only. It must not take real money until **all** of these are done:
>
> 1. A gambling **licence** is held by a legal entity that operates the book.
> 2. Written **counsel sign-off** covers the product, its distribution and the settlement unit.
> 3. A **KYC/geo vendor** is contracted and its key is the eligibility signer (today it is a mock key).
> 4. **imdUSD v2** is live and stable, and the markets point at it (today they use a mock token).
> 5. The **ExitDesk is funded** with real USDC and the global open-interest cap is sized to that funding.
> 6. A **Swarm audit** (and ideally an external audit) of every contract in this folder is complete, with findings fixed.
>
> The deploy script refuses chain ids 1 and 4663.

## Contracts

| Contract | Role | Privileged party |
|---|---|---|
| `PredictionRegistry` | Defaults for **future** markets: recipients, rake split (capped at 5%), caps, minimum stake, lock margin (floored at 180 s), bond sizes, modules. Template and resolver allow-lists, creator + crew registry. Tracks global open interest and refuses a stake that would push it above the ExitDesk's USDC balance. | Owner (multisig). Cannot touch a deployed market. |
| `MarketFactory` | Deploys exact EIP-1167 clones of `ParimutuelMarket`. Builds the question document from the template parts plus slot values, hashes it on chain, snapshots the registry's terms into the clone, and copies the creator and their crew into the clone's deny-list. Emits the full documents. | None. Only registered creators may call it. |
| `ParimutuelMarket` | One pool. `stake`, `stakeFor` (door only), `claim`, `refund`, `finalize`, `voidUnresolved`, `payCreator`, `sweep`. Per-wallet and per-market caps, deny-list, source-clock lock, rake split, creator escrow, one-year sweep. | None. Only its snapshotted resolver, dispute module and council can move the state machine. |
| `SwarmResolver` | Verifies swarm-panel attestations (see below). Tier `Primary` proposes; tier `Dispute` (a separate deployment with larger panel floors) reports the second panel's answer to the dispute module. | None. Authority is the oracle signature only. |
| `DisputeModule` | Bonded disputes: bond = max(minBond, bondBps of the pool). Second panel agrees, so the proposal stands; it disagrees or stays silent for 3 days, so the market escalates. Losing bond: 50% to the proposer, 50% to the treasury. | None. |
| `CouncilResolver` | Fixed member set, majority threshold (3 of 5 in the design). Votes on chain for a coded outcome or VOID on escalated markets, within the market's 7-day window. Can also vote to slash a creator's escrowed fee and bond. | Its members, within those limits. |
| `EligibilityGate` | Verifies short-lived EIP-712 eligibility passes (wallet, issuedAt, expiresAt; at most 1 day; domain binds chain and contract). Revocation per wallet. Only `stake` is gated. | Owner rotates the signer; owner or signer revokes wallets. |
| `UsdcDoor` | USDC to imdUSD at market through an `IUsdcSwapper`, then `stakeFor` in one transaction. Records each wallet's USDC deposited. | None. |
| `ExitDesk` | Pays imdUSD to USDC 1:1 only while the peg feed reads below $0.995 (and is fresh), per wallet up to its door deposits minus what it has already been paid. The owner cannot withdraw USDC below the open-interest cover. | Owner (multisig): fund, withdraw the excess, withdraw imdUSD bought, set the feed. |

## Lifecycle

```
                 stake / stakeFor (pass + caps + deny-list)
                 ┌───────┐
                 ▼       │
   create ──▶  OPEN ─────┘
                 │ block.timestamp >= lockAt (no transaction)
                 ▼
              LOCKED ──── no proposal by resolveAfter + 7 d ──────────────────────▶ VOID (timedOut)
                 │ primary SwarmResolver: verified answer (+ attested start)
                 ▼
             PROPOSED ─── dispute window passes ── finalize() ──▶ FINAL, or VOID if code 0 / no winner
                 │ DisputeModule.dispute() + bond, inside the window
                 ▼
             DISPUTED ─── 2nd panel agrees ────────────────────▶ FINAL / VOID (as proposed)
                 │ 2nd panel disagrees, or silent for 3 d
                 ▼
             ESCALATED ── council: threshold votes for a code or VOID ──▶ FINAL / VOID
                 │ no decision in 7 d
                 ▼
               VOID (timedOut)

   FINAL: claim() pays winners; refund() pays late stakes; rake legs paid at once, creator leg vests 7 d.
   VOID:  refund() pays every stake in full; no rake.
   FINAL or VOID + 365 d: sweep() sends whatever is left to the treasury.
```

**Lock on the source clock.** Source-clock templates carry a second question for the event's official start
(unix seconds). The proposal carries that attested start, and every stake timestamped after
`attestedStart - lockMargin` is refunded instead of counted (`lockMargin >= 180 s`). Stakes after `lockAt` are
refused outright.

**Payout.** With counted pools `C[i]`, winner `w` and losing side `L = sum(C) - C[w]`, the rake is
`L x (treasury + creator + resolver + insurance bps)`. A winner's counted stake `s` pays `s + s x (L - rake) / C[w]`,
rounded down. The rounding dust (at most 1 wei per winner) is swept after a year. If nobody counted on the winning
outcome, the market voids.

**Outcome codes.** Outcomes are 1-based and 0 always means VOID, for the answer code, the proposal and the council.
A template maps an answer to an outcome in one of three modes:

- `Coded`: `codeMap[code]` gives the outcome, e.g. `1 home, 2 away, 3 draw, 4 postponed, 5 abandoned` maps to `[_, 1, 2, 0, 0, 0]` for a two-way market.
- `Bool`: true is outcome 1, false is outcome 2.
- `Threshold`: an answer above the market's threshold is outcome 1, otherwise outcome 2 (totals; the line stays out of the hashed question).

## Swarm attestations: how `SwarmResolver` maps to the real format

The resolver reuses the verification core of the open-source oracle co-op hub and proposal guard:

- **Struct and domain.** Field for field, the plane's `OracleAttestation(bytes32 requestId, uint256 chainId, bytes32 questionHash, uint8 answerType, bytes answer, uint256 figure, uint64 fromBlock, uint64 toBlock, bytes32 blockHash, bytes32 panelJobId, uint16 panelSize, uint16 quorum, uint16 agreed, uint64 issuedAt, uint64 expiresAt)` under the EIP-712 domain `("IdentityMD Oracle", "2", chainId, verifyingContract)`. `test/markets/SwarmResolver.t.sol` replays a real production signature and recovers the service key.
- **Binding to the resolver.** `verifyingContract` is the consumer named in the oracle request, so a request must name the resolver that will receive it (primary or dispute tier). A signature bought for any other consumer or chain does not verify.
- **Binding to the market.** The question document is the template's canonical JSON up to `,"window":{"fromBlock":`. The resolver checks `keccak256(prefix) == market.questionHash` and then that the signed `questionHash` equals `prefix ‖ fromBlock ‖ ,"toBlock": ‖ toBlock ‖ }}`. One character of difference is refused.
- **Absolute counts.** `panelSize >= minPanel`, `quorum >= minQuorum` and `agreed >= quorum`. The service has signed attestations whose `agreed` fell below the requested `quorum`, so the resolver re-checks it. Floors are counts, never ratios.
- **Timing.** `issuedAt >= resolveAfter` (an answer signed before the event ended is refused), not expired, request id unused.

Mismatches with the design, and how they are handled:

1. **The start time is not in the signed struct.** An attestation carries one answer. The source-clock lock therefore
   uses a second question (the template's `startParts`, answered in unix seconds), bought in the same oracle group
   order and submitted together with the answer.
2. **The window is in data-chain blocks.** Event questions are not about a block range, so the window only has to be
   well formed. Event timing is bound by `issuedAt` instead.
3. **`figure`** is not used. Answers are read from `answer` (32 bytes) only.

## Shared interface with the sports-book front end

The template and market fields line up with the front end's market model:

| Front-end market field | On chain |
|---|---|
| `question` (exact text the panel is asked) | template `parts` + slots, `questionHash` on the market, full text in `MarketCreated` |
| `outcomes` (labels, in display order) | `outcomeCount`, outcome numbers 1..n in the same order (labels stay off chain) |
| answer codes (`1 = home, 2 = away, 3 = draw...`) and the void rule | `answerMode` + `codeMap` (0 = VOID) |
| `line` on totals | `threshold` (answer > threshold is "over") |
| `closes` ("at the game's attested start") | `lockAt` + template `startParts` + `lockMargin` |
| `kind` (`main`, `total`, `window`, `creator`) | template `name` |
| `FEE` | `rake` legs (snapshotted) |
| `MAX_PER_WALLET` | `perWalletCap` |
| `PANEL {size, quorum}` | primary `SwarmResolver` `minPanel` / `minQuorum` |
| `status` (`open`, `locked`, `settled`, `void`) | `state()` (`Open`, `Locked`, `Proposed`..`Escalated`, `Final`, `Void`) |
| `pools` | `outcomePool(i)` |

## Trust assumptions

- **Oracle key.** Whoever holds the oracle service key can propose any coded outcome. Disputes, the second panel
  and the council bound the damage. The resolver never trusts the requested quorum; it re-checks the counts.
- **Council.** A threshold of members can pick any coded outcome or VOID for an escalated market and slash a
  creator's escrow and bond. It cannot send stakes anywhere but to stakers, and it is silent outside escalations.
- **Registry owner.** It can change only what **future** markets snapshot. It can also move the global exit-cover
  rule (by pointing at another desk), which affects whether new stakes are accepted but never moves funds.
- **Eligibility signer.** It can admit or refuse new stakers. It cannot stop claims or refunds. The gate is the one
  module that is live rather than snapshotted, so a compromised signer can be rotated for open markets.
- **ExitDesk owner.** It holds the desk's USDC, but cannot withdraw it below the open-interest cover. A cash-out can
  still bring the balance below the open interest; then new stakes are refused until it recovers.
- **No admin path moves user funds.** Markets have no owner. Rake legs, the creator's vested share and the one-year
  sweep go to the snapshotted recipients only.
- **First valid answer wins.** Any valid attestation for a market's question can be submitted, and the first one
  proposes. A conflicting later answer is what disputes are for.

## What is mocked here

- **imdUSD**: `MockImdUSD` (18 decimals, no permit, open mint). **USDC**: `MockUSDC` (6 decimals).
- **Swap**: `MockUsdcSwapper` behind `IUsdcSwapper` (settable rate and above-peg toll). A real implementation must quote the toll.
- **Peg price**: `MockPegPriceFeed` behind `IPegPriceFeed`.
- **KYC/geo signer**: any key (the broadcaster by default).
- **Council**: the broadcaster alone (1 of 1) by default.
- **Oracle**: the real service key by default. Tests sign with a local secp256k1 key.

The mocks live in `test/markets/mocks/`.

## Deploying to a testnet

```
forge script script/markets/DeployMarketsTestnet.s.sol --rpc-url $SEPOLIA_RPC_URL        # dry run
```

Sepolia is the default target. Robinhood Chain has a testnet (chain id 46630), but the oracle service currently
signs only for consumers on Ethereum, Sepolia and Robinhood Chain mainnet, so a resolver there could not receive
real attestations. All parameters are read from the environment; see the script header.
