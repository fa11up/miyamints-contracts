# miyamints contracts

Smart contracts for miyamints, an NFT launchpad built on [ms2fun-contracts](https://github.com/Zodomo/ms2fun-contracts).
This repository is a snapshot published for security review. Ethereum mainnet only for now.

- `src/registry/MiyaRegistry.sol`: non-upgradeable registry of factories, collections and alignment vaults, the
  payment-token allowlist (ETH, IMD, INFER, USDC, imdUSD, cbBTC, WBTC; at most 15 ERC-20s), and the fee terms each
  collection snapshots at launch (1% protocol fee, a collection-chosen alignment share of at least 10%, the rest to the
  artist).
- `src/factories/` and `src/libraries/PaymentLib.sol`: ERC721 fixed-price drops, ERC721 auctions (one currency per
  auction house) and ERC1155 editions (optional dynamic pricing). Each sale is priced per accepted token; the artist
  collects every token exactly as paid; protocol and vault cuts are taken in the token paid.
- `src/vaults/uni/`: the alignment vault (`UniAlignmentVault`, libraries `PendingLedger` and `VaultSwaps`) and its
  factory, which also holds the swap-target allowlist (0x AllowanceHolder, zRouter), the ETH pool for ETH-mode claims
  and per-token minimum contributions. A keeper converts pending tokens with aggregator calldata it supplies; the vault
  checks every swap and adds INFER/IMD liquidity to the hooked Uniswap v4 pool, permanently.
- `src/pools/`: MiyaPool, a zero-fee NFT pool (deposit an NFT for 1e18 pool tokens; redeem a chosen id or a random
  one by commit-reveal, fixed per pool at creation).
- `script/DeployMiyamints.s.sol`, `script/config/`, `DEPLOY.md`: the deployment and its runbook.
- `docs/IMD-INFER-VAULT.md`: the design of multi-token sales and the vault. `AUDIT-NOTES.md`: internal audit findings
  and their status. `abi/`: the ABIs the app reads.

## Build and test

```sh
git clone --recursive <this repo>
forge build
SKIP_FORK_TESTS=true forge test --offline
REQUIRE_FORK_TESTS=true FORK_BLOCK=26374628 forge test --match-path "test/{fork,deploy}/*"   # mainnet RPC
```

Foundry with solc 0.8.28 and `via_ir` (a full build takes about 10 minutes and several GB of memory). `src` alone builds
much faster: `forge build --skip test --skip script`.

## License

Derived from ms2fun-contracts and distributed under its license: see [LICENSE](LICENSE).
