# Internal audit notes (for external review)

Status of the internal-audit findings. Line numbers refer to the
pre-fix tree (commit 88641a8). The regression tests below are ports of the internal PoC tests, which
demonstrated each fixed bug on 88641a8; here they assert the fixed behaviour.

| ID | Finding | Status |
|----|---------|--------|
| H1 | `UniAlignmentVault.claimFees` / `claimFeesAsDelegate` revert with `Reentrancy()` once the LP accrues native-ETH fees: `PoolManager.take(ETH)` and the zRouter token->ETH swap pay into `receive()`, which runs the `nonReentrant` contribution path. All LP yield unclaimable. | Fixed |
| H2 | Fee watermark model (`shareValueAtLastClaim`) dilutes unclaimed fees when new shares are minted (diluted part stranded forever) and resets a benefactor's watermark on re-contribution, erasing all their unclaimed fees. `ERC721DropInstance.withdraw()` is permissionless, so anyone could trigger the wipe. | Fixed |
| H3 | Conversion caller reward = `(100k + 15k*n) * tx.gasprice + 0.0012 ETH`, paid from the vault's general balance, i.e. from benefactors' fees. A builder/validator-set gas price drains the vault. | Fixed |
| M1 | `MiyaPool` RANDOM mode: once the outcome block hash is public, a depositor can steer which id a pending commit receives by depositing before reveal (contradicts MiyaPool.sol:41-42). | Fixed |
| M2 | Vault swaps are sandwichable: `convertAndAddLiquidity(minOutTarget)` accepts any caller-chosen floor (e.g. 1), and the fee token->ETH swap has `minEthOut = 0` when the validator has no TWAP data. Fork test on a real pool (CULT): `validatePrice` passed throughout while a 5 ETH pre-buy cut a 1 ETH swap to 33% of its normal output and a 25 ETH pre-buy to about 0%. Effectively High. | Fixed (keeper only) |
| M3 | `protocolTreasury` was never settable in production (factory owns the vault, no passthrough), locking the 1% LP-yield cut. | Fixed |
| M4 | Factory owner could repoint any vault's V4 pool key at any time; hooks were not checked. | Fixed |
| M5 | `PasswordTierGatingModule`: no factory calls `configureFor`, so a collection that picks it could not be configured. | Not fixed; off at deploy, external review asked to confirm |
| M6 | `ERC721AuctionInstance.settleAuction` used `_safeMint`; a contract winner whose `onERC721Received` reverts froze settlement (artist proceeds, vault cut, the line's queue). | Fixed |
| M7 | `ERC1155Instance` lacked `supportsInterface` / `uri` / `balanceOfBatch`, so `MiyaPoolFactory._detectKind` reverted for miyamaker 1155 collections. | Fixed |
| L1 | `renounceOwnership` on instances makes `owner() == address(0)`; artist share then goes to `address(0)` (Drop `withdraw()` is permissionless). | Fixed (renounce disabled) |
| L2 | `ERC721DropInstance.mintedInPhase` survived `setPhases`, applying old counts to unrelated new phases. | Fixed |
| L3 | `ERC1155Instance.claimFreeMint` ignored the edition `openTime`. | Fixed |

## What changed

**H1** — `receive()` returns early while a transient flag (`_COLLECTING_SLOT`, TSTORE/TLOAD) is set; the flag
wraps only the internal collection (`_claimVaultFees`) and the keeper's two swaps. One TLOAD keeps 2300-gas
`transfer` senders working. The v1 test that showed it on a real `PoolManager` was deleted with v1. Vault v2 keeps the
flag around every swap; tests: `test_routerRefund_isDustForCurrentHolders`, `test_guard_ethSentDuringASwapIsNotAContribution`
(`test/vaults/`), and on a mainnet fork `test_fork_claim_eth` (`test/fork/UniAlignmentVaultFork.t.sol`) and
`test_fork_oneWeiInRouterDoesNotBlockConversion` (`test/deploy/DeployMiyamints.t.sol`). Native-ETH LP fees no longer
arise (the v2 position is INFER/IMD).

**H2** — MasterChef-style accounting: `accFeePerShare` (1e36 scale) + per-benefactor `feeCheckpoint` and
`settledFees`. Pending fees are settled before every share change (`_distributeSharesAndCleanup`).
`convertAndAddLiquidity` force-collects LP yield before minting new shares, so fees accrued before a join stay
with existing holders. A per-share-index checkpoint (rather than a rounded reward debt) means each payout rounds
down once, so `sum(claims) <= fees distributed` exactly. The v1 tests were deleted with v1; the same properties on v2:
`test_fees_notDilutedByLaterBatch`, `test_fees_survivesRecontribution`, `test_partial_laterConversionTakesNoEarlierFees`
(`test/vaults/UniAlignmentVault.t.sol`), `invariant_claimsWithinDistributed` and `invariant_monotonic`
(`test/vaults/UniAlignmentVaultInvariant.t.sol`), and on a fork `test_fork_secondBatch_doesNotTakeEarlierFees`.

**H3** — Reward = `min(CONVERSION_REWARD = 0.0012 ETH, 1% of the pending batch)`, carved out of the batch before
the swap/LP (no `tx.gasprice` term, never from general balance). A rejected reward is distributed to
shareholders as fees. v2 tests (the v1 ones were deleted): `test_reward_cappedAtOnePercentOfBatchEth`,
`test_reward_zeroWithoutEth`, `test_reward_rejectedGoesToHolders`; solvency after every conversion is
`invariant_solventPerToken`.

**M3** — `protocolTreasury()` is now a view of `registry.treasury()` (follows `MiyaRegistry.setTreasury`). The
vault's other owner-only setters were unreachable (owner = factory, no passthrough) and were removed rather than
wired: `setAlignmentToken` (incompatible with an immutable pool key), `setStandardConversionReward` (H3),
`setMaxPriceDeviationBps`, `setDustDistributionThreshold`, `setProtocolYieldCutBps`, `setProtocolTreasury`,
`recordAccumulatedFees` (credited fees without ETH — insolvency). `depositFees` became a permissionless donation
to current shareholders (requires shares).

**M4** — `setV4PoolKey` is set-once and requires `hooks == address(0)`. The factory sets the key inside
`deployVault` (native ETH / alignment token, the factory's zRouter fee tier and tick spacing — the pool zRouter
swaps on); `setVaultPoolKey` was removed.

**M6** — Settlement self-calls `safeMintWinner` in `try`; on failure the token is minted to the instance and
`escrowedWinner[tokenId]` can pull it to any address with `claimEscrowedToken`.

**M7** — Added ERC165 `supportsInterface` (ERC165, ERC1155, ERC1155MetadataURI), `uri(id)`, `balanceOfBatch`, and
`to != address(0)` checks on transfers. Test creates a `MiyaPool` for an `ERC1155Instance` and deposits.

**Lows** — `renounceOwnership` reverts on Auction, Drop and 1155 instances; Drop per-wallet counters are keyed by
a `phasesEpoch` bumped in `setPhases` (`mintedInPhase(phaseId, minter)` view kept); `claimFreeMint` checks
`openTime`.

**M1** — RANDOM pools keep ids in a deposit-order queue. Each commit records the queue end, draws only from
`[head, queueEnd)`, and swaps a picked id with the head, so that range stays exactly the ids it could draw minus those
already drawn. Reveals must run in commit order (`nextRevealId`). Once a target block is mined the pick is fixed: later
deposits and reveal order cannot move it. Ordered reveals could let one commit block the rest, so the recipient cannot
be zero, a commit is capped at `MAX_COMMIT_UNITS` (50), and an id the collection refuses to transfer goes to
`escrowedTo` (`claimEscrowed`). Tests: `test/pools/MiyaPool.t.sol`.

**M2** — `convertAndAddLiquidity` and the new `convertFeeTokens` are limited to `MiyaRegistry.conversionKeeper`, which
submits through a private mempool with floors from a live quote. Claims no longer swap: `claimFees` was open to anyone
and swapped fee tokens with a zero floor when the validator had no price, so token-side fees now wait in
`pendingFeeTokens`. They convert before any share mint, which keeps H2's guarantee. (v2 has no fee-token conversion:
fees are paid in the tokens earned.) The v1 test was deleted; v2 tests: `test_convert_keeperOnly`, `test_claimEth`
(zero floor refused), `test_guard_zeroFloorRefused`, and on a fork `test_fork_keeperFloors`.

