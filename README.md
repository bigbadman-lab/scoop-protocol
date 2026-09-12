# SCOOP Protocol

Permissionless market infrastructure built on Uniswap v4 for Robinhood Chain.

Launch fixed-supply tokens against ETH, ecosystem assets or supported stock tokens, with configurable fee economics, creator attribution, holder rewards and permanently locked initial liquidity.

- Product: https://scoop.fun
- Documentation: https://scoop.fun/docs
- App repository: https://github.com/bigbadman-lab/scoop-app

## What it does

SCOOP launches a fixed-supply ERC-20, creates a Uniswap v4 pool, seeds permanently locked initial liquidity, and wires immutable fee destinations for creator attribution, deployer share, Protocol Vault, operations and optional Holder Rewards. Supported quote assets include native ETH, ecosystem assets and registered stock tokens.

Pairing against a stock token does **not** mean a SCOOP-launched token represents, owns or tracks shares in the underlying company.

## Architecture

Major contracts in `src/`:

| Component | Contract | Role |
| --- | --- | --- |
| Factory | `ScoopFactory` | Permissionless atomic launch orchestrator |
| Token deployer | `ScoopTokenDeployer` | CREATE2 deployment of `ScoopToken` |
| Launch deployer | `ScoopLaunchDeployer` | CREATE2 deployment of per-launch modules |
| Quote registry | `ScoopQuoteRegistry` | Quote asset registration and enable policy |
| Price oracle | `ScoopPriceOracle` | Quote → USD price reads |
| Creator registry | `ScoopCreatorRegistry` | Creator identity → payout wallet resolution |
| Creator rewards | `ScoopCreatorRewards` | Escrow and claim for creator fee allocation |
| Fee distributor | `ScoopFeeDistributor` | Splits harvested trading fees |
| Holder rewards | `ScoopHolderRewards` | Per-launch holder fee vault (Merkle claims) |
| Liquidity locker | `ScoopLiquidityLocker` | Permanently holds the initial LP NFT |

`ScoopFactoryDeployer` deploys `ScoopCreatorRewards` and `ScoopFactory` together. Each launch also deploys a `ScoopToken` plus per-launch `ScoopHolderRewards`, `ScoopFeeDistributor` and `ScoopLiquidityLocker`.

```text
Factory.launch / launchAndBuy
  → TokenDeployer (ScoopToken)
  → LaunchDeployer (HolderRewards + FeeDistributor + LiquidityLocker)
  → Uniswap v4 pool + locked LP
Trading fees → LiquidityLocker.collectFees → FeeDistributor → recipients
```

## Economics

- Base trading fee: **1%**
- Base fee allocation:
  - 70% creator allocation (routable at launch to Creator or Holders)
  - 4% deployer
  - 20% Protocol Vault
  - 6% operations
- Optional additional fee: **0%–2%** in **0.1%** increments, allocated entirely to Creator, Deployer or Holders
- Launch fee: **0.0005 ETH**

## Canonical deployment

Robinhood Chain Mainnet (chain ID `4663`).

| | |
| --- | --- |
| SCOOP Factory | `0x4B227d5E6199f42ceA4e638875fF8C740757DD3C` |
| Canonical deployment block | `60525572` |

Full canonical address tables, quote catalogue and event/indexer notes: https://scoop.fun/docs

## Development

Requires [Foundry](https://book.getfoundry.sh/). Solidity `0.8.26`, Cancun, via-IR (see `foundry.toml`). Clone with submodules:

```shell
git submodule update --init --recursive
forge build
forge test
forge fmt
```

Fork/mainnet tests may require RPC configuration (see `.env.example`). Deployment and configuration scripts live under `script/`.

## Repository structure

```text
src/       Protocol contracts and libraries
script/    Foundry deployment and configuration scripts
test/      Unit, fork, security and invariant tests
audit/     Canonical production freeze and catalogue artifacts
docs/      Internal milestone / runbook notes
lib/       Foundry / Uniswap / OpenZeppelin dependencies
broadcast/ Foundry deployment and configuration broadcast records
```

## Documentation

Detailed public reference lives at https://scoop.fun/docs, including launch lifecycle, economics, creator identity, Holder Rewards, quote assets, oracle, architecture, canonical deployment, events and API/indexer integration.

## Security / status

Production SCOOP contracts in `src/` are intended to be **non-upgradeable**: dependencies and fee recipients are constructor immutables, with no proxy/UUPS ownership path on the Factory or per-launch stack.

This repository does not claim a formal third-party audit, explorer verification status or operational guarantees for offchain app/indexer infrastructure.
