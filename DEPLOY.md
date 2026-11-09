# Deploying miyamints

One script, `script/DeployMiyamints.s.sol`, deploys and wires everything the app needs on one chain, including the
music drops (ERC1155 editions). Markets (`src/markets`) are not part of this deployment.

## Vault v2 (INFER/IMD) status

The vault and its factory are v2 (`docs/IMD-INFER-VAULT.md`): the factory takes `(registry, poolManager, zRouter,
INFER, IMD, alignmentPoolKey)`; `deployVault(salt, targetId)`. Conversions run keeper-built aggregator calldata (0x
AllowanceHolder, zRouter as the fallback) against the factory's swap-target allowlist; there is no route table. From
`config/<chainId>.json` the script sets, before the ownership handoff: the registry's payment tokens (`paymentTokens`,
at most 15 ERC-20s), the vault factory's swap targets (`swapTargets`: 0x AllowanceHolder
`0x0000000000001fF3684f28c67538d4D072C22734` and zRouter on mainnet), the IMD/ETH pool ETH-mode claims sell into
(`ethPool`, 10000 / 200) and the per-token minimums (`minContributions`). It checks that the INFER/IMD alignment pool
(`alignmentPool`: fee 12500, spacing 60, hook `0x784F…6000`) and the ETH/IMD pool are initialized with liquidity in
range. Other chains have no INFER/IMD config (mainnet only).

## Release rules

- **Deploy from `main` only**, through `script/deploy.sh` (or from a release tag with `DEPLOY_TAG=<tag>`). It refuses a
  dirty tree, untracked files, submodules off their recorded commits, any branch but `main`, and a `main` that isn't
  `origin/main`. The Solidity script refuses `--broadcast` unless `deploy.sh` set `DEPLOY_GIT_COMMIT`, and writes that
  commit (`gitCommit`, `gitRef`) and the `chainId` into `deployments/<chainId>.json`. That file is the record of which
  source is on chain: verify against that commit.
- **Ship the app that matches these ABIs in the same release.** `deploy/live` still carries an older app whose
  hand-written ABIs don't match these contracts: `createDrop` with 9 params (no `ownerReserve`), `Phase` without
  `supplyCap` (`setPhases`, `phases()`), and `MiyaPool.commits` read as `snapshot` where the contract returns `queueEnd`
  (and no escrow / `nextRevealId`). Calls from that app would revert or misread. Merge the app from `main` to
  `deploy/live` together with the deployment.
- **Don't set `VITE_*` addresses on `deploy/live`** (and don't commit `deployments/<chainId>.json` to it) before its
  app matches. `app/tests/abi-drift.test.mts` (`yarn test`) must pass on the branch being released.
- **The compiler is pinned to solc 0.8.28** (`foundry.toml`, default and deploy profiles). The real `PoolManager` is
  exercised on a mainnet fork (`test/fork/`, `test/deploy/`), not against a locally compiled v4-core.

## ABI snapshots (`contracts/abi/`)

`contracts/abi/*.json` are the ABIs of the contracts the app calls, generated from the 0.8.28 build, so the app's
drift test runs in CI without forge. After any change to a contract's external interface:

```sh
cd contracts && script/export-abis.sh        # forge build + rewrite abi/*.json; commit the result
cd ../app && yarn test                       # abi-drift.test.mts: the app's ABIs against the snapshots
```

`script/export-abis.sh --check` fails when the snapshots are older than the source (for CI that has forge). To add a
contract, add it to the list in `export-abis.sh` and to `MAP` in `app/tests/abi-drift.test.mts`.

## What it deploys, in order