## Drop additions after the internal audit

These were added after the findings above, so the internal audit did not cover them. Tests:
`test/factories/erc721drop/ERC721Drop.t.sol`.

- **`ownerReserve`** (`InitParams`, immutable): `ownerMint` can mint only this many pieces in total, and phases can't
  sell the unused part, so `totalSupply + (ownerReserve - ownerMinted) <= maxSupply` always holds. It limits
  `ownerMint` only: the owner can still add a free phase with `setPhases`, as before.
- **`Phase.supplyCap`**: the most a phase can sell; 0 = no cap. Counts are scoped to the phase list, so `setPhases`
  resets them, including when it resubmits the same list. A cap therefore binds the owner only while the list stands;
  `maxSupply` and the reserve always hold.
- **`mintTo`**: mints to another wallet. The allowlist and per-wallet limit apply to the payer, not the recipient. It
  uses `_mint`, so the recipient gets no callback.
- **`lockRoyalty`**: permanently stops `setRoyalty`. Drops only: Auction and 1155 instances have no ERC-2981 support.
- **Royalty cap** (2026-11-07): `MAX_ROYALTY_BPS = 1000`. The constructor and `setRoyalty` revert `RoyaltyTooHigh`
  above 10%, the cap the app promises; both emit `RoyaltySet(receiver, bps)`. Before, only solady's
  10000 bps ceiling applied, so an owner could set 100% after launch. Test: `test_royaltyCappedAtTenPercent`.
- **Metadata events**: `setMetadata` emits EIP-4906 `BatchMetadataUpdate(1, maxSupply)` and `supportsInterface` reports
  `0x49064906`. `ERC1155Instance.updateEditionMetadata` emits the standard `URI` event.

## Parked vault cuts can be topped up (2026-11-07)

`UniAlignmentVault.receiveContribution` rejects anything under `MIN_CONTRIBUTION` (0.001 ETH). A collection's last
split can park a cut under that, and with nothing left to sell no later split carries it, so it stranded.
`ERC1155Instance.retryVaultContribution` and `ERC721DropInstance.flushPendingVaultCut` are now `payable`, like
`ERC721AuctionInstance.flushPendingVaultCut` (dd1a98c): the parked cut plus `msg.value` goes to the vault, credited to the
collection, and a total still under the minimum reverts, which returns the ETH. Both still revert when nothing is
parked. `VaultContributionRetried` reports the full amount sent. Tests:
`test_RetryVaultContribution_DustCanBeToppedUpToReachTheVault`, `test_RetryVaultContribution_ToppingUpNothingParkedReverts`,
`test_flushPendingVaultCut_topUpGoesToTheVaultForTheDrop`.

## External audit round 1 (pools, vaults, registry and factories at a991e8c)

