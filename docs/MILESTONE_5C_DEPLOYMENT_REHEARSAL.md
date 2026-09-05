# Milestone 5C — Mainnet Deployment Fork Rehearsal

**Date:** 2026-09-05  
**Git commit rehearsed:** `384e838fa393efd54752a8f3a915ccb1ff254f0d` (branch `main`, dirty working tree — uncommitted 5B/5C artifacts)  
**Chain ID:** `4663` (Robinhood Chain)  
**Fork block (representative):** `25913457`  
**Broadcast:** **NONE** (simulation / fork only)

---

## Verdict

```text
DEPLOYMENT CONFIGURATION DECISIONS REQUIRED
```

Core deployment mechanics, HELLO canary, CREATE2 grief recovery, ETH receivability, and oracle freshness were rehearsed successfully on a live Robinhood fork. Production role keys, recipient wallets, and equity `maxAge` policy remain **PENDING** before 5D.

---

## Files Created / Modified

### Created
- `script/ScoopProtocolDeploy.sol` — shared deploy + configure library
- `script/DeployScoop.s.sol` — forge script (no `--broadcast` in 5C)
- `test/deployment/ScoopMainnetDeploymentFork.t.sol`
- `test/deployment/ScoopHelloCanaryFork.t.sol`
- `docs/MILESTONE_5C_DEPLOYMENT_REHEARSAL.md` (this file)
- `docs/MAINNET_DEPLOYMENT_CHECKLIST.md`
- `docs/MAINNET_DEPLOYMENT_RUNBOOK.md`

### Modified
- `.env.example` — deployment/oracle rehearsal env vars

### Frozen protocol Solidity (`src/`)
**NONE**

---

## Canonical External Dependencies (FINAL PRODUCTION VALUE)

| Contract | Address | Fork bytecode |
|----------|---------|---------------|
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | PRESENT |
| PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` | PRESENT |
| UniversalRouter | `0x8876789976dEcBfCbBbe364623C63652db8C0904` | PRESENT |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | PRESENT |
| ETH/USD feed | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | PRESENT |

---

## Role / Recipient Classification

| Role | Rehearsal value | Production status |
|------|-----------------|-------------------|
| Deployer wallet | Foundry default / script sender | **PENDING DEPLOYMENT DECISION** |
| `verificationAuthority` | TEST/FORK ONLY EOA | **PENDING** — prefer multisig/HSM (5B F-02) |
| `registryAuthority` | TEST/FORK ONLY EOA (combined with oracle in rehearsal) | **PENDING** |
| `oracleAuthority` | Same as registry in rehearsal | **PENDING** — may equal registry or separate |
| `launchFeeRecipient` | TEST/FORK ONLY payable EOA | **PENDING** — must pass ETH receive test |
| `buybackVault` | TEST/FORK ONLY payable EOA | **PENDING** — must pass ETH receive test |
| `operations` | TEST/FORK ONLY payable EOA | **PENDING** — must pass ETH receive test |

**verificationAuthority production choice (explicit):** not finalized. Options: EOA / hardware-wallet EOA / multisig / HSM-backed signer. Silent weak EOA is **not** acceptable for mainnet.

---

## Deployment Order (rehearsed)

1. `ScoopCreatorRegistry(verificationAuthority)`
2. `ScoopTokenDeployer()`
3. `ScoopLaunchDeployer(positionManager)`
4. `ScoopQuoteRegistry(registryAuthority)`
5. `ScoopPriceOracle(oracleAuthority)`
6. Configure ETH quote + feed (`maxAge` explicit)
7. Optional AAPL rehearsal quote + feed (**not** production policy)
8. `ScoopFactoryDeployer(...)` → CREATE nonce1 `CreatorRewards`, nonce2 `Factory`
9. Assert `predictedFactory == factory` and `creatorRewards.sourceRegistrar() == factory`

### CREATE nonce prediction
Factory address = `keccak256(rlp([factoryDeployer, nonce=2]))` for `1 <= nonce <= 0x7f`. Constructor args do not change the predicted address.

---

## Quote / Oracle Policy

| Asset | Rehearsal | Production initial list |
|-------|-----------|-------------------------|
| Native ETH (`address(0)`) | Registered + enabled + feed | **Required** |
| AAPL | Included in deployment fork tests only | **PENDING / NOT ENABLED** for production by 5C |

**ETH maxAge (rehearsal):** `1 days` (86400s) in HELLO canary; deployment suite may use the same or script env `SCOOP_ETH_MAX_AGE`.  
**Equity maxAge / off-hours:** **NOT FINALIZED** — weekend/stale equity feeds can block new launches; existing pools continue trading after disable/staleness (proven in 5B).

---

## ETH Receivability

| Recipient | Result |
|-----------|--------|
| `launchFeeRecipient` (EOA) | PASS — balance increases |
| `buybackVault` (EOA) | PASS |
| `operations` (EOA) | PASS |
| `RejectETHRecipient` | PASS — call fails (documents F-03/F-04 operational risk) |

Checklist gate for 5D: **ETH RECEIVABILITY VERIFIED** for all three immutables with **final** production addresses.

---

## Gas (fork rehearsal)

From `test_gasReport_logged` at fork block `25913457`:

| Metric | Value |
|--------|-------|
| Total deployment gas | **10,189,960** |
| Total config gas | **351,343** |
| Largest tx gas (FactoryDeployer stack) | **4,629,260** |
| Block gas limit | Readable / ample on Robinhood |
| Deployer ETH estimate | **PENDING LIVE GAS PRICE** at 5D |

**Funding safety margin:** fund deployer for ≥ 2× (deployment + config + HELLO launchAndBuy + buffer), re-estimate at broadcast time.

---

## HELLO Canary (fork)

| Field | Value |
|-------|--------|
| Name | Hello World |
| Ticker | HELLO |
| Creator | Wallet creator (separate from authorities) |
| Quote | Native ETH |
| Launch fee | 0.0005 ETH |
| launchAndBuy quote | 0.01 ETH (+ fee) |
| Opening FDV | ≈ $5,000 (asserted) |
| LP owner | ScoopLiquidityLocker |
| Factory custody | 0 ETH / 0 HELLO after launch |
| Fee split | 70/4/20/6 verified |
| Creator claim | PASS |
| CREATE2 grief + fresh salt | PASS |
| Image URI | **REHEARSAL ONLY** `ipfs://bafyrehearsalhello5c...` — not production CID |

