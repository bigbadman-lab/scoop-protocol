# Phase 6C.1B — ETH → Quote → SCOOP Token Routing Audit

**Date:** 2026-09-06  
**Scope:** Fork-only proof that a post-launch buyer can purchase a `TOKEN / USDG` SCOOP pool using **native ETH only**, in **one Universal Router transaction**, without Factory changes.  
**Baseline:** `scoop-v1-mainnet-canary` Factory `0x15E874Bc667435ddbF2a67c0362701DC23C90833`, chainId `4663`  
**Prerequisite:** Phase 6C.1 — `USDG READY FOR CONFIGURATION`  
**Constraint:** No mainnet broadcasts. No `src/**` changes. USDG configured **on fork only**.

---

## 1. Executive verdict

**Classification: A — ETH-ONLY POST-LAUNCH BUY PROVEN**

**Final string:** `ETH-ONLY POST-LAUNCH BUY PROVEN`

On a Robinhood mainnet fork, after registering USDG + configuring its Chainlink feed (fork-only), launching a TEST/USDG pool with a USDG-funded creator buy, an ETH-only buyer with **zero USDG** executed:

`WRAP_ETH → V3 WETH→USDG (fee 500) → V4 USDG→TEST → SWEEP`

in a **single** `UniversalRouter.execute{value}` call and received TEST with **0 USDG residual** and **0 WETH residual**. Factory balances were unchanged. Canonical pool remained TEST/USDG.

ScoopFactory does **not** need changes. Post-launch ETH routing belongs in the app/router layer.

---

## 2. Launch-time vs post-launch distinction

| Path | Who pays | Asset required | Who executes |
|---|---|---|---|
| Launch-time optional initial buy | Creator | **Canonical quote** (USDG for TOKEN/USDG) | ScoopFactory `launchAndBuy` pulls ERC-20, Permit2 → UR V4 |
| Launch fee | Creator | **Always native ETH** (`LAUNCH_FEE = 0.0005 ETH`) | Factory → fee recipient |
| Post-launch user buy | User | Ideally native ETH (or quote) | App / Universal Router — **not Factory** |

Fork proof: creator with 0 USDG + approve cannot `launchAndBuy` with USDG quote amount — reverts as expected. Future TOKEN/NVDA initial buys would likewise require NVDA (or whatever the registered quote is). **Do not change this.**

---

## 3. Routing infrastructure (chain 4663)

| Piece | Address / note |
|---|---|
| Universal Router | `0x8876789976dEcBfCbBbe364623C63652db8C0904` (Factory immutable) |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| V3 QuoterV2 | `0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7` |
| WETH/USDG V3 fee 500 | `0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a` (live liquidity) |

UR supports mixed commands: `WRAP_ETH (0x0b)`, `V3_SWAP_EXACT_IN (0x00)`, `V4_SWAP (0x10)`, `SWEEP (0x04)`. Robinhood V4 params include `minHopPriceX36` (Factory uses `0`).

---

## 4. Trading API verdict

Uniswap Trading API against Robinhood:

- Authenticated endpoints return **401** without an API key.
- Legacy unauthenticated `/quote` paths returned **404**.

**Not usable for in-fork proofs without credentials.** Suitable later as a **quote/calldata provider** for production UX (route discovery, slippage, expiry), not as the sole on-chain execution path.

---

## 5. Universal Router verdict

**Direct Universal Router calldata works** for ETH → USDG → TOKEN when:

1. ETH is wrapped to WETH on the router (`ADDRESS_THIS`).
2. V3 exact-in uses `payerIsUser = false` and **`amountIn = CONTRACT_BALANCE` (`1 << 255`)**. Explicit amountIn with router-held WETH reverts `SliceOutOfBounds` on this UR build.
3. V4 hop settles USDG from the **router** (`SETTLE` + `payerIsUser = false` + `CONTRACT_BALANCE`), swaps with `OPEN_DELTA`, `TAKE_ALL` to `msg.sender`.
4. Optional `SWEEP` clears USDG dust.

Factory’s `SETTLE_ALL` (Permit2 pull from caller) is **wrong** for intermediate USDG already sitting on the router.

---

## 6. ETH → USDG route

| Hop | Protocol | Path | Test size |
|---|---|---|---|
| 1 | Uniswap V3 | WETH → USDG, fee **500** | 0.02 ETH → ~49.9 USDG (6 dp) via QuoterV2 |
| 2 | Uniswap V4 | USDG → TEST, fee **10000**, tickSpacing **10**, no hooks | SCOOP canonical pool |

Other V3 fee tiers (100/3000/10000) exist; fee 500 has meaningful liquidity and was used for the proof.

---

## 7. Fork TEST/USDG launch

Fork-only (authority EOA prank):

1. `PRICE_ORACLE.configureFeed(USDG, 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2, 86400)`
2. `QUOTE_REGISTRY.registerQuote(USDG, QuoteType.Scoop)`
3. Creator funded with 25 USDG via `deal`, approved Factory, `launchAndBuy` with `LAUNCH_FEE` in ETH.