Fixed, with regression tests. The vault findings were reproduced on a mainnet fork with the real zRouter and PoolManager
(`test/deploy/DeployMiyamints.t.sol`) before fixing:

- **Swap proportion mixed units** (High): `calculateSwapProportion` divided ETH wei by ETH wei plus token units, so every
  conversion after the first swapped 35% or 65% and stranded about 30% of the batch. It now compares value: about 50%
  for a full-range position at any price, still clamped to 35-65%.
- **zRouter refund blocked conversions** (High): zRouter refunds its whole ETH balance to the payer after an ETH swap, so
  1 wei sent to the router made `receive()` revert every conversion. The swap now runs in collecting mode.
- **Leftovers** (Low): an LP add can't use every wei. Each
  conversion works from all the ETH and tokens the vault holds beyond what it owes, so leftovers feed the next batch,
  which gets them as a small windfall in LP shares (those can only earn yield). ETH sent to the vault outside
  contributions ends up here too.
- **Price overflow, dust reference pools, TWAP orientation** (High x3): prices use `fullMulDiv`. A v3 or v4 pool only
  counts as a reference with at least 10 ETH of virtual depth at its current price. `calculateSwapProportion` no longer
  compares against a TWAP, which removes both the griefing path and the inverted comparison. `validatePrice` now only
  compares v2 against v3 when both have depth: its v4 lookup, unreachable TWAP branch and v2-capacity check are gone,
  because the vault only ever swaps through its own v4 pool (a dust v2 pair could otherwise block a thin v4 pool).
- **`deployVault`** (Medium): owner only. A permissionless vault could carry a validator that blocks its conversions.
- **Auction settlement gas** (Medium) and **pool reveal gas** (Low): the winner mint and reveal transfers have a gas cap,
  and too little gas reverts instead of forcing a token into escrow. The largest reveal fits mainnet's transaction gas
  cap at worst, so a recipient can't block the ordered queue.
- **CREATE3 salts** (Medium): the auction and 1155 factories bind the salt to the creator and to the factory.
- **Pool hardening** (Low): a second hook for a held id reverts, a safe mint into a pool reverts (it credited
  `address(0)`), the pool can't be a recipient, kind detection follows ERC-165, and claiming an escrowed auction token
  into a pool credits the winner.
- **Parked vault cuts** (Low): they go with the next split on all three sale paths, so small ones add up past the
  vault's minimum. A final residue under 0.001 ETH can stay parked if a collection never sells again.
- **1155 `withdraw`** (Low): anyone can call it, matching the Drop, so the cuts never wait on the artist.

Accepted or deferred:

- **RANDOM pools on Robinhood Chain (4663) are not safe to offer.** The chain runs on Arbitrum's stack: `block.number` is
  an estimate of the Ethereum block, `blockhash` is documented as "cryptographically insecure" and not to be relied on
  for randomness, and the EIP-2935 lookup always fails there, so the window is 256 blocks. Mainnet is unaffected. `MiyaPoolFactory` refuses
  RANDOM on 4663; TARGETED pools still open there. It needs a different source of randomness before that can change.
- **Gating module**: it gates nothing even if configured: the no-password tier is open, and the "password" is a public
  hash. `FREE_MINT_ONLY` and `claimFreeMint` bugs are latent behind it. It stays off at deploy and needs a redesign
  before it is enabled.
- **Griefing a reference pool needs real capital, not none.** A griefer who keeps 10 WETH (recoverable) in a v3 pool at a
  wrong price can block a token that also has a 10+ WETH v2 pair. INFER has neither.
- **1155 `withdraw(amount)` can be front-run** now that anyone can call it: the artist's exact-amount transaction reverts,
  a retry works, and no funds are at risk.
- **Auction anti-snipe has no cap**: a high bidder can keep a line open by paying the increment and gas every window.
  Anyone can outbid. Creators choose the increment.
- **Info items left as they are**: a committer's own same-transaction deposits count toward its draw range; re-arming an
  earlier commit can change a later pick; a collection that refuses by returning silently leaves an id untracked; a
  pool's name and permit domain read the collection live; the Permit2 infinite allowance; token id `0xfbb67fda52d4bfb8bf`
  can't be pooled; the registry owner can lower the alignment floor for future launches only; `DynamicPricingModule` is
  accepted as a gating module; 1155 mints skip the receiver hook.

## Final review round (deployment and fixes, at 7906d3d)

Fixed:

- **Batch size could freeze a vault** (High): a conversion looped over every contributor, and 500 fresh ones needed more
  than mainnet's transaction gas cap. It now records one share rate per batch and each benefactor collects theirs the
  next time they are touched (`_collected`, `_settleFees`), so a conversion costs the same for any number of
  contributors. The participant cap and the griefing around it are gone, along with dust share bookkeeping: shares
  round down when collected, so a few wei of `totalShares` belong to nobody and their fee share stays in the vault.
  `benefactorShares` and `pendingETH` are now views that include an uncollected batch.
- **Dust fee tokens blocked the keeper** (Medium): a floor of 0 now leaves fee tokens pending. A keeper could use this to
  skip real fee tokens before a share change, moving some yield to new holders: part of keeper trust below.
- **Next contributor's windfall** (Medium): the swap uses the single-sided add formula against the pool's virtual ETH
  depth, then measures what is left and goes again, up to three passes (`_swapAndAdd`), so a batch pairs its own ETH even
  when liquidity outside the current range absorbs the swap at a better price than the formula assumes. Leftovers feed
  the next batch. Accepted edge: on a batch far larger than the pool, a position tuned to the batch can still make a later
  pass over-swap and leave tokens for the next batch. On a harness with a 100 ETH batch against 4.87 ETH of depth, the
  next 30 ETH contributor got 29% of shares where 15% is normal, and the position's owner about 0.8 ETH; at 10 ETH the
  worst tried left 1.5% of the batch. Principal stays in the LP. The keeper must simulate each conversion, and convert
  often enough that batches stay small against the pool.
