# SCOOP V1 — Mainnet Deployment Checklist

Use at 5D broadcast time. Do not check boxes until evidence exists.

```text
[ ] 5B security green (no CRITICAL code blockers; findings operationalized)
[ ] 5C fork rehearsal green (deployment + HELLO canary)
[ ] Audited / reviewed git commit pinned (clean tree preferred)
[ ] Full forge test suite green on pinned commit
[ ] Robinhood RPC healthy (chainId 4663)
[ ] Canonical Uniswap dependency bytecode verified on tip
    [ ] PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951
    [ ] PositionManager 0x58daec3116aae6D93017bAAea7749052E8a04fA7
    [ ] UniversalRouter 0x8876789976dEcBfCbBbe364623C63652db8C0904
    [ ] Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3
[ ] Deployer funded (gas estimate × safety margin)
[ ] registryAuthority confirmed (FINAL PRODUCTION VALUE)
[ ] oracleAuthority confirmed (FINAL PRODUCTION VALUE)
[ ] verificationAuthority confirmed (multisig/HSM/hardware EOA — documented)
[ ] launchFeeRecipient ETH receive tested (FINAL address)
[ ] buybackVault ETH receive tested (FINAL address)
[ ] operations ETH receive tested (FINAL address)
[ ] ETH RECEIVABILITY VERIFIED stamped for all three recipients
[ ] Initial quotes approved (ETH required; others explicit)
[ ] AAPL production enablement decided YES/NO (default NO unless approved)
[ ] Oracle feeds approved
[ ] maxAge approved (ETH + any equity policy / off-hours handling)
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

## Env required for `DeployScoop.s.sol`

```text
ROBINHOOD_RPC_URL
VERIFICATION_AUTHORITY
REGISTRY_AUTHORITY
ORACLE_AUTHORITY
LAUNCH_FEE_RECIPIENT
BUYBACK_VAULT
OPERATIONS
SCOOP_ETH_MAX_AGE
SCOOP_INCLUDE_AAPL_REHEARSAL
SCOOP_AAPL_MAX_AGE   # only if INCLUDE=true
DEPLOYER_PRIVATE_KEY # 5D broadcast only — never commit
```