| # | Contract | How | Owner after handoff |
|---|----------|-----|---------------------|
| 0 | `TestAlignmentToken` (Sepolia only, when no `ALIGNMENT_TOKEN`) | CREATE | none |
| 1 | `MiyaRegistry(owner=deployer, treasury, protocolFeeBps=100, minAlignmentBps=1000)` | CreateX CREATE3 | `OWNER` |
| 2-3 | `UniAlignmentVaultFactory(registry, poolManager, zRouter, INFER, IMD, alignmentPoolKey)` (+ its vault implementation, linked to the `PendingLedger` and `VaultSwaps` libraries) | CREATE | `OWNER` |
| 4 | `ERC721DropFactory(registry, weth)` (fixed-price drops) | CreateX CREATE3 | ownerless |
| 5 | `ERC721AuctionFactory(registry, weth)` | CREATE | `OWNER` |
| 6 | `ERC1155Factory(registry, weth)` (music drops: `createInstance` + `ERC1155Instance.addEdition`) | CREATE | `OWNER` |
| 7 | `DynamicPricingModule` (LIMITED_DYNAMIC editions) | CREATE | `OWNER` |
| 7b | `PasswordTierGatingModule` (only with `DEPLOY_GATING_MODULE=true`, see decisions) | CREATE | `OWNER` |
| 8 | `MiyaPoolFactory` | CreateX CREATE3 | ownerless |
| 9 | registry: `setConversionKeeper(KEEPER)`, `setVaultFactory`, `setFactory` x3, `setComponent(dynamicPricing)`; `ERC1155Factory.setDynamicPricingModule` | calls | |
| 9b | registry `setPaymentToken` per `paymentTokens`; vault factory `setSwapTarget` per `swapTargets`, `setEthPool(ethPool)`, `setMinContribution` per `minContributions` | calls | |
| 10 | registry `addTarget(name, [INFER, IMD])` → target 0; `vaultFactory.deployVault(...)` → **default vault** (CREATE3 via the factory) | calls | vault owned by the vault factory |
| 11 | `transferOwnership(OWNER)` on registry, vault factory, auction factory, 1155 factory, modules (skipped when `OWNER` is unset) | calls | |

Then it asserts the wiring (factories/vault factory/components registered, target active, vault registered,
owners, treasury, fee bps, vault-factory parameters, the vault's pool key, config and treasury, every payment token
allowed, every swap target allowed, the ETH-claim pool, every minimum, both pools live; it warns loudly when `KEEPER` is
unset or `swapTargets` is empty), prints the
addresses and the app env lines, and writes `deployments/<chainId>.json` with `chainId`, `gitCommit` and `gitRef`
(broadcast only; a dry run writes the gitignored `deployments/<chainId>.dryrun.local.json`). Dry-run files are local
scratch and go stale: one from before 2026-11-04 still names CULT as the alignment token where the config now says
INFER. Delete it, or re-run the dry run, rather than reading addresses from it.