- **Depth floor** (Low): a v3 reference must also hold 10 WETH, so a one-tick position can't pass it with dust.
- **Deploy script** (Low): `OWNER` and mainnet or 4663 `TREASURY` must have code; the alignment pool must have
  `minPoolEth` of depth at its current price (a narrow position reaches that cheaply, so it only stops an unseeded or dust
  pool), and the script prints depth and price for a human to check. `DEPLOY.md` gives a seeding procedure.
- **Fork tests** (Low, Info): they use the real pool once it exists, and now convert fee tokens and claim through the real
  zRouter. Two regressions that could no longer fail were removed; unit tests cover what they claimed.

## Notes for the reviewer

- **Keeper trust (M2).** The keeper must simulate each conversion: swap size depends on the pool's state, and `minOutTarget`
  is the tokens bought across all passes. The keeper's floors are the only price protection. A malicious keeper, or whoever holds its
  key, can sandwich its own conversion with low floors and take up to the whole batch being converted. It can also stop
  converting (ETH and fee tokens wait; the owner can replace it). It can also sandwich `convertFeeTokens` (or `minEthOutForFees`) with a 1-wei floor and take the pending fee tokens,
  which are yield holders already earned. It cannot touch earlier LP positions or settled ETH fees.
- **`minOutTarget` only catches an upward price move.** If someone sells the token into the pool just before the keeper's
  quote, the quote already reflects the low price, the floor passes, and the vault adds liquidity at that price. The
  attacker's buy-back realises the position's impermanent loss. Thin pools and predictable conversions make this worse:
  seed deep, convert through a private mempool, and check the price against an outside reference before converting.
- **`validatePrice` compares v2 spot against a v3 TWAP.** Someone who pays arbitrage to keep a v2 pair more than 5% off during
  the keeper's blocks can delay conversions for as long as they fund it. Delay only: no funds move. It needs a token with
  both a deep v2 pair and a deep v3 pool, which INFER doesn't have.
- **`validatePrice` is a backstop, not a guarantee.** It cross-checks v2 against v3 only when both have real depth. INFER
  has no v2 or v3 pool at all, so it checks nothing there. Safety rests on the keeper's floors.
- **Default alignment token is INFER**, which needs a hookless ETH pool seeded before deployment (DEPLOY.md).
- **RANDOM re-rolls remain**: a commit left unrevealed past the block-hash window is re-armed, and block producers can
  influence the hash. Both are documented in `MiyaPool.sol`.

- Fee collection is still gated by `vaultFeeCollectionInterval` (1 day) for claims, but forced on every
  conversion. Uncollected LP yield is not reflected in `getUnclaimedFees` until collected.
- Shares per ETH now differ slightly between batches (each batch pays its own ≤1% reward); the share-ordering
  invariant tolerance accounts for this.

---

## Vault v2: multi-token, aligned to the INFER/IMD pool (2026-11-08, not yet reviewed)

Spec: `docs/IMD-INFER-VAULT.md`. `UniAlignmentVault` and `UniAlignmentVaultFactory` were replaced in place (nothing was
deployed); the v1 notes above describe the hardening it keeps. New review surface:

- **Contributions** (`receiveContribution(Currency, amount, benefactor)`): ETH (`msg.value == amount`, 0.001 ETH minimum,
  also via `receive()`), or an ERC-20 that is on `MiyaRegistry.isPaymentToken` (no route needed since the aggregator
  change). The vault pulls the ERC-20 from msg.sender and reverts unless its balance grew by exactly `amount`, and
  refuses less than the token's `minContribution` in the factory (owner-set, 0 = none; the deploy sets ~0.001 ETH worth
  per token). At most 16 distinct tokens pending, and per benefactor (the registry allows at most 15 ERC-20s).