---

## Authority Blast Radius (runbook)

| Authority | Can | Cannot |
|-----------|-----|--------|
| `registryAuthority` | Register/disable quotes | Move funds, change factory immutables |
| `oracleAuthority` | Configure/disable feeds, set maxAge | Steal balances; can DoS **new** launches via stale/disable |
| `verificationAuthority` | Bind **unclaimed** X identities | Rebind claimed X; **compromise can steal unclaimed X rewards (F-02)** |

---

## Source Verification Readiness

| Item | Value |
|------|--------|
| solc | 0.8.26 |
| optimizer | true, runs 200 |
| via_ir | true |
| evm | cancun |
| Standard JSON | Generate via `forge verify-contract` / `forge build --out` artifacts at 5D |
| Per-token | ScoopToken artifact + constructor args |

Live explorer verification: **not submitted in 5C**.

---

## Validation Commands

```bash
forge fmt --check
forge build
set -a && source .env && set +a
forge test --match-path 'test/deployment/*' -vv
forge test --match-contract ScoopFactoryForkTest -vv
forge test --match-contract ScoopFactoryMaxRangeLiquidityForkTest -vv
forge test --match-contract ScoopFactoryLaunchFeeForkTest -vv
forge test --match-contract ScoopFactorySecurityForkTest -vv
forge test
```

---

## Pending Production Decisions (block 5D until resolved)

1. Final `verificationAuthority` key ceremony (multisig/HSM recommended)
2. Final `registryAuthority` / `oracleAuthority` addresses (split or combined)
3. Final payable `launchFeeRecipient`, `buybackVault`, `operations` + ETH receive proofs
4. Initial production quote list (ETH required; AAPL **not** auto-enabled)
5. Production ETH + equity `maxAge` policy
6. HELLO production image CID (distinct from rehearsal)
7. Pinned clean git commit for broadcast
8. Live gas price + deployer funding

---

## Blockers

**None for continued rehearsal.**  
**Mainnet broadcast blockers:** pending decisions above.
