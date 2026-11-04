# Deploying miyamints

One script, `script/DeployMiyamints.s.sol`, deploys and wires everything the app needs on one chain, including the
music drops (ERC1155 editions). Markets (`src/markets`) are not part of this deployment.

## What it deploys, in order

| # | Contract | How | Owner after handoff |
|---|----------|-----|---------------------|
| 0 | `TestAlignmentToken` (Sepolia only, when no `ALIGNMENT_TOKEN`) | CREATE | none |
| 1 | `MiyaRegistry(owner=deployer, treasury, protocolFeeBps=100, minAlignmentBps=1000)` | CreateX CREATE3 | `OWNER` |
| 2 | `UniswapVaultPriceValidator(weth, v2Factory, v3Factory, poolManager, 500, 1800)` | CreateX CREATE3 | ownerless |
| 3 | `UniAlignmentVaultFactory(weth, poolManager, zRouter, fee, tickSpacing, validator, registry)` (+ its vault implementation) | CREATE | `OWNER` |
| 4 | `ERC721DropFactory(registry, weth)` (fixed-price drops) | CreateX CREATE3 | ownerless |
| 5 | `ERC721AuctionFactory(registry, weth)` | CREATE | `OWNER` |
| 6 | `ERC1155Factory(registry, weth)` (music drops: `createInstance` + `ERC1155Instance.addEdition`) | CREATE | `OWNER` |
| 7 | `DynamicPricingModule` (LIMITED_DYNAMIC editions) | CREATE | `OWNER` |
| 7b | `PasswordTierGatingModule` (only with `DEPLOY_GATING_MODULE=true`, see decisions) | CREATE | `OWNER` |
| 8 | `MiyaPoolFactory` | CreateX CREATE3 | ownerless |
| 9 | registry: `setVaultFactory`, `setFactory` x3, `setComponent(dynamicPricing)`; `ERC1155Factory.setDynamicPricingModule` | calls | |
| 10 | registry `addTarget(name, [alignmentToken])` → target 0; `vaultFactory.deployVault(...)` → **default vault** (CREATE3 via the factory) | calls | vault owned by the vault factory |
| 11 | `transferOwnership(OWNER)` on registry, vault factory, auction factory, 1155 factory, modules (skipped when `OWNER` is unset) | calls | |