- **Conversion** (keeper only, `ConvertParams{tokens, amounts, swaps, ethLeg, minSplitOut, deadline}`, revised twice on
  2026-11-08: subsets after the keeper build's fork runs, then aggregator calldata; see below): any non-empty subset of
  the pending tokens, no duplicates, any order, and exactly `amounts[i]` (0 < amount <= pending) of each. Collect the
  position's fees for current holders; take the amounts out of pending; reward 0.0012 ETH capped at 1% of the ETH
  converted (0 without ETH); each token through its keeper-built `SwapCall` (0x AllowanceHolder or zRouter calldata,
  guarded, see "Aggregator calldata"). A swap outputs IMD (valued on its own) or ETH: all ETH (converted ETH net of the
  reward + every swap's ETH out) goes to IMD in ONE swap (`ethLeg`, `EthLegSwapped`), its IMD attributed pro rata to
  each token's ETH. Then the free INFER/IMD (beyond fees owed AND beyond what is still pending) is balanced and added full range,
  up to 3 passes. INFER is valued at the balancing swap's realized rate (pool price if no swap). Shares = liquidity
  units, split per token by realized IMD value. ETH beyond fees, pending and the reward is dust for current holders. A
  solvency check (`balance >= fees owed + protocol cut + pending`, for INFER, IMD and ETH; and, after a conversion,
  balance >= pending for every token still open) ends every conversion and claim.
- **Pending ledger** (`PendingLedger`, linked library): per token a pro-rata pool. Converting `a` of `P` pending
  converts the fraction a/P of every benefactor's balance in it and pays that token's shares pro rata, in O(1) per
  (benefactor, token): Liquity's product-and-sum (product p of remaining/pending with epochs and a scale factor, sum s of
  shares per unit, and per fee index a sum sa of shares x fee index at each conversion, so lazily collected shares earn
  only the fees after their conversion). Rounding: balances, shares and fees down, `sa` up. A holder's shares round down by
  up to its pending in raw units / p (<= 1e-15 of them in the tests); balances are exact to 1 part in 1e9 per conversion; a remainder that can't be rescaled (< 1e-18 of pending in a fresh pool) or a balance across two
  rescales (< 1e-9 of it) is dropped as unowned dust that stays in `pendingByToken`. Magnitudes: `s` grows by
  shares x p / pending, so a dust pending that gets a big batch's shares grows it fast; with p <= 1e18 a 1-wei pending
  earning 1e30 shares at a fee index of 1e40 still fits. An overflow there would revert conversions of that token (the
  keeper can leave it out) and benefactor touches; the invariant handler found one with p = 1e36 (a 3-sat conversion
  taking 3e25 of leftover liquidity at a mock fee index of 7.6e54), which is why p is 1e18.
- **Why the revision**: on a mainnet fork, (1) one token whose route couldn't absorb its pending amount blocked every
  batch (the call had to convert exactly `openBatchTokens()`); (2) ETH, USDC, WBTC and cbBTC each ran their own ETH ->
  IMD swap in turn, so order changed shares (block 26,371,711: cbBTC -0.40% going last vs first, ETH +0.41% first vs
  last); (3) any 1-unit contribution in a new token between quote and landing made the call revert `BadParams`; (4) more
  of a listed token arriving before landing was converted under floors sized for less. Now: subsets, exact amounts
  (top-ups and new tokens stay pending, so the call can't be broken), one ETH leg (identical shares in any order, on the
  fork), per-token minimums.
- **Vault config** lives in the vault factory (`IVaultConfig`, owner = Safe), read live by every vault: the swap-target
  allowlist, per-token minimums and the ETH-claim pool. The route table is gone (see "Aggregator calldata").
- **Code size**: the vault is 23,426 bytes (EIP-170 limit 24,576; margin 1,150), `VaultSwaps` 3,344, the factory 3,673 (runtime). The guarded swap and the balancing math are in a
  linked library (`VaultSwaps`, by DELEGATECALL: calls, approvals and the transient "collecting" flag are the vault's
  own) and the ledger in `PendingLedger`. Both are deployed once and linked into the implementation the factory
  deploys (forge links them in tests and scripts; `keeper/scripts/fork-e2e.mjs` links by hand).
- **Pool key** fixed at deploy; the hook may only hold initialize permissions (no swap, liquidity, donate or delta
  flags) and the fee must be static, checked in `initialize`.
- **Fees**: INFER and IMD index per share (1% protocol cut each, `withdrawProtocolFees(token)`) and an ETH dust index
  (rejected rewards, refunds; no cut). `claimFees(mode, minEthOut)`: TOKENS pays INFER + IMD (+ ETH dust); ETH swaps
  INFER -> IMD in the pool and IMD -> ETH through zRouter `swapV4` on the factory's `ethPool` (default 10000/200; the
  same balance guards, but the target is the factory's fixed zRouter, not the allowlist), `minEthOut` must be non-zero and is the
  claimant's only protection; REINVEST balances and adds the claim to the position (shares at the current share price),
  `minEthOut` is then the minimum shares, and what the add can't use stays claimable. `claimFeesAsDelegate` takes
  TOKENS or ETH. Claims and reinvests are permissionless for one's own fees, so their swaps are sandwichable up to the
  claimant's floor; they cannot touch anyone else's balance.
- **Removed from v1**: the price validator (no on-chain reference exists for these pools), `pendingFeeTokens` /
  `convertFeeTokens` (fees are paid in the tokens earned, so the keeper never swaps them), `depositFees`.
- **Leftovers** from earlier adds (INFER/IMD the balancing could not pair) and strays are added with the next batch,
  but belong to the holders before it (see "Audit-suite fixes"). Pro rata means a late top-up is converted in part with the rest (its
  holder's balance shrinks by the same fraction as everyone's), not first-in-first-out.
- Tests: `test/vaults/` (unit with a simulated pool: subsets, exact amounts, several tokens per benefactor partly
  converted, the merged ETH leg and order independence, griefing after the quote, minimums, rescale and dust paths;
  `UniAlignmentVaultSwaps.t.sol`: every swap guard with a failing case, and all 24 orders of a 4-token batch over two
  targets; invariants with random subsets, partial amounts and orders, plus misbehaving swaps that must revert:
  per-token solvency, claims within distributed, monotonic shares and fee indexes, pending balances against an
  independent pro-rata model) and `test/fork/UniAlignmentVaultFork.t.sol` (real pools through zRouter calldata built in
  the test: each token, a 7-token batch from 7 benefactors, order independence, a subset batch with a half-converted
  token, keeper floors including the leg, the real 0x AllowanceHolder with a Settler stand-in, real swaps generating
  fees, each claim mode, reinvest pricing).

---

# Scope: prediction markets (`src/markets/`, testnet only)

A new, separate scope, added on branch `contracts/markets`. **Not for mainnet**: see the gate list in
`src/markets/README.md` (licence, counsel sign-off, KYC vendor, imdUSD v2 live, ExitDesk funded, Swarm audit).
Nothing here shares state with the launchpad contracts above.

| Contract | Review focus |
|---|---|
| `ParimutuelMarket.sol` | stake checkpoints, cutoff by attested start, settlement and rake maths, claim/refund/sweep, creator escrow |
| `SwarmResolver.sol` | EIP-712 attestation verification, question splice, absolute-count quorum |
| `DisputeModule.sol`, `CouncilResolver.sol` | escalation state machine, bond settlement, council limits |
| `PredictionRegistry.sol`, `MarketFactory.sol` | snapshotting, template validation, slot sanitising, EIP-1167 clone, open-interest cap |
| `EligibilityGate.sol` | pass verification, revocation |
| `UsdcDoor.sol`, `ExitDesk.sol` | door deposits, 1:1 exit limits, cover rule |

Tests are in `test/markets/`: unit tests, fuzz tests, an invariant suite over random stake / lock / propose /
dispute / panel / council / claim / refund / sweep sequences, and a replay of a real production oracle signature.

## Collections v2: multi-token sales (2026-11-08, not yet reviewed)

Drops, 1155 editions and auctions take any token on the registry allowlist (`isPaymentToken`); see
docs/IMD-INFER-VAULT.md. Earlier sections describe the ETH-only collections; where they name a function, read it as below.

- Proceeds are booked per token as `unsplitProceeds[token]`. `distribute(token)` is permissionless and does the split
  (protocol cut to the treasury, vault cut to `vault.receiveContribution(token, …)`, the rest to `ownerBalance[token]`), so
  nobody can hold the cuts back. `withdraw(token)` is owner-only and runs `distribute` first. `withdrawAll()` walks every
  token ever accepted, so a delisted token stays withdrawable.
- The 1155's `retryVaultContribution` is now `flushPendingVaultCut(token, topUp)`, the same on all three types. Parked cuts
  (`pendingProtocolCut[token]`, `pendingVaultCut[token]`) are per token. `sweepUntrackedETH` is now `sweepUntracked(token)`.
- ERC-20 payments: `maxCost` is required, `msg.value` must be 0, exactly the cost is pulled and the balance change checked
  (`ShortTransfer` refuses fee-on-transfer tokens). The vault is approved for exactly the cut, and the approval is reset if
  the call fails.
- Auctions: one currency per auction collection, fixed at creation. ETH auctions keep the old push paths. ERC-20 outbid
  refunds are pull (`refundOf`, `claimRefund(to)`), so a blocklisted bidder cannot stop a higher bid; `escrowed(token)`
  equals deposits, live bids and refunds owed.
- `claimVaultFees(mode, minEthOut)` forwards the INFER, IMD and ETH that arrived, by balance change. INFER and IMD are
  mainnet constants in PaymentLib.
- Factory size: the factories store the instance init code in SSTORE2 data contracts (`InitCodeStore`) to stay under
  EIP-170. A collection now costs about 1.3M more gas to create.
- Deploy: `script/config/1.json` holds `paymentTokens`, `swapTargets`, `ethPool` and `minContributions`; the script sets
  them before the ownership handoff and `_checkPayments` confirms each (see "Aggregator calldata").

## Audit-suite fixes (2026-11-08)

- **Leftovers no longer go to the next batch.** INFER/IMD already free before a conversion (earlier leftovers, strays)
  is still added to the position, but the batch is issued shares only for its own value, priced once the leftover's
  liquidity is in (`_batchShares`, `_sharesFor`), so holders before the batch keep all of it (shares <= liquidity
  units, as the invariant already allowed). `BatchConverted` reports shares issued. Reinvest also mints at the share price. A first batch (no shares yet) takes everything.
- **Fee tokens from the vault.** Collections forward the vault's own `infer()` / `imd()` (read per claim), not mainnet
  constants, so fees forward on any chain.
- **`withdrawAll` skips a token that can't pay out** (and emits `WithdrawSkipped`) instead of reverting for all.
- **Auctions get `sweepUntracked(token)`** for the auction currency, like the other collections.
- **Dynamic pricing rounds up**, so a tiny base price can't mint below price.
- Not fixed, by decision: an issuer blocklist (USDC) on the vault makes that token's splits revert (approve outside the
  try).

