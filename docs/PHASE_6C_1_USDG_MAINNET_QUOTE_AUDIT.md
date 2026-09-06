# Phase 6C.1 — USDG Mainnet Quote Audit

**Date:** 2026-09-06  
**Scope:** Read-only compatibility audit of canonical USDG against deployed SCOOP V1 on Robinhood Chain (`chainId = 4663`).  
**Baseline:** `scoop-v1-mainnet-canary` @ `c8268c0a97274cb751f4077d0e28450caf276357`  
**Constraint:** No mainnet broadcasts. No `src/**` changes. No production USDG enablement.

---

## 1. Executive verdict

**Classification: A — READY FOR CONFIGURATION**

**Final string:** `USDG READY FOR CONFIGURATION`

Deployed SCOOP V1 already supports ERC-20 quotes with decimals `≤ 18`, AggregatorV3 feeds, Permit2 → Universal Router initial buys, and a native-ETH launch fee independent of quote asset. Canonical USDG is a 6-decimal ERC-20 behind an EIP-1967 proxy. A live Chainlink `USDG / USD` AggregatorV3 proxy exists on Robinhood Chain and matches `ScoopPriceOracle`.

USDG is **not** registered or oracle-configured in production today. Enabling it is configuration-only — **no protocol redeploy**.

Fork proof (this phase): register + configure on a mainnet fork, then `launch` and `launchAndBuy` with USDG — **9/9 tests passed**.

---

## 2. Current deployed SCOOP quote architecture

| Component | Address |
|---|---|
| ScoopQuoteRegistry | `0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD` |
| ScoopPriceOracle | `0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12` |
| ScoopFactory | `0x15E874Bc667435ddbF2a67c0362701DC23C90833` |

### ScoopQuoteRegistry

- `registerQuote(asset, quoteType)` — authority-only; write-once identity; **starts enabled**.
- `setQuoteEnabled(asset, enabled)` — authority-only toggle; type immutable.
- Native ETH = `address(0)` / `QuoteType.Native`.
- ERC-20 quotes use `QuoteType.Scoop | Stock | Pons`.
- No decimals stored; no bytecode check at registration.
- Immutable `registryAuthority`.

### ScoopPriceOracle

- `configureFeed(quoteAsset, feed, maxAge)` — authority-only; **write-once feed**; starts enabled.
- Requires AggregatorV3 `decimals()` + `latestRoundData()`; feed must have code; feed decimals `≤ 18`.
- `getPriceUsd` → 1e18 USD (`1e18 = $1`).
- **No fixed/$1 stable mode.**
- `setFeedEnabled` / `setMaxAge` allowed; feed address cannot be replaced in V1.
- Immutable `oracleAuthority`.

### ScoopFactory launch path

1. Collect fixed `LAUNCH_FEE = 0.0005 ETH` → `launchFeeRecipient` (**always native ETH**).
2. Require quote registered + enabled.
3. Read quote decimals (`address(0)` → 18); revert if `> 18`.
4. `priceOracle.getPriceUsd(quoteAsset)`.
5. `ScoopLaunchMath.calculateLaunchPricing(...)` → sqrtPriceX96 + one-sided LP ticks.
6. Init v4 pool; mint one-sided launched-token LP; assert zero quote principal delta.
7. Optional `launchAndBuy`: ERC-20 `transferFrom` exact amount, then Permit2 → Universal Router exact-in swap.

---

## 3. Current live USDG state (production)

| Check | Result |
|---|---|
| Quote registered | **false** |
| Quote enabled | **false** |
| Oracle configured | **false** |
| Oracle enabled | **false** |
| Registered quote count | `1` (native ETH only) |

ETH remains registered + enabled with feed `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`, `maxAge = 86400`, feed decimals `8`.

---

## 4. Canonical USDG contract verification

