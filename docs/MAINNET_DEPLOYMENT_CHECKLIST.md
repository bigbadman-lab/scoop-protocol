# SCOOP V1 — Mainnet Deployment Checklist

Use at 5D broadcast time. Do not check boxes until evidence exists.

```text
[ ] 5B security green (no CRITICAL code blockers; findings operationalized)
[ ] 5C fork rehearsal green (deployment + HELLO canary)
[ ] 5C.1 multi-signer tooling green (Phase A/B scripts + ScoopMultiSignerDeploymentFork)
[ ] Audited / reviewed git commit pinned (clean tree preferred)
[ ] Full forge test suite green on pinned commit
[ ] Robinhood RPC healthy (chainId 4663)
[ ] Canonical Uniswap dependency bytecode verified on tip
    [ ] PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951
    [ ] PositionManager 0x58daec3116aae6D93017bAAea7749052E8a04fA7
    [ ] UniversalRouter 0x8876789976dEcBfCbBbe364623C63652db8C0904
    [ ] Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3
[ ] Scoop Deploy 1 funded (gas estimate × safety margin) — Phase A only
[ ] Scoop Auth 1 funded for Phase B config txs only
[ ] DEPLOYER_ADDRESS == Scoop Deploy 1 (FINAL)
[ ] REGISTRY_AUTHORITY == ORACLE_AUTHORITY == Scoop Auth 1 (FINAL)
[ ] VERIFICATION_AUTHORITY == Scoop Verify 1 (FINAL; distinct from Deploy/Auth)
[ ] launchFeeRecipient ETH receive tested (Scoop Treasury 1)
[ ] buybackVault ETH receive tested (Scoop Buyback 1)
[ ] operations ETH receive tested (Scoop Operations 1)
[ ] ETH RECEIVABILITY VERIFIED stamped for all three recipients
[ ] Deploy 1 nonce recorded immediately before Phase A broadcast
[ ] Phase A: DeployScoopGlobals broadcast + STOP
[ ] Phase A manifest recorded (all SCOOP_* handoff addresses)
[ ] Phase A code + immutables verified on-chain
[ ] Phase A: ETH still unregistered/unconfigured
[ ] Phase B: ConfigureScoopProtocol broadcast + STOP
[ ] Phase B: ETH Native quote + canonical ETH/USD feed + maxAge 86400
[ ] AAPL production enablement decided YES/NO (default NO)
[ ] Oracle equity maxAge / off-hours policy decided (if any stock enabled)
[ ] ScoopFactoryDeployer predicted Factory relation verified
[ ] creatorRewards.sourceRegistrar == Factory
[ ] All Factory immutables match intended config
[ ] Gas budget approved at live basefee
[ ] Source verification artifacts ready (solc 0.8.26, via_ir, optimizer 200)
[ ] Broadcast disabled during any final rehearsal
[ ] HELLO final image CID confirmed (≠ rehearsal CID)
[ ] Fresh HELLO salt generated (never reuse disclosed/failed salt)
[ ] Operator runbook reviewed (CREATE2 grief recovery, recipient DoS, authority blast radius)
[ ] STOP after HELLO — no public launches until 5E forensic review
```

## Production multi-signer env (5C.1 / 5D)

```text
ROBINHOOD_RPC_URL
DEPLOYER_ADDRESS              # Scoop Deploy 1 — Phase A
DEPLOYER_PRIVATE_KEY          # 5D Phase A only — never commit
REGISTRY_AUTHORITY            # Scoop Auth 1 — Phase B
ORACLE_AUTHORITY              # must equal REGISTRY_AUTHORITY (MVP)
AUTHORITY_PRIVATE_KEY         # 5D Phase B only — never commit
VERIFICATION_AUTHORITY        # Scoop Verify 1
LAUNCH_FEE_RECIPIENT
BUYBACK_VAULT
OPERATIONS
SCOOP_ETH_MAX_AGE=86400
SCOOP_BROADCAST=false         # set true only for intentional 5D broadcast

# After Phase A handoff:
SCOOP_QUOTE_REGISTRY
SCOOP_PRICE_ORACLE
# (+ other SCOOP_* manifest fields)
```

## Legacy single-signer rehearsal only

`script/DeployScoop.s.sol` — not for production 5D. Requires one sender == registry+oracle authority.
Additional vars: `SCOOP_INCLUDE_AAPL_REHEARSAL`, optional `SCOOP_AAPL_MAX_AGE`.