## Vault v2: aggregator calldata replaces the route table (2026-11-08, not yet reviewed)

Decision (2026-11-08): conversions still happen on chain in the vault, but the swap path comes from the keeper as
aggregator calldata: **0x** (AllowanceHolder `0x0000000000001fF3684f28c67538d4D072C22734`; the keeper calls the 0x API
off chain with `taker` = the vault) with **zRouter** (`0x000000000000FB114709235f1ccBFfb925F600e4`) as the fallback
calldata the keeper builds itself. The per-token route table (`setRoute`, `getRoute`, `hasRoute`, `routedTokens`,
`RouteHop`, `VaultSwaps.route`) is gone; `receiveContribution` only needs the token on the registry allowlist.

```solidity
struct SwapCall { address target; address tokenOut; bytes data; uint256 minOut; }
struct ConvertParams { address[] tokens; uint256[] amounts; SwapCall[] swaps; SwapCall ethLeg; uint256 minSplitOut; uint256 deadline; }
```

**The calldata is keeper-chosen. What bounds it** (`VaultSwaps.swap` / `_exec`, each with a failing test in
`test/vaults/UniAlignmentVaultSwaps.t.sol`):

| Guard | Failing case (test) |
|---|---|
| Target on the vault factory's allowlist (`setSwapTarget`, Safe-owned; refuses EOAs, INFER, IMD, the PoolManager, the registry, the factory), read live per call; the keeper can't add one | `test_guard_targetMustBeAllowlisted` (unlisted contract, a token as target, the leg), `test_targetRemovedAtConversion_reverts`, `test_setSwapTarget_refusesEoasAndVaultInternals`, `test_setSwapTarget_onlyOwner` |
| Output is ETH or IMD; the leg's is IMD | `test_guard_outputMustBeEthOrImd_legMustBeImd` |
| `minOut` non-zero (fixes the zero-floor finding for good) | `test_guard_zeroFloorRefused` |
| Exact approval of the amount in, to the target only | `test_guard_pullBeyondApprovalFails`; on the fork `test_fork_allowanceHolder_operatorCannotTakeMoreThanTheAmount` |
| Approval reset to 0 after the call | `test_guard_approvalResetAfterTheCall` (a token whose transferFrom keeps the allowance), `test_aggregator_erc20ToEth_andLeg` (expects both approve calls) |
| ERC-20 input drops by exactly the amount in (partial fills, refunds of unspent input, over-pulls revert `InputMismatch`) | `test_guard_pullLessRefused`, `test_guard_refundOfUnspentInputRefused`, `test_guard_overPullRefused` |
| Output measured by the vault's own balance change, at least `minOut` | `test_guard_underDeliveryRefused`, `test_guard_outputSentElsewhereRefused`, `test_swapFloorEnforced` |
| nonReentrant; ETH arriving mid-swap is never a contribution | `test_guard_reentryRefused` (collectFees, claimFees, receiveContribution, a nested conversion), `test_guard_ethSentDuringASwapIsNotAContribution` |
| Nothing owed to others is usable: after the batch, every fee token covers fees + protocol cut + pending, and every open token covers its pending | `test_guard_cannotTouchOtherPendingTokens` (a target seizing another benefactor's pending token: `Insolvent`) |
| A target revert bubbles (no silent failure) | `test_guard_targetRevertBubbles` |

The invariant handler also sends misbehaving swaps (under-delivery, partial pull, output elsewhere, refunded input)
through an allowlisted target and fails the campaign unless each reverts on a guard.

- **AllowanceHolder's `operator` is keeper-chosen** (inside the `exec` calldata), as are its `token`, `amount` and
  `target`. That is bounded the same way: AllowanceHolder's ephemeral allowance is keyed by the caller (the vault) and
  only lets `operator` pull through AllowanceHolder, which then needs the vault's real ERC-20 approval, exactly the
  amount in and reset after the call. So any operator, honest Settler or the keeper's own contract, can move at most
  the amount in of the input token, and the vault reverts unless its output rises by `minOut`. An operator check would
  not add anything: 0x redeploys Settlers, and a dishonest keeper doesn't need a rogue operator to sell at its own
  floor (below). `exec` refuses ERC-20 targets itself (`ConfusedDeputy`), and nobody else can use the vault's
  allowance: the ephemeral allowance is set only by the vault's own `exec`, inside the vault's call.
- **zRouter's other entry points** (`multicall`, `deposit`, `sweep`, `snwap`, `execute` for trusted targets) run with
  the vault as `msg.sender` too. They can only use the vault's approval (the amount in) and its ETH value (the amount in
  for the leg); the balance checks then apply. The vault never approves Permit2, so `permit2TransferFrom` has nothing.
