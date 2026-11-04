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
`transfer` senders working. Test: `test/vaults/UniAlignmentVaultRealV4.t.sol` (real v4 `PoolManager`; this file
compiles as a separate solc 0.8.26 unit, see `foundry.toml`).

**H2** — MasterChef-style accounting: `accFeePerShare` (1e36 scale) + per-benefactor `feeCheckpoint` and
`settledFees`. Pending fees are settled before every share change (`_distributeSharesAndCleanup`).
`convertAndAddLiquidity` force-collects LP yield before minting new shares, so fees accrued before a join stay
with existing holders. A per-share-index checkpoint (rather than a rounded reward debt) means each payout rounds
down once, so `sum(claims) <= fees distributed` exactly. Tests: `UniAlignmentVaultFeeAccounting.t.sol` (PoC ports +
fuzz), `invariant_feesConserved` in `UniVaultInvariant.t.sol`, and the real-v4 non-dilution test.

**H3** — Reward = `min(CONVERSION_REWARD = 0.0012 ETH, 1% of the pending batch)`, carved out of the batch before
the swap/LP (no `tx.gasprice` term, never from general balance). A rejected reward is distributed to
shareholders as fees. Tests: `M04_GriefingAttackTests.t.sol`, `testFuzz_callerRewardKeepsVaultSolvent`.

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
`pendingFeeTokens`. They convert before any share mint, which keeps H2's guarantee. Tests:
`UniAlignmentVaultRealV4.t.sol`.

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
- **Metadata events**: `setMetadata` emits EIP-4906 `BatchMetadataUpdate(1, maxSupply)` and `supportsInterface` reports
  `0x49064906`. `ERC1155Instance.updateEditionMetadata` emits the standard `URI` event.

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