| Field | Value |
|---|---|
| Official docs address | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` ([Robinhood Chain contracts](https://docs.robinhood.com/chain/contracts/)) |
| Onchain code | EIP-1967 proxy |
| `name()` | `Global Dollar` |
| `symbol()` | `USDG` |
| `decimals()` | **6** |
| `totalSupply()` | ~`6.465e14` base units at audit |
| EIP-1967 implementation | `0x68184C449E1a8f34fA18d289737129FD27B66f8F` (**upgradeable**) |
| `paused()` | `false` (at audit) |

---

## 5. USDG ERC-20 characteristics

- Standard ERC-20 surface responds (`approve` / `transfer` / `transferFrom` / `allowance` / `balanceOf`).
- No `isBlacklisted` / `frozen` selectors found on the proxy surface probed.
- `paused()` present and currently false — issuer pause risk remains.
- Upgradeable implementation → issuer can change semantics later (ops risk).
- Fee-on-transfer would fail Factory exact-pull / post-buy asserts; fork path used exact transfers successfully.

---

## 6. Decimal analysis

USDG decimals = **6** (live).

```text
TARGET_FDV_USD (5_000e18)
  → TOKEN_USD_PRICE = 5e12
  → quotePriceUsd from oracle (~1e18)
  → encode sqrtPriceX96 with 10^6 quote decimals and 10^18 token decimals
  → one-sided LP in launched token only
  → initial buy consumes USDG base units (6 dp)
```

`ScoopLaunchMath` already unit-tests 6/8/18 quote decimals. Factory reads decimals live. **No hidden 18-decimal quote assumption.** Fork launch with USDG confirmed.

---

## 7. ScoopQuoteRegistry compatibility

**Verdict: COMPATIBLE**

Register as `QuoteType.Scoop` (only non-Native/Stock/Pons bucket). No immutable block against USDG.

---

## 8. ScoopPriceOracle compatibility

**Verdict: COMPATIBLE (feed required; no static $1 mode)**

Possibility B (fixed $1) **does not exist** in deployed V1. Possibility A succeeds via live Chainlink feed.

---

## 9. USDG/USD oracle findings

| Item | Value |
|---|---|
| Source | Chainlink `feeds-robinhood-mainnet.json` entry **`USDG / USD`** |
| Proxy | `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2` |
| `description()` | `USDG / USD` |
| `decimals()` | `8` |
| Directory heartbeat | `86400` |
| Directory threshold | `0.5%` |
| Live answer (audit) | `99993909` ≈ **$0.99993909** |
| Freshness (audit) | ~3–4h ≪ 86400s |
| Oracle normalize (fork) | `getPriceUsd(USDG) = 999939090000000000` |
| Interface match | Yes |
| Recommended maxAge | **86400** (match ETH production + heartbeat) |

**Possibility C does not apply.**

---

## 10. Factory launch math/path

Oracle price every launch; 6-decimal USDG is first-class via `quoteDecimals`; pool currencies sorted by address; opening sqrt is oracle-derived; LP is one-sided launched-token. Fork asserted opening sqrt matches `ScoopLaunchMath.calculateLaunchPricing`.

---

## 11. ERC-20 initial-buy / Permit2 path

**Verdict: SUPPORTED (fork-proven)**

`msg.value == LAUNCH_FEE` only; user approves Factory; Factory exact `transferFrom`; Permit2 allowance to Universal Router; exact-in V4 swap; no stranded Factory USDG/token/ETH. Example fork buy: `10e6` USDG → `~1.976e24` tokens out.

---

## 12. Native launch-fee behavior

**Proven:** `LAUNCH_FEE` is always paid in native ETH to immutable `launchFeeRecipient`, **even when quoteAsset = USDG**.

Live: `LAUNCH_FEE = 5e14` wei (0.0005 ETH), recipient `0xCb2D4ceD82B5E9e013F4db58F999662052aE1FA3` (EOA).

---

## 13. Uniswap v4 ordering / liquidity

- PoolKey sorts USDG vs ScoopToken by address.
- Initial LP has **zero quote principal**.
- Factory asserts ERC-20 quote balance unchanged across LP mint.
- Initial buy is quote→token exact-in via Universal Router.
- LP NFT custodied by launch liquidity locker (fork-asserted).

---

## 14. Mainnet fork results

Contract: `test/deployment/ScoopUsdGQuoteAuditFork.t.sol` (`ScoopUsdGQuoteAuditForkTest`).

| Test | Result |
|---|---|
| Live USDG metadata | PASS |
| Live SCOOP USDG unconfigured | PASS |
| Live authorities + fee | PASS |
| Live USDG/USD feed compatible | PASS |
| Math 6-decimal ~$1 quote | PASS |
| Fork configure + launch | PASS |
| Fork launchAndBuy | PASS |
| Fork exact native fee only | PASS |
| Fork unauthorized configure reverts | PASS |

**9/9 passed.** No broadcasts.

---

## 15. Admin / signer authority

| Role | Live address | Code |
|---|---|---|
| `registryAuthority` | `0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7` | EOA |
| `oracleAuthority` | `0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7` | Same EOA |

---

## 16. Exact future configuration sequence (DO NOT EXECUTE in 6C.1)

Caller: `0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7` on chain `4663`.

```text
1. Verify chainId == 4663 and caller == registryAuthority == oracleAuthority
2. Precondition:
     quoteRegistry.isRegistered(USDG) == false
     priceOracle.isConfigured(USDG) == false