- **What a dishonest keeper can still do** is unchanged from M2: sell a batch at its own floors (a low `minOut` and a
  sandwich, or a route through its own contract), up to the batch being converted. It cannot touch fees, the position,
  other pending balances, or tokens not in the call. The floors are the only price protection; the keeper quotes,
  simulates and sends privately.
- **The ETH leg** is sent the batch's ETH as value (pending ETH net of the reward + every swap's measured ETH out); the
  keeper builds it to sell all of msg.value (zRouter `swapAmount` 0; a 0x quote for the expected amount). ETH it hands
  back (unspent input, or zRouter's whole stray balance) is ETH beyond what is owed and goes to the holders before the
  batch as dust, as before; it is never counted as leg input or as a token's output (`test_ethLeg_refundIsDustForHoldersNotLegInput`).
  A leg target that keeps unspent ETH loses it to the batch, bounded by the leg's `minOut`. A strict
  "spent exactly" check on ETH in would let 1 wei left in zRouter block conversions (the earlier High).
- **ETH-mode claims** keep `claimFees(ClaimMode, uint256 minEthOut)`: INFER -> IMD vault-side, then IMD -> ETH through
  the factory's fixed zRouter (`swapV4` on `ethPool`, Safe-settable, default 10000/200) under the same balance guards;
  `minEthOut` stays mandatory. This path doesn't need zRouter on the allowlist (`test_claimEth_worksWithoutZRouterAllowlisted`,
  `test_ethPool_usedByEthClaims`).
- **Order independence** holds as long as no two tokens' swaps in one batch share a pool; every token's ETH meets in
  the one leg. Tested over all 24 orders of a 4-token batch on two targets (`test_fairness_everyPermutationGivesTheSameValues`)
  and on the fork (`test_fork_mixedBatch_orderIndependent`). The keeper keeps the pools apart (0x routes are its
  choice).

**Other audit items closed with this change:**

- **Payment-token cap** (`MiyaRegistry.MAX_PAYMENT_TOKENS = 15`, `TooManyPaymentTokens`): a vault holds at most 16
  distinct tokens pending (in all and per benefactor), ETH included, so 15 ERC-20s + ETH always fit and the cap can't
  make a vault refuse an allowed token. Only a token dropped from the allowlist while still pending can push a vault
  past 16; the next new token's cut is then parked by the collection until the dropped one converts
  (`test_tooManyTokens`, `test_paymentToken_capOf15Erc20s`). (Asked for as "16"; 16 ERC-20s + ETH would be 17.)
- **Unowned rounding shares (accepted, no change).** A benefactor's lazily collected shares round down by up to its
  pending in raw units / p (<= ~1e-15 of them in the tests), so a few share units belong to nobody. Their fee share
  stays in the vault (claims never exceed what was distributed: `invariant_claimsWithinDistributed`), and the units
  stay in the position. Too small to matter, and exact accounting would cost a per-batch remainder ledger.
