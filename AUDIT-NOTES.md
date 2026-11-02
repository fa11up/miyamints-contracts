# Internal audit notes (for external review)

Status of the internal-audit findings as of branch `contracts/audit-fixes`. Line numbers refer to the
pre-fix tree (commit 88641a8). The regression tests below are ports of the internal PoC tests, which
demonstrated each fixed bug on 88641a8; here they assert the fixed behaviour.

| ID | Finding | Status |
|----|---------|--------|
| H1 | `UniAlignmentVault.claimFees` / `claimFeesAsDelegate` revert with `Reentrancy()` once the LP accrues native-ETH fees: `PoolManager.take(ETH)` and the zRouter token->ETH swap pay into `receive()`, which runs the `nonReentrant` contribution path. All LP yield unclaimable. | Fixed |
| H2 | Fee watermark model (`shareValueAtLastClaim`) dilutes unclaimed fees when new shares are minted (diluted part stranded forever) and resets a benefactor's watermark on re-contribution, erasing all their unclaimed fees. `ERC721DropInstance.withdraw()` is permissionless, so anyone could trigger the wipe. | Fixed |
| H3 | Conversion caller reward = `(100k + 15k*n) * tx.gasprice + 0.0012 ETH`, paid from the vault's general balance, i.e. from benefactors' fees. A builder/validator-set gas price drains the vault. | Fixed |
| M1 | `MiyaPool` RANDOM mode: once the outcome block hash is public, a depositor can steer which id a pending commit receives by depositing before reveal (contradicts MiyaPool.sol:41-42). | **Open** (needs design decision) |
| M2 | Vault swaps are sandwichable: `convertAndAddLiquidity(minOutTarget)` accepts any caller-chosen floor (e.g. 1), and the fee token->ETH swap has `minEthOut = 0` when the validator has no TWAP data. | **Open** (needs design decision: TWAP floor / keeper restriction) |
| M3 | `protocolTreasury` was never settable in production (factory owns the vault, no passthrough), locking the 1% LP-yield cut. | Fixed |
| M4 | Factory owner could repoint any vault's V4 pool key at any time; hooks were not checked. | Fixed |
| M5 | Not part of this change's brief; status not re-verified here. | Unverified |
| M6 | `ERC721AuctionInstance.settleAuction` used `_safeMint`; a contract winner whose `onERC721Received` reverts froze settlement (artist proceeds, vault cut, the line's queue). | Fixed |
| M7 | `ERC1155Instance` lacked `supportsInterface` / `uri` / `balanceOfBatch`, so `MiyaPoolFactory._detectKind` reverted for miyamaker 1155 collections. | Fixed |
| L1 | `renounceOwnership` on instances makes `owner() == address(0)`; artist share then goes to `address(0)` (Drop `withdraw()` is permissionless). | Fixed (renounce disabled) |
| L2 | `ERC721DropInstance.mintedInPhase` survived `setPhases`, applying old counts to unrelated new phases. | Fixed |
| L3 | `ERC1155Instance.claimFreeMint` ignored the edition `openTime`. | Fixed |

## What changed

**H1** — `receive()` returns early while a transient flag (`_COLLECTING_SLOT`, TSTORE/TLOAD) is set; the flag
wraps only the internal collection (`_claimVaultFees` + `_convertVaultFeesToEth`). One TLOAD keeps 2300-gas
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

## Notes for the reviewer

- Fee collection is still gated by `vaultFeeCollectionInterval` (1 day) for claims, but forced on every
  conversion. Uncollected LP yield is not reflected in `getUnclaimedFees` until collected.
- Shares per ETH now differ slightly between batches (each batch pays its own ≤1% reward); the share-ordering
  invariant tolerance accounts for this.
- ETH sent to the vault by anyone other than via contributions/collection (e.g. `selfdestruct`) is unaccounted
  surplus; it is never paid out as fees.

---