**Addressing.** The factories already deploy collections and vaults with CreateX CREATE3, and `MiyaPoolFactory`
assumes the same address on every chain, so contracts that take their owner as an argument or have none use CreateX
CREATE3 with a deployer-permissioned salt (`deployer ‖ 0x00 ‖ keccak(SALT_NAMESPACE.label)`): same deployer +
namespace = same address on every chain, and nobody else can claim it. Contracts whose constructor does
`owner = msg.sender` use plain CREATE (under CREATE3 the owner would be CreateX's throwaway proxy). With a **fresh
deployer EOA (nonce 0) on every chain**, the CREATE addresses match across chains too (the dry runs on 1 and 4663
produced identical addresses). Re-running with the same deployer and namespace reverts with
`already deployed at this salt: change SALT_NAMESPACE`.

## Per-chain config

`script/config/<chainId>.json` (every external address checked with `cast code` on 2026-11-01; notes in `_verified`):

| | Ethereum (1) | Robinhood Chain (4663) | Sepolia (11155111) |
|---|---|---|---|
| WETH | `0xC02a…6Cc2` | `0x0Bd7…AD73` | `0xfFf9…6B14` |
| Uniswap v4 PoolManager | `0x0000…8A90` | `0x8366…0951` | `0xE03A…3543` |
| zRouter | `0x0000…00e4` | `0x0000…00e4`, chain build | `0x0000…00e4` |
| swap targets | 0x AllowanceHolder `0x0000…2734`, zRouter | none set | none set |
| ETH-claim pool (`ethPool`) | ETH/IMD 10000 / 200 | default | default |
| v3 factory | `0x1F98…F984` | `0x1f7d…2efa` | `0x0227…aC1c` |
| CreateX / Permit2 | canonical, verified | canonical, verified | canonical, verified |
| treasury | imdUSD Treasury `0x6Ac8…7Bc` | **unset: `TREASURY` required** | deployer if unset |
| default alignment token | INFER `0x53d0…7921` (INFER/IMD pool live) | USDG `0x5fc5…1168` (placeholder; no IMD config, so the script refuses) | test token |

## Env

| Var | Required | Meaning |
|---|---|---|
| `OWNER` | strongly recommended | Final owner (a Safe on that chain). Unset = the deployer keeps ownership and the script prints a loud warning. |
| `KEEPER` | strongly recommended | The only address that can run vault conversions (`MiyaRegistry.conversionKeeper`). Unset = conversions stay paused until the owner calls `setConversionKeeper`; the script prints a loud warning. |
| `TREASURY` | 4663: yes | Overrides config `treasury`. On 4663 the mainnet imdUSD Treasury address has no code. |
| `ALIGNMENT_TOKEN`, `ALIGNMENT_TARGET_NAME` | no | Override the default vault's token / target name. The INFER/IMD-shaped alignment pool (`alignmentPool`) must be initialized with liquidity, else the script stops and names the pool, fee and tick spacing. |
| `ALLOW_MISSING_POOL` | no | `true` skips the pool checks (default on Sepolia's test token only). On 1 / 4663 it prints a loud warning: without the INFER/IMD pool the default vault can't convert, and without the ETH/IMD pool claims taken as ETH revert. |
| `PROTOCOL_FEE_BPS`, `MIN_ALIGNMENT_BPS` | no | Defaults 100 (1%, max 500) and 1000 (10%). |
| `SALT_NAMESPACE` | no | CREATE3 salt namespace, default `miyamints.v1`. |
| `DEPLOY_GATING_MODULE` | no | Default false. |
| `DEPLOYER_PRIVATE_KEY` | no | Only if you cannot use `--account`/`--ledger`. Read with `vm.envUint`, never printed. |
| `MAINNET_RPC_URL`, `FORK_BLOCK`, `SKIP_FORK_TESTS`, `REQUIRE_FORK_TESTS` | tests | Fork test RPC (default publicnode), optional pinned block, opt-out, and fail-instead-of-skip. |
| `DEPLOY_GIT_COMMIT`, `DEPLOY_GIT_REF`, `DEPLOY_TAG` | deploy | Set by `script/deploy.sh` (don't set the first two by hand). `DEPLOY_TAG` deploys a release tag instead of `main`. |
| `ETHERSCAN_API_KEY` | verify | Etherscan v2 key (also covers Sepolia). |

## Runbook

**Robinhood Chain: no RANDOM pools.** `blockhash` on Arbitrum-based chains is documented as insecure randomness
(AUDIT-NOTES.md), so `MiyaPoolFactory` refuses them on 4663. Keep the app from offering them there.

**Run the fork tests for real.** Set `REQUIRE_FORK_TESTS=true` before deploying, or a machine without an RPC skips them and
reports green. Pin `FORK_BLOCK` to a recent block so the run is repeatable.

**Precondition: both pools the vault uses are live.** The INFER/IMD alignment pool (fee 12500, spacing 60, hook
`0x784F…6000`) and the hookless ETH/IMD pool (10000 / 200) were initialized with liquidity on 2026-11-08 (7.62e23 and
9.73e21 in range). The script checks both and prints their liquidity and price: compare the price with the market
before you broadcast, because no check here can know it.

1. **Prepare.** `git checkout main && git pull`; `git submodule update --init --recursive`;
   `REQUIRE_FORK_TESTS=true FORK_BLOCK=<a recent block> forge test` (the fork tests run the script on a mainnet fork,
   smoke-test every factory and convert real batches through zRouter and AllowanceHolder; `test/deploy/` also runs the
   script offline against mocks), `script/export-abis.sh --check`, and `cd ../app && yarn test`. Create a fresh deployer and import it into a keystore:
   `cast wallet import miyamints-deployer --interactive` (or use a Ledger). Fund it: about 31.4M gas in total (16
   transactions, the largest about 5.4M), so 0.03 ETH covers 1 gwei; at the 2026-11-01 base fee (~0.033 gwei) it
   is about 0.002 ETH. Same order on 4663 (L1 data fees extra).
2. **Create the Safe** that will own the system on each chain and note its address (`OWNER`). On 4663, also pick
   the `TREASURY`.
3. **Dry run** (no `--broadcast`), from the same clean `main`:
   ```sh
   cd contracts
   OWNER=0xSafe KEEPER=0xKeeper script/deploy.sh \
     --fork-url https://ethereum-rpc.publicnode.com --account miyamints-deployer --sender 0xDeployer
   ```
   Check the printed addresses, owner and treasury. Robinhood: add `TREASURY=0x...` and use
   `--fork-url https://rpc.mainnet.chain.robinhood.com`.
4. **Broadcast + verify, Ethereum:**
   ```sh
   OWNER=0xSafe KEEPER=0xKeeper script/deploy.sh --rpc-url https://ethereum-rpc.publicnode.com \
     --account miyamints-deployer --sender 0xDeployer --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
   ```
   (`--ledger --sender 0x...` instead of `--account` for a hardware wallet.) Robinhood Chain (Blockscout):
   ```sh
   OWNER=0xSafe KEEPER=0xKeeper TREASURY=0x... script/deploy.sh \
     --rpc-url https://rpc.mainnet.chain.robinhood.com --account miyamints-deployer --sender 0xDeployer --broadcast \
     --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
   ```
5. **Verify anything `--verify` missed** (CREATE3 deployments, the vault implementation, the default vault
   clone): `forge verify-contract <addr> src/registry/MiyaRegistry.sol:MiyaRegistry --chain 1 --constructor-args
   $(cast abi-encode "c(address,address,uint16,uint16)" <deployer> <treasury> 100 1000)`; same pattern for the
   others (constructor args are in the script and in `broadcast/DeployMiyamints.s.sol/<chainId>/run-latest.json`).
   Artist collections deployed later by the factories are verified the same way.
6. **Ownership.** With `OWNER` set, the script already transferred ownership (solady one-step `transferOwnership`,
   no acceptance needed) and asserted it. Confirm: `cast call <registry> "owner()(address)"` etc. for the vault
   factory, auction factory, 1155 factory and dynamic pricing module. If you deployed without `OWNER`, do it now
   from the deployer: `cast send <each> "transferOwnership(address)" 0xSafe --account miyamints-deployer`. Drop
   factory and pool factory are ownerless; vaults are owned by the vault factory.
7. **Commit `deployments/<chainId>.json`** (to `main`, then release it with the matching app; see Release rules). The app bundles it (`app/src/constants/contracts.ts`), so music drops
   and the other miyamints addresses work without env. Or set the printed env lines (Vercel / `app/.env.local`):
   `VITE_MUSIC_FACTORY_<id>`, `VITE_MUSIC_VAULT_<id>` (read by the app today), plus `VITE_MIYA_REGISTRY_<id>`,
   `VITE_ERC721_DROP_FACTORY_<id>`, `VITE_ERC721_AUCTION_FACTORY_<id>`, `VITE_MIYA_POOL_FACTORY_<id>`,
   `VITE_VAULT_FACTORY_<id>` (exposed through `miyamintsAddresses()`; no screen uses them yet). Env overrides the
   JSON. The legacy constants (`MIYAMINI_CONTRACT`, `FACTORY_CONTRACT` 0x37d2…, `AUCTION_CONTRACT`, ...) are
   unchanged.
8. **Smoke on the live chain**: launch a test track from Drop Music, mint it, and confirm it appears in Mint → Music.

## Decisions and keys you must supply

- **Deployer key**: a fresh keystore account or Ledger (`--account` / `--ledger`). Nothing is hardcoded.
- **`OWNER` Safe per chain** (1 and 4663). The mainnet governance Safe has no code on 4663.
- **`TREASURY` on 4663.** Mainnet uses the imdUSD Treasury `0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc`.
- **Default alignment token (mainnet): INFER** (`0x53d0eA0A685220718Dc6a0a6e4617194C6F37921`), paired with IMD in the
  INFER/IMD pool (`alignmentPool`). Pool depth limits what each conversion can swap without heavy slippage.
- **Keeper**: `KEEPER` runs `convertAndAddLiquidity` with aggregator calldata it builds (0x quotes with the vault as
  taker, zRouter as the fallback), through a private mempool, with minimum outputs from a live quote. Nothing on chain
  can check those floors (AUDIT-NOTES.md, vault v2). If the keeper stops, pending contributions wait (nothing is lost)
  until the owner sets a new one. The keeper can't add swap targets: only the vault factory's owner can.
- **The alignment pool is fixed per vault factory** (and per vault). The ETH-claim pool and the swap targets are not:
  the owner changes them for every vault at once (`setEthPool`, `setSwapTarget`).
- **4663 default alignment token: USDG, a placeholder.** There is no INFER or IMD on 4663, and the script refuses a
  chain without `imd`. Pick a real target and pools before broadcasting there.
- **Fees**: protocol 1% (`PROTOCOL_FEE_BPS`), minimum alignment 10% (`MIN_ALIGNMENT_BPS`), matching the plan.
- **Gating module is off by default.** `PasswordTierGatingModule.configureFor` only accepts a first configuration
  from a registered factory, and no factory calls it, so a collection that picks it could never be configured.
  The app passes no gating module. Enable it only after that path exists.

## Price validator: no longer deployed

`UniswapVaultPriceValidator` (v1 vaults) is not deployed by this script any more: vault v2 has no on-chain price
reference (none exists for its pools) and relies on the keeper's floors (AUDIT-NOTES.md, M2 and vault v2). The source
stays in `src/peripherals/` with its tests; the config keys only it used (`v2Factory`, `maxPriceDeviationBps`,
`twapSeconds`, `minPoolEth`, and the old `zRouterFee` / `zRouterTickSpacing`) are gone.