3. ScoopPriceOracle.configureFeed(
     0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,
     0x61B7e5650328764B076A108EFF5fa7282a1B9aD2,
     86400
   )
4. ScoopQuoteRegistry.registerQuote(USDG, QuoteType.Scoop)  // uint8(1)
5. Read-back asserts (registered/enabled/configured/getPriceUsd ≈ 1e18)
6. Fork launch rehearsal (already covered)
7. STOP for human review
8. Future Phase 6C.2 broadcast only
```

Optional: after register, `setQuoteEnabled(USDG, false)` until feed verified, then re-enable.

---

## 17. Rollback / disable path

```text
quoteRegistry.setQuoteEnabled(USDG, false)
priceOracle.setFeedEnabled(USDG, false)
```

No unregister / feed replace in V1.

---

## 18. Risks / open questions

1. Upgradeable USDG — monitor pause/upgrade events.
2. Peg can deviate; SCOOP prices from feed, not assumed $1.
3. Heartbeat 86400 — same staleness class as ETH.
4. Single EOA authority for quote + oracle.
5. `QuoteType.Scoop` taxonomy has no `Stable` label — document policy choice.
6. No L2 sequencer uptime check (same as ETH today).
7. **6C.3 stock-token prep:** 18-decimal ERC-20s, per-asset Chainlink feeds, multiplier already in feed — do not re-apply `uiMultiplier`. Catalogue via `GET https://api.robinhood.com/rhj/assets`. Do not configure in this phase.

---

## 19. Production readiness classification

```text
A — READY FOR CONFIGURATION
```

---

## 20. Recommended 6C.2 action

1. Dedicated guarded script `script/ConfigureUsdGQuote.s.sol` (prefer over reusing ETH-only `ConfigureScoopProtocol.s.sol`).
2. Guards: chainId 4663, canonical addresses, USDG + feed guards, authority match, preconditions, dry-run default, explicit broadcast flag only, postcondition asserts, no key logging.
3. Simulate → human review → broadcast.
4. Post-config fork canary with small USDG buy.
5. Do not enable stock tokens in 6C.2.

---

## ETH vs USDG comparison

| Concern | ETH | USDG |
|---|---|---|
| Quote representation | native `address(0)` | ERC-20 `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| Decimals | 18 | **6** |
| User payment | `msg.value` | `transferFrom` + approve |
| Launch fee | 0.0005 ETH | **0.0005 ETH (still native)** |
| Price oracle | ETH/USD | USDG/USD |
| Initial buy | native via router | ERC-20 via Permit2→UR |
| Pool ordering | address sort | address sort vs token |
| Approvals | none for quote | Factory ERC-20 approve |
| Failure modes | wrong msg.value | allowance/balance/FOT/pause |

---

## End state

```text
USDG READY FOR CONFIGURATION
```