- **Deploy script**: the old `UniswapVaultPriceValidator` is no longer deployed (its checks and JSON output removed);
  the dead config keys `maxPriceDeviationBps`, `twapSeconds`, `minPoolEth`, `v2Factory`, `zRouterFee`,
  `zRouterTickSpacing` and `routes` are gone. Config gains `swapTargets` (AllowanceHolder, verified with `cast code` at
  block ~26,374,628, and zRouter) and `ethPool`; the script sets them before the handoff, and `_checkPayments` checks
  every target is allowed, the ETH pool, every minimum, and that both the INFER/IMD and the ETH/IMD pools are
  initialized with liquidity (StateLibrary over `extsload`), and warns loudly when `KEEPER` or `swapTargets` is unset.
  No early return skips a check. Offline test (no RPC, mocks at `script/config/31337.json`'s addresses):
  `test/deploy/DeployMiyamintsOffline.t.sol`.
- **Real-vault ERC-20 sales**: `test/integration/RealVaultErc20.t.sol` sells in USDC on a drop, a 1155 edition and an
  auction into a real (pool-simulated) vault on a real registry and factory: the cut arrives and converts; a refusal
  (token dropped from the allowlist; a cut under the factory minimum) parks it with no allowance left; a flush succeeds.

## Known risks (accepted for testnet; re-assess before any mainnet use)

- **Two-wallet self-hedge against the door caps.** The ExitDesk pays 1:1 only up to each wallet's own door
  deposits, so "buy imdUSD below the peg, bet both sides, cash out at $1" is capped per wallet. Two wallets that
  bet opposite sides through the door and pool their winnings can still cash out their combined deposits at $1
  after buying below the peg. That extracts roughly (depeg − rake) on the losing wallet's door credit. The bound is
  the wallets' total door deposits (`test_arbitrage_twoWalletSelfHedgeBoundedByTotalDeposits`), and the per-wallet
  and per-market caps keep it small. Operationally, the desk only opens below $0.995, and the desk and caps are
  sized together.
- **Oracle disagreement rate leads to the void path.** Paid swarm questions have historically failed or split often
  enough that VOID is a normal outcome, not an edge case. A market voids on a VOID code, no proposal within 7 days,
  nobody counted on the winner, or council silence, and all of these refund in full. Expect a meaningful void rate
  and budget its operational cost (oracle fees, creator expectations). A wrong primary answer that nobody disputes
  stands once the dispute window closes.
- **Sybil insiders.** The deny-list holds only the creator's registered wallet and declared crew. A creator or crew
  member staking through an undeclared wallet cannot be detected on chain. The mitigations are off chain (KYC on
  creators, linkage analysis, win-rate anomaly scoring), plus the council's power to slash the creator's escrowed fee
  share and bond before they vest. Caps bound what one wallet can take.
- **The source clock depends on a second attestation.** The oracle signs one answer per attestation, so the official
  start comes from a separate start-time question. If that answer is wrong, stakes fall on the wrong side of the
  cutoff. Disputes cover the outcome only; the dispute tier does not re-attest the start time.
- **The first valid answer proposes.** Anyone may submit any valid attestation for the market's question. If the
  oracle signs two different answers, the first to land proposes, and the dispute path is the remedy.
- **Identical questions share attestations.** Two markets with the same template and slots have the same
  `questionHash`. One attestation can resolve only one of them (request ids are single-use per resolver), so the
  second market needs its own request.
- **The global open-interest cap is checked at stake time.** ExitDesk cash-outs can bring the desk's USDC below open
  interest. New stakes are then refused, but existing positions are not re-covered automatically.
- **The eligibility gate is live.** Unlike every other dependency, the gate is not snapshotted per market, so a
  compromised signer can be rotated. It can only refuse new stakes.

## Final sweep (b7193ce), fixed without another external round

Job 6dfbf85f. No high findings. Four of the five seats could not run code in their sandbox, so most of this was found by
reading; only the economics seat ran tests. Not exercised by that round: extraction numbers against a real pool, worst-case
gas for the multi-pass loop, real zRouter on a fork, on-chain config addresses.

- **RANDOM on Robinhood Chain** (Medium): `MiyaPoolFactory` now refuses it on 4663.
- **A conversion's own swap fees** (Low): the vault books them after each swap, so they go to holders before the batch closes
  and the protocol gets its cut. On a first conversion there are no holders, so they stay in the batch.
- **Refusing treasury** (Low): all three sale types park the cut in `pendingProtocolCut`, pay it with the next cut, and
  anyone can call `flushPendingProtocolCut`. A sale no longer depends on the treasury.
- **Vault salts** (Low): `deployVault` and `computeVaultAddress` refuse a salt not bound to the factory.
- **Validator precision** (Low, reported but not reachable): the example needs a v2 reserve above uint112's limit. The cross-check needs 10
  WETH in the pair, so the price can't go below about 2e-15 ETH, where rounding is about 5 bps against a 500 bps limit. No
  change; tests pin that lowest price.
- **Stray ETH on ERC1155** (Low): `sweepUntrackedETH` counts it as proceeds, so `withdraw` splits it.
- **Vault implementation** (Info): the factory spends its initialization at construction.
- **Batch cost rounding** (Info): a small base price no longer rounds to free.
- **Fork test** (Info): `REQUIRE_FORK_TESTS=true` fails instead of skipping. CI and pre-deploy runs should set it. It still seeds
  its own 100 ETH pool until the real one exists.
