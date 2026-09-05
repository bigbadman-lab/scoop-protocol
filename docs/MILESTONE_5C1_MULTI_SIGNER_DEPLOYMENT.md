# Milestone 5C.1 — Production Multi-Signer Deployment Tooling

**Date:** 2026-09-05  
**Scope:** Tooling / tests / docs only. No `src/**` changes. No broadcast. No funding. No HELLO launch.

## Verdict target

```text
MULTI-SIGNER DEPLOYMENT TOOLING READY
```

## Why this milestone existed

5C's combined `DeployScoop.s.sol` assumed one sender could deploy globals **and** call `registerQuote` / `configureFeed`.

Production role split is intentional:

```text
Scoop Deploy 1  ≠  Scoop Auth 1
DEPLOYER_ADDRESS ≠ REGISTRY_AUTHORITY (== ORACLE_AUTHORITY)
```

A live simulation of the combined script deployed globals, then reverted:

```text
ScoopQuoteRegistry::registerQuote(address(0), Native) → Unauthorized()
```

That was a **tooling mismatch**, not a protocol bug.

## Locked production role model

| Role | Wallet | Duties |
|------|--------|--------|
| Scoop Deploy 1 | `DEPLOYER_ADDRESS` | Phase A — deploy globals, pay gas |
| Scoop Auth 1 | `REGISTRY_AUTHORITY` / `ORACLE_AUTHORITY` | Phase B — ETH quote + ETH/USD feed |
| Scoop Verify 1 | `VERIFICATION_AUTHORITY` | X claim signatures only — **neither** deploy nor configure |
| Scoop Treasury 1 | `LAUNCH_FEE_RECIPIENT` | 0.0005 ETH launch fee |
| Scoop Buyback 1 | `BUYBACK_VAULT` | 20% fee allocation |
| Scoop Operations 1 | `OPERATIONS` | 6% + remainder |

Treasury / Buyback / Operations: `cast code` → `0x` (EOAs).  
**ETH RECEIVABILITY PRECHECK: PASS AS EOAs** (no real ETH sent in 5C.1).

## Scripts

### Phase A — `script/DeployScoopGlobals.s.sol`

- Signer: Scoop Deploy 1 (`--sender "$DEPLOYER_ADDRESS"`)
- Deploys: CreatorRegistry, TokenDeployer, LaunchDeployer, QuoteRegistry, PriceOracle, FactoryDeployer → CreatorRewards + Factory
- Does **not** register quotes or configure feeds
- Requires `msg.sender == DEPLOYER_ADDRESS`
- Requires Deploy ≠ Auth ≠ Verify
- Logs immutable deployment manifest, then **STOP**

### Phase B — `script/ConfigureScoopProtocol.s.sol`

- Signer: Scoop Auth 1 (`--sender "$REGISTRY_AUTHORITY"`)
- Inputs: `SCOOP_QUOTE_REGISTRY`, `SCOOP_PRICE_ORACLE`, `SCOOP_ETH_MAX_AGE`
- Registers native ETH (`address(0)`, `QuoteType.Native`)
- Configures canonical ETH/USD feed `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`
- Sets/confirms `maxAge = 86400`
- Does **not** deploy globals
- Does **not** enable AAPL
- **STOP** — HELLO is a later step

### Legacy — `script/DeployScoop.s.sol`

Retained as a **single-signer rehearsal helper** only. Not for production 5D. Requires one sender to be registry+oracle authority.

## Simulation commands (5C.1 — no `--broadcast`)

```bash
set -a && source .env && set +a

# Phase A
forge script script/DeployScoopGlobals.s.sol:DeployScoopGlobals \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$DEPLOYER_ADDRESS" \
  -vvvv

# Record SCOOP_* handoff addresses from the manifest into .env, then:

# Phase B
forge script script/ConfigureScoopProtocol.s.sol:ConfigureScoopProtocol \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$REGISTRY_AUTHORITY" \
  -vvvv
```

### Ephemeral fork state across separate CLI processes

Separate `forge script` simulations do **not** share CREATE state. Phase B against addresses from a prior Phase A simulation will not see those contracts on a fresh fork tip.

**Authoritative end-to-end two-signer proof:**  
`test/deployment/ScoopMultiSignerDeploymentFork.t.sol`

Do not fake persistence between CLI processes.

## Future 5D broadcast (documented only — not executed here)

```bash
# Phase A — Scoop Deploy 1
SCOOP_BROADCAST=true forge script script/DeployScoopGlobals.s.sol:DeployScoopGlobals \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$DEPLOYER_ADDRESS" \
  --broadcast -vvvv
# STOP — record addresses, verify code + immutables, fill SCOOP_* handoff vars

# Phase B — Scoop Auth 1
SCOOP_BROADCAST=true forge script script/ConfigureScoopProtocol.s.sol:ConfigureScoopProtocol \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$REGISTRY_AUTHORITY" \
  --broadcast -vvvv
# STOP — verify ETH quote/oracle; HELLO is separate
```

Broadcast requires explicit `SCOOP_BROADCAST=true` **and** Foundry `--broadcast`. A private key alone must not broadcast.

Never print private keys.

## CREATE / nonce implications

Global deployments use normal `CREATE`. Mainnet addresses depend on:

```text
Scoop Deploy 1 address
account nonce at broadcast time
exact deployment tx sequence in DeployScoopGlobals
```

Before 5D: record current Deploy 1 nonce; avoid unrelated txs if you care about predicted addresses.  
Pre-known addresses are **not** operationally required for V1 MVP if the manifest handoff is recorded immediately after Phase A.

## ETH production config (Phase B)

| Item | Value |
|------|--------|
| Quote | `address(0)` / `Native` |
| Feed | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |
| maxAge | `86400` (proposed production) |
| AAPL | **not** production-enabled by Phase B |

## Tests

| File | Purpose |
|------|---------|
| `ScoopMainnetDeploymentFork.t.sol` | 5C combined rehearsal (incl. AAPL rehearsal path) |
| `ScoopHelloCanaryFork.t.sol` | 5C HELLO canary (unchanged scope) |
| `ScoopMultiSignerDeploymentFork.t.sol` | 5C.1 distinct Deploy vs Auth; negative auth; Verify cannot configure |

## Pending decisions (carry into 5D / ops)

- Formal sign-off that `SCOOP_ETH_MAX_AGE=86400` is final production policy
- Equity / AAPL enablement remains **NO** unless separately approved
- Funding Deploy 1 for gas (not required in 5C.1)
- HELLO production image CID + fresh salt (5D+)

## Explicit non-goals of 5C.1

- No mainnet broadcast  
- No production funding  
- No HELLO launch  
- No `src/**` edits  
- Do not auto-start 5D  

## Validation (2026-09-05)

```text
forge clean + forge build     OK (no DeployHelper/foundry-pp stale warning)
forge fmt --check             OK
test/deployment/*             26 passed / 0 failed / 0 skipped
ScoopFactorySecurityForkTest  11 passed
ScoopFactoryForkTest          9 passed
full suite                    616 passed / 0 failed / 0 skipped
Phase A CLI sim (Deploy 1)    PHASE_A_COMPLETE + STOP
Phase A wrong sender          SenderMismatch (Auth rejected as Deploy)
ScoopFactory runtime          17574 bytes (unchanged vs 5A freeze)
src/**                        unmodified
```

## Operator mantra

```text
Scoop Deploy 1 deploys.
Scoop Auth 1 configures quote/oracle.
Scoop Verify 1 does neither.
Mandatory human STOP between Phase A and Phase B.
```
