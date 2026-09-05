# SCOOP V1 — Mainnet Deployment Runbook (5D)

**Pre-mainnet rule:** rehearse on a current Robinhood fork first. 5C did not broadcast.

## 0. Preflight

1. Checkout pinned commit from checklist.
2. `forge test` green; RPC `eth_chainId == 0x1237` (4663).
3. Confirm bytecode at PoolManager / PositionManager / UniversalRouter / Permit2.
4. Confirm final authorities + payable recipients; send 0.01 ETH test transfers to recipients.
5. Set `.env` with FINAL values only (no silent defaults).
6. Generate HELLO salt offline; do not disclose early.
7. Confirm HELLO production image CID.

## 1. Deploy globals (broadcast)

Order (via `forge script script/DeployScoop.s.sol:DeployScoop --broadcast` **only in 5D**):

1. CreatorRegistry  
2. TokenDeployer  
3. LaunchDeployer  
4. QuoteRegistry  
5. PriceOracle  
6. Configure ETH quote + oracle (`maxAge` approved)  
7. Optional approved non-ETH quotes (explicit)  
8. FactoryDeployer → CreatorRewards + Factory  

If `registryAuthority != oracleAuthority`, split configure txs per key.

## 2. Verify addresses

- Manifest every address  
- `predictedFactory == factory`  
- `sourceRegistrar == factory`  
- All Factory immutables  
- ETH registered/enabled; feed fresh; `getPriceUsd(0) > 0`

## 3. Verify source (explorer)

- Submit global contracts with constructor args  
- Record solc 0.8.26 / via_ir / optimizer 200  

## 4. Launch HELLO (canary)

1. Fresh salt  
2. Wallet creator ≠ protocol authorities  
3. Prefer plain `launch` then optional small `launchAndBuy` (0.01 ETH)  
4. Confirm metadata, FDV ≈ $5k, LP locker ownership, fee 0.0005 ETH, factory empty  
5. Optional: one buy/sell + fee collect/distribute/claim  

## 5. STOP

**Do not** proceed to public launches. Hand off to **5E forensic review**.

## Operational rules

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
Keep offline / multisig / HSM. No day-to-day hot wallet.

### Rejecting recipients (F-03 / F-04)
- Shared buyback/ops reject → ETH `distribute` DoS **globally**  
- Per-launch deployer reject → DoS **that launch only**  
Require payable EOAs or contracts with working `receive`/`fallback`.

### Oracle
- Stale/disabled feed blocks **new** launches for that quote  
- Existing pools continue to trade  
- Equity feeds: plan for nights/weekends before enabling stocks
