# SCOOP V1 — Mainnet Deployment Runbook (5D)

**Pre-mainnet rule:** rehearse on a current Robinhood fork first. 5C / 5C.1 did not broadcast.

**Operator mantra:**

```text
Scoop Deploy 1 deploys globals.
Scoop Auth 1 configures ETH quote/oracle.
Scoop Verify 1 does neither.
Mandatory human STOP between Phase A and Phase B.
No one-shot deploy+configure broadcast.
```

## 0. Preflight

1. Checkout pinned commit from checklist.
2. `forge test` green; RPC `eth_chainId == 0x1237` (4663).
3. Confirm bytecode at PoolManager / PositionManager / UniversalRouter / Permit2.
4. Confirm FINAL role mapping in `.env` (Deploy ≠ Auth ≠ Verify).
5. Confirm payable recipients (EOA or proven `receive`); send 0.01 ETH test transfers.
6. Record Scoop Deploy 1 current nonce; avoid unrelated txs until Phase A completes.
7. Set `SCOOP_ETH_MAX_AGE=86400` (proposed production) and `SCOOP_BROADCAST=false` until ready.
8. Generate HELLO salt offline; do not disclose early.
9. Confirm HELLO production image CID.

## 1. Phase A — Scoop Deploy 1 broadcasts globals

```bash
set -a && source .env && set +a
SCOOP_BROADCAST=true forge script script/DeployScoopGlobals.s.sol:DeployScoopGlobals \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast -vvvv
```

Deploys only:

1. CreatorRegistry  
2. TokenDeployer  
3. LaunchDeployer  
4. QuoteRegistry  
5. PriceOracle  
6. FactoryDeployer → CreatorRewards + Factory  

Does **not** register quotes or configure feeds.

### STOP after Phase A

- Copy full deployment manifest into secure ops notes + `.env` handoff vars  
- Verify code at every address  
- Assert immutables / authorities / `predictedFactory` / `sourceRegistrar`  
- Confirm ETH is still **unregistered / unconfigured**  
- Do not proceed until a second human confirms the handoff  

## 2. Phase B — Scoop Auth 1 configures ETH only

```bash
# Ensure SCOOP_QUOTE_REGISTRY + SCOOP_PRICE_ORACLE are set from Phase A
SCOOP_BROADCAST=true forge script script/ConfigureScoopProtocol.s.sol:ConfigureScoopProtocol \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$REGISTRY_AUTHORITY" \
  --broadcast -vvvv
```

Configures only:

- Native ETH quote (`address(0)`)  
- Canonical ETH/USD feed `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`  
- `maxAge == 86400`  

Does **not** enable AAPL. Does **not** deploy contracts.

### STOP after Phase B

- Verify quote registered/enabled + Native  
- Verify feed address / enabled / maxAge / `getPriceUsd(0) > 0`  
- Confirm AAPL not production-registered by this path  

## 3. Verify source (explorer)

- Submit global contracts with constructor args  
- Record solc 0.8.26 / via_ir / optimizer 200  

## 4. Launch HELLO (canary) — separate step

See **[`docs/MILESTONE_5D_HELLO_CANARY.md`](./MILESTONE_5D_HELLO_CANARY.md)** for the locked metadata, salt, creator, simulation, and broadcast commands.

One-off tooling: `script/LaunchHello.s.sol` (helpers in `script/ScoopHelloCanaryLaunch.sol`).

```bash
set -a && source .env && set +a
# SCOOP_FACTORY + HELLO_CREATOR_ADDRESS required; SCOOP_BROADCAST=false

forge script script/LaunchHello.s.sol:LaunchHello \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$HELLO_CREATOR_ADDRESS" \
  -vvvv
```

### STOP after HELLO simulation

Review predicted addresses + manifest. Do not broadcast until a second human confirms.

### Explicit HELLO broadcast (only after STOP clearance)

```bash
SCOOP_BROADCAST=true forge script script/LaunchHello.s.sol:LaunchHello \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --broadcast -vvvv
```

Post-launch: confirm metadata, FDV ≈ $5k, LP locker ownership, fee `0.0005 ETH`, factory empty, initial buy to HELLO creator.

## 5. STOP

**Do not** proceed to public launches. Hand off to **5E forensic review**.
**No second launch** until Milestone 5E is complete.

## Simulation (no broadcast) — 5C.1

```bash
forge script script/DeployScoopGlobals.s.sol:DeployScoopGlobals \
  --rpc-url "$ROBINHOOD_RPC_URL" --sender "$DEPLOYER_ADDRESS" -vvvv

forge script script/ConfigureScoopProtocol.s.sol:ConfigureScoopProtocol \
  --rpc-url "$ROBINHOOD_RPC_URL" --sender "$REGISTRY_AUTHORITY" -vvvv
```

Separate script processes do not share ephemeral CREATE state. End-to-end two-signer persistence is proven by:

```text
test/deployment/ScoopMultiSignerDeploymentFork.t.sol
```

## Legacy combined script

`script/DeployScoop.s.sol` is a single-signer **rehearsal** helper only. Do not use it for production multi-signer 5D.

## Operational rules

### CREATE / nonce (Phase A)
```text
mainnet addresses = f(Scoop Deploy 1, nonce, tx sequence)
record nonce before Phase A; avoid unrelated Deploy 1 txs mid-deploy
```

### CREATE2 grief (F-01)
```text
fresh random salt per attempt
never reuse a disclosed/failed salt
```
If launch reverts on CREATE2: generate new salt and retry.

### verificationAuthority (F-02)
```text
verificationAuthority compromise can steal unclaimed X creator rewards.
```
Keep offline / multisig / HSM. No day-to-day hot wallet. Verify 1 must not hold registry/oracle authority.

### Rejecting recipients (F-03 / F-04)
- Shared buyback/ops reject → ETH `distribute` DoS **globally**  
- Per-launch deployer reject → DoS **that launch only**  
Require payable EOAs or contracts with working `receive`/`fallback`.

### Oracle
- Stale/disabled feed blocks **new** launches for that quote  
- Existing pools continue to trade  
- Equity feeds: plan for nights/weekends before enabling stocks
