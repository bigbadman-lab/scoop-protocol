# Phase 6C.2A — Guarded USDG Configuration Tooling

**Date:** 2026-09-06  
**Scope:** Build one-purpose, heavily guarded tooling to configure canonical USDG on Robinhood SCOOP V1, and prove it on a mainnet fork.  
**Baseline:** `scoop-v1-mainnet-canary`, chainId `4663`  
**Prerequisite verdicts:** `USDG READY FOR CONFIGURATION` (6C.1), `ETH-ONLY POST-LAUNCH BUY PROVEN` (6C.1B)

---

## Explicit safety statement

**NO MAINNET TRANSACTION WAS SENT IN 6C.2A.**

This phase only:
- added guarded script + shared logic
- ran fork tests / dry-run script simulation
- documented exact future 6C.2B transactions

---

## 1. Purpose

Ship a dedicated operator path that can, tomorrow (6C.2B), perform exactly two authority writes:

1. `ScoopPriceOracle.configureFeed(USDG, USDG_USD_FEED, 86400)`
2. `ScoopQuoteRegistry.registerQuote(USDG, QuoteType.Scoop)`

…and refuse to run if any canonical guard fails.

---

## 2. Canonical addresses

| Role | Address |
|---|---|
| ScoopQuoteRegistry | `0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD` |
| ScoopPriceOracle | `0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12` |
| ScoopFactory | `0x15E874Bc667435ddbF2a67c0362701DC23C90833` |
| Registry + Oracle authority | `0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| USDG / USD feed | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |
| ETH / USD feed (unchanged check) | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |

USDG metadata: symbol `USDG`, decimals `6`, name `Global Dollar`.  
Feed: description `USDG / USD`, decimals `8`, maxAge `86400`.

---

## 3. Artifacts

| File | Role |
|---|---|
| `script/ConfigureUsdGQuoteLogic.sol` | Shared guards + oracle-first execute + postconditions |
| `script/ConfigureUsdGQuote.s.sol` | Operator script; dry-run by default; broadcast only with `SCOOP_USDG_BROADCAST=true` |
| `test/deployment/ScoopConfigureUsdGQuoteFork.t.sol` | Fork guards, happy path, launch rehearsal |
| `docs/PHASE_6C_2A_USDG_CONFIGURATION_TOOLING.md` | This document |

`src/**` untouched.

---

## 4. Guards

Hard failures before any write:

- `chainId == 4663`
- QuoteRegistry / PriceOracle / USDG / feed addresses exact
- `registryAuthority` and `oracleAuthority` == production authority
- broadcast caller == authority (broadcast path only)
- USDG symbol/decimals
- feed description/decimals + live `latestRoundData()` freshness vs maxAge
- USDG not yet registered
- USDG oracle not yet configured

Refuse partial / write-once collisions: if already registered or already configured → revert and report.

---

## 5. Exact two-write sequence (oracle-first)

**Invariant:** registered quotes start **enabled**. Therefore configure the oracle **before** registering the quote.

1. `PRICE_ORACLE.configureFeed(USDG, USDG_USD_FEED, 86400)`
2. `QUOTE_REGISTRY.registerQuote(USDG, QuoteType.Scoop)` // enum value `1`

No ETH writes. No stock writes. No extra enable toggles (both start enabled).

---

## 6. Events (from source)

- `PriceFeedConfigured(address indexed quoteAsset, address indexed feed, uint48 maxAge, uint8 feedDecimals)`
- `QuoteRegistered(address indexed asset, QuoteType indexed quoteType)`

---

## 7. Fork simulation results

`ScoopConfigureUsdGQuoteForkTest`: **12/12 passed**

Includes:
- happy path (oracle then register + event topic checks)
- wrong chain / registry / oracle / USDG / feed
- unauthorized caller
- already configured / already registered refusal
- stale feed refusal
- ETH config unchanged after USDG config
- full `launchAndBuy` rehearsal against USDG (creator receives tokens; Factory holds 0 USDG/token/ETH; LP NFT owned by liquidity locker)

ETH-routing regression: covered by Phase 6C.1B (`ScoopEthToUsdGRouteForkTest`); not duplicated as a mega-harness here. Launch rehearsal confirms post-config Factory path.

Dry-run script (no broadcast) succeeded against live RPC and printed sanitized preconditions.

---

## 8. Gas estimates (fork)

Measured via `gasleft()` around each call as authority:

| Tx | Function | Gas (approx) |
|---|---|---|
| TX1 | `configureFeed` | ~80,980 |
| TX2 | `registerQuote` | ~98,769 |
| **Total** | | **~180k** |

Recommended authority wallet ETH buffer for 6C.2B: **≥ 0.01 ETH** (large safety margin vs ~180k gas on Robinhood).

---

## 9. Future 6C.2B command — DO NOT EXECUTE IN 6C.2A

Prefer Foundry keystore / hardware signer over raw private keys in shell history:

```bash
SCOOP_USDG_BROADCAST=true forge script script/ConfigureUsdGQuote.s.sol:ConfigureUsdGQuote \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --account <authority-keystore-account> \
  --sender 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7 \
  --broadcast -vvvv
```

Dry-run (safe anytime):

```bash
forge script script/ConfigureUsdGQuote.s.sol:ConfigureUsdGQuote \
  --rpc-url "$ROBINHOOD_RPC_URL" -vvvv
```

---

## 10. Human-review calldata — DO NOT SEND — FOR 6C.2B HUMAN REVIEW ONLY

### TX1 — configure oracle feed

- **Target:** ScoopPriceOracle `0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12`
- **Function:** `configureFeed(address,address,uint48)`
- **Args:**
  - `quoteAsset = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
  - `feed = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`
  - `maxAge = 86400`
- **Calldata:**
  ```
  0x05dcbd6e0000000000000000000000005fc5360d0400a0fd4f2af552add042d716f1d16800000000000000000000000061b7e5650328764b076a108eff5fa7282a1b9ad20000000000000000000000000000000000000000000000000000000000015180
  ```

### TX2 — register quote

- **Target:** ScoopQuoteRegistry `0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD`
- **Function:** `registerQuote(address,uint8)`
- **Args:**
  - `asset = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
  - `quoteType = 1` (`QuoteType.Scoop`)
- **Calldata:**
  ```
  0xe36c992e0000000000000000000000005fc5360d0400a0fd4f2af552add042d716f1d1680000000000000000000000000000000000000000000000000000000000000001
  ```

**Expected mainnet tx count: 2**

---

## 11. Partial-state recovery

If TX1 succeeds and TX2 fails:

- State: oracle configured, quote **not** registered — **safe** (USDG not yet enabled as a launchable quote).
- Recovery: investigate failure; if USDG still unregistered, send **TX2 only**.
- Do **not** re-send TX1 (write-once feed).

If TX1 fails: **do not send TX2**.

Do not auto-retry blindly.

---

## 12. Emergency disable (after successful config; do not execute now)

V1 cannot unregister or replace the feed.

Authority may disable:

1. `quoteRegistry.setQuoteEnabled(USDG, false)`
2. `priceOracle.setFeedEnabled(USDG, false)`

Authority: same EOA `0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7`  
Tx count: 2

---

## 13. 6C.2B human checklist (do not execute tonight)

- [ ] git clean / correct commit reviewed
- [ ] chainId 4663
- [ ] authority wallet available (keystore/hardware preferred)
- [ ] authority funded (≥ 0.01 ETH recommended)
- [ ] USDG still unregistered
- [ ] oracle still unconfigured for USDG
- [ ] USDG metadata rechecked (symbol/decimals)
- [ ] feed live + fresh
- [ ] fork simulation green
- [ ] calldata reviewed (section 10)
- [ ] TX1 broadcast
- [ ] TX1 receipt + `isConfigured(USDG)==true` / feed match / maxAge 86400
- [ ] TX2 broadcast
- [ ] TX2 receipt + `isRegistered(USDG)==true` / enabled / type Scoop
- [ ] ETH quote still registered/enabled; ETH feed/maxAge unchanged
- [ ] `getPriceUsd(USDG) > 0`
- [ ] later app/indexer sync check

---

## 14. Final verdict

**USDG CONFIGURATION TOOLING READY FOR HUMAN REVIEW**