Result: TEST token deployed, canonical pool quoteAsset = USDG, creator received TEST from USDG buy.

---

## 8–9. ETH-only buyer / single-tx proof

Buyer start: ETH > 0, USDG = 0, TEST = 0.  
One `execute{value: 0.02 ether}`:

| Metric | Result |
|---|---|
| Buyer TEST | `9688217118946275339200082` (> 0) |
| Buyer USDG residual | **0** |
| Buyer WETH residual | **0** |
| Factory ETH / USDG / TEST | Unchanged / unchanged / 0 |
| Canonical quoteAsset | Still USDG |

---

## 10. Approvals / native ETH handling

Ideal path achieved for the buyer:

- Pays **native ETH** via `msg.value` only.
- **No** WETH approval, **no** USDG approval, **no** Permit2 signature/allowance from the buyer.
- Intermediate WETH/USDG stay on Universal Router until settled into the V4 pool.
- TEST taken to `msg.sender` (buyer).

Creator launch path still needs ERC-20 approve(Factory) for USDG (unchanged product rule).

---

## 11. Slippage / min-out

Production requirements (not locked as UI defaults):

- Exact-in ETH amount from user.
- V3 `amountOutMinimum` from QuoterV2 − slippage bps (fork used 1%).
- V4 `amountOutMinimum` on TEST (fork used `1` wei floor for proof only — production needs a real min).
- `deadline` on `execute`.
- Refresh quotes on each buy attempt; fail closed on expiry / impact.

---

## 12. Fees

| Fee | Applies to post-launch ETH route? |
|---|---|
| SCOOP `LAUNCH_FEE` | **No** |
| Uniswap V3 pool fee (500) | Yes — WETH/USDG hop |
| Uniswap V4 LP fee (10000) | Yes — USDG/TEST hop |
| Gas | Yes — single UR tx |
| UniswapX / API surcharge | N/A for direct UR proof |

---

## 13. Indexer implications

For a multi-hop ETH buy:

- Canonical SCOOP trade remains **USDG → TOKEN** on the Factory pool.
- `tx.from` = buyer; swap sender / router = Universal Router.
- Indexer should keep pair label **Paired with USDG**.
- Optional later: display user payment asset as ETH + route `ETH → USDG → TOKEN`.

No indexer code changed in this phase.

---

## 14. UI implications

Desired buy panel:

- YOU PAY: ETH  
- YOU RECEIVE: TOKEN  
- Optional route detail: `ETH → USDG → TOKEN`  
- Pair label: **Paired with USDG**

Fallback: if no ETH route, allow direct quote-asset buy.

---

## 15. Stock Token extrapolation

Same architecture should extend to TOKEN/AAPL, TOKEN/NVDA, etc. **if**:

- ETH↔stock-token (or WETH↔stock) liquidity exists with acceptable depth.
- UR can settle the stock ERC-20 into the V4 SCOOP pool the same way.
- Token transfer restrictions / trading-hours behavior are handled in product policy.

**Not proven** in this phase — do not claim stock routes work until dedicated fork tests.

---

## 16. Fallback behavior

Show route unavailable and offer direct USDG (quote) buy when:

- No / thin ETH→quote liquidity  
- Excessive price impact  
- Quote expiry / provider outage (if using Trading API)  
- Quote asset paused / transfer-restricted  

---

## 17. Factory recommendation

**Should ScoopFactory change?** **No.**

Factory remains: create token, canonical quote pool, optional quote-denominated initial buy.  
ETH routing lives in **application + Universal Router** (hybrid with Trading API for quotes).

**Where should ETH routing live?** **Hybrid:**

- **Trading API** (when keyed): route discovery, slippage, calldata templates.  
- **Direct UR**: deterministic execution; required for fork tests and as API outage fallback.

---

## 18. Product rule

- Launch-time initial buy: **must use registered quote asset**.  
- Post-launch: **ETH-only single-tx buy is viable** for USDG pairs given live WETH/USDG V3 liquidity + UR multi-command encoding above.  
- Always label the pool by its canonical quote.

---

## 19. Classification

**A — ETH-ONLY POST-LAUNCH BUY PROVEN**

---

## 20. Next action

1. Production: configure USDG (6C.1 enablement) when product-ready.  
2. App: build buy UI path that quotes ETH→USDG→TOKEN and submits UR calldata (Trading API optional).  
3. Harden production mins (slippage, deadlines, impact caps).  
4. Later: stock-token ETH route fork matrix.

---

## Test artifact

`test/deployment/ScoopEthToUsdGRouteFork.t.sol` — 3/3 passed:

- `test_live_routingInfrastructure`
- `test_fork_launchTimeDevBuyRequiresUsdG`
- `test_fork_ethOnlyBuyerSingleTxBuysTest`

---

ETH-ONLY POST-LAUNCH BUY PROVEN