Then it asserts the wiring (factories/vault factory/components registered, target active, vault registered,
owners, treasury, fee bps, validator and vault-factory parameters, the vault's pool key and treasury), prints the
addresses and the app env lines, and writes `deployments/<chainId>.json` (broadcast only; a dry run writes the
gitignored `deployments/<chainId>.dryrun.local.json`).

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
| zRouter | `0x0000…00e4` (fee 10000 / ts 200) | `0x0000…00e4`, chain build (3000 / 60) | `0x0000…00e4` (3000 / 60) |
| v3 factory | `0x1F98…F984` | `0x1f7d…2efa` | `0x0227…aC1c` |
| v2 factory (validator) | `0x5C69…aA6f` (pairs under 10 WETH ignored) | none on chain | `0xF62c…80E6` |
| CreateX / Permit2 | canonical, verified | canonical, verified | canonical, verified |
| treasury | imdUSD Treasury `0x6Ac8…7Bc` | **unset: `TREASURY` required** | deployer if unset |
| default alignment token | INFER `0x53d0…7921` (seed its pool first) | USDG `0x5fc5…1168` (placeholder) | test token |

## Env

| Var | Required | Meaning |
|---|---|---|
| `OWNER` | strongly recommended | Final owner (a Safe on that chain). Unset = the deployer keeps ownership and the script prints a loud warning. |
| `KEEPER` | strongly recommended | The only address that can run vault swaps (`MiyaRegistry.conversionKeeper`). Unset = conversions stay paused until the owner calls `setConversionKeeper`. |
| `TREASURY` | 4663: yes | Overrides config `treasury`. On 4663 the mainnet imdUSD Treasury address has no code. |
| `ALIGNMENT_TOKEN`, `ALIGNMENT_TARGET_NAME` | no | Override the default vault's token / target name. Needs a hookless native-ETH v4 pool at the config fee tier with liquidity, else the script stops (`ALLOW_MISSING_POOL=true` to bypass). |
| `PROTOCOL_FEE_BPS`, `MIN_ALIGNMENT_BPS` | no | Defaults 100 (1%, max 500) and 1000 (10%). |
| `SALT_NAMESPACE` | no | CREATE3 salt namespace, default `miyamints.v1`. |
| `DEPLOY_GATING_MODULE` | no | Default false. |
| `DEPLOYER_PRIVATE_KEY` | no | Only if you cannot use `--account`/`--ledger`. Read with `vm.envUint`, never printed. |
| `MAINNET_RPC_URL`, `FORK_BLOCK`, `SKIP_FORK_TESTS` | tests | Fork test RPC (default publicnode), optional pinned block, opt-out. |
| `ETHERSCAN_API_KEY` | verify | Etherscan v2 key (also covers Sepolia). |

## Runbook

**Robinhood Chain: don't offer RANDOM pools.** `blockhash` on Arbitrum-based chains is documented as insecure randomness
(AUDIT-NOTES.md). They need a different randomness source, or must stay off, before any launch there.

**Seed the alignment pool in one transaction, then check it.** `PoolManager.initialize` is open to anyone, so an unseeded
pool can be initialized first at any price. Initialize and add liquidity atomically (one call through a position manager
or your own contract), with a price limit. If someone got there first, trade the pool to the market price before adding
anything. Seed it deep against your conversion batches. The script stops below `minPoolEth` of depth and prints the
pool's depth and price: compare the price with the market before you broadcast, because no check here can know it.

1. **Prepare.** `git submodule update --init --recursive`; `forge test` (the fork test runs the script on a
   mainnet fork and smoke-tests every factory). Create a fresh deployer and import it into a keystore:
   `cast wallet import miyamints-deployer --interactive` (or use a Ledger). Fund it: about 31.4M gas in total (16
   transactions, the largest about 5.4M), so 0.03 ETH covers 1 gwei; at the 2026-11-01 base fee (~0.033 gwei) it
   is about 0.002 ETH. Same order on 4663 (L1 data fees extra).
2. **Create the Safe** that will own the system on each chain and note its address (`OWNER`). On 4663, also pick
   the `TREASURY`.
3. **Dry run** (no `--broadcast`):
   ```sh
   cd contracts
   FOUNDRY_PROFILE=deploy OWNER=0xSafe KEEPER=0xKeeper forge script script/DeployMiyamints.s.sol \
     --fork-url https://ethereum-rpc.publicnode.com --account miyamints-deployer --sender 0xDeployer
   ```
   Check the printed addresses, owner and treasury. Robinhood: add `TREASURY=0x...` and use
   `--fork-url https://rpc.mainnet.chain.robinhood.com`.
4. **Broadcast + verify, Ethereum:**
   ```sh
   FOUNDRY_PROFILE=deploy OWNER=0xSafe KEEPER=0xKeeper forge script script/DeployMiyamints.s.sol --rpc-url https://ethereum-rpc.publicnode.com \
     --account miyamints-deployer --sender 0xDeployer --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
   ```
   (`--ledger --sender 0x...` instead of `--account` for a hardware wallet.) Robinhood Chain (Blockscout):
   ```sh
   FOUNDRY_PROFILE=deploy OWNER=0xSafe KEEPER=0xKeeper TREASURY=0x... forge script script/DeployMiyamints.s.sol \
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
   factory, pool factory and price validator are ownerless; vaults are owned by the vault factory.
7. **Commit `deployments/<chainId>.json`.** The app bundles it (`app/src/constants/contracts.ts`), so music drops
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
- **Default alignment token (mainnet): INFER** (`0x53d0eA0A685220718Dc6a0a6e4617194C6F37921`). INFER trades through
  IMD and has no ETH pool, so **a hookless native-ETH v4 pool at 1% / tick spacing 200 must be seeded before deploying**;
  the script stops at its pool check otherwise. Pool depth limits what each conversion can swap without heavy slippage.
- **Keeper**: `KEEPER` runs `convertAndAddLiquidity` and `convertFeeTokens`, through a private mempool, with minimum
  outputs from a live quote. A new pool has no reference price, so nothing on chain can check those floors. If the
  keeper stops, vault ETH and fee tokens wait (nothing is lost) until the owner sets a new one.
- **Vault fee tier is factory-wide and immutable**: every vault from this factory swaps and LPs at 1%. A different tier
  means a second vault factory.
- **4663 default alignment token: USDG, a placeholder.** There is no INFER on 4663. Pick a real target before
  broadcasting there (it needs an ETH v4 pool at 0.3%, or change `zRouterFee` in `config/4663.json`).
- **Fees**: protocol 1% (`PROTOCOL_FEE_BPS`), minimum alignment 10% (`MIN_ALIGNMENT_BPS`), matching the plan.
- **Gating module is off by default.** `PasswordTierGatingModule.configureFor` only accepts a first configuration
  from a registered factory, and no factory calls it, so a collection that picks it could never be configured.
  The app passes no gating module. Enable it only after that path exists.

## Fixed: dust v2 pairs blocked vault conversion

`UniswapVaultPriceValidator.validatePrice` used to revert `PriceDeviationTooHigh` whenever a token had both a v2 pair
and a v3 pool whose prices disagreed. A token with a dust v2 pair hit this, and anyone can make
one for any token for almost nothing, so this was a cheap way to block every vault's conversions. Since 2026-11-02 a
v2 pair only counts as a price reference once it holds `MIN_V2_REFERENCE_WETH` (10 ETH, the same floor as the v2-only
route). The mainnet config uses the real v2 factory again. `validatePrice` is now a backstop only: see M2 in AUDIT-NOTES.md.
