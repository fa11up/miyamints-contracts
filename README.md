# miyamints contracts

Smart contracts for miyamints, an NFT launchpad built on [ms2fun-contracts](https://github.com/Zodomo/ms2fun-contracts).
This repository is a snapshot published for security review.

- `src/registry/MiyaRegistry.sol`: non-upgradeable registry of factories, collections and alignment vaults, and the
  fee terms each collection snapshots at launch (1% protocol fee, a collection-chosen alignment share of at least 10%,
  the rest to the artist).
- `src/factories/`: ERC721 fixed-price drops, ERC721 auctions, ERC1155 editions (optional dynamic pricing).
- `src/vaults/uni/` and `src/peripherals/`: Uniswap v4 alignment vaults and their price validator.
- `src/pools/`: MiyaPool, a zero-fee NFT pool (deposit an NFT for 1e18 pool tokens; redeem a chosen id or a random
  one by commit-reveal, fixed per pool at creation).
- `script/DeployMiyamints.s.sol`, `script/config/`, `DEPLOY.md`: the deployment and its runbook.
- `AUDIT-NOTES.md`: internal audit findings and their status.

## Build and test

```sh
git clone --recursive <this repo>
forge build
forge test
```

Foundry with solc 0.8.28 (one test compiles separately with 0.8.26; see `foundry.toml`).

## License

Derived from ms2fun-contracts and distributed under its license: see [LICENSE](LICENSE).
