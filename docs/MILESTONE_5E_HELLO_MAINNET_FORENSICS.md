# Milestone 5E — HELLO Mainnet Canary Forensics

```text
MILESTONE 5E — COMPLETE

HELLO MAINNET CANARY FORENSICS: PASS
```

The first controlled SCOOP V1 production launch successfully exercised the live production path:

```text
ScoopFactory
→ ScoopToken deployment
→ FeeDistributor deployment
→ LiquidityLocker deployment
→ Uniswap V4 pool initialization
→ LP position creation + locker custody
→ initial ETH buy
→ launch fee routing
→ creator token receipt
```

No second token was launched as part of the 5E forensic process.

Evidence sources for this record:

- Foundry production broadcast artifact: `broadcast/LaunchHello.s.sol/4663/run-latest.json`
- Independent read-only mainnet forensic verification performed after the canary (token metadata, `getLaunch`, balances, LP ownership/liquidity, pool key)

---

## 1. Canonical transaction

| Field | Value |
|-------|--------|
| Transaction | `0xbb4e2f633b3ffb96c0786c9e0b7e096383be3b6472c8e6aec42264f5620d0fe7` |
| Status | SUCCESS (`receipt.status = 0x1`) |
| Chain ID | `4663` (`0x1237`) |
| Block number | `55863290` (`0x35467fa` — from broadcast receipt) |
| Factory | `0x15E874Bc667435ddbF2a67c0362701DC23C90833` |
| From | `0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C` |
| To | `0x15E874Bc667435ddbF2a67c0362701DC23C90833` |
| Function | `launchAndBuy(...)` |
| `msg.value` | `0.0105 ETH` (`0x254db1c2244000`) |
| Nonce | `0` |

---

## 2. Canonical HELLO deployment

| Component | Address |
|-----------|---------|
| HELLO token | `0x2284ed0e4d446c6D78aC2d49a68BAE822Fd87373` |
| Fee distributor | `0x187E2c017bcc52094A9086abAC94Dde7B680a988` |
| Liquidity locker | `0xAa8445659A2424ee1BA33C232Ec05569c975193f` |
| Pool ID | `0xe9ee30525faa467bcc5742f330a47c7d516a56a06f6fd9b302a8599f344f5abc` |
| LP NFT ID | `2004846` |

All three CREATE2 contract addresses matched the addresses predicted before the real broadcast (token, fee distributor, liquidity locker). The broadcast artifact records CREATE2 deployments at those exact addresses.

---

## 3. Creator identity

| Field | Value |
|-------|--------|
| Creator | `0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C` |
| creatorId | `0xffcbd42160aa8079474ac1074616a9c5f6e1e73a422c5a596a2f2cc978fa39ef` |

The Factory launch record was independently read after launch and matched both values. The broadcast calldata and indexed `TokenLaunched` / `InitialBuyExecuted` topics are consistent with the same creator and creatorId.

---

## 4. Locked HELLO metadata (live reads)

Independently verified live token metadata after deployment:

| Field | Value |
|-------|--------|
| Name | `Hello World` |
| Symbol | `HELLO` |
| Decimals | `18` |
| Total supply | `1000000000000000000000000000` |
| Description | `Hello, world. This is a test.` |
| Image | `ipfs://bafybeihzgw4e5bppt5wu2eqrm524xdme6g73rzdoifo5hujjavnm7exwyi` |
| Twitter | `https://x.com/scoopterminal` |
| Telegram | empty |
| Discord | empty |
| Website | `https://scoop.fun` |
| Farcaster | empty |

| Attribution | Value |
|-------------|--------|
| `deployer` | `0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C` |
| `launchFactory` | `0x15E874Bc667435ddbF2a67c0362701DC23C90833` |

These values were read directly from the live HELLO contract after deployment. Launch calldata in the broadcast artifact encodes the same name, symbol, description, image, and socials.

---

## 5. Launch economics

| Field | Value |
|-------|--------|
| Launch fee | `0.0005 ETH` |
| Initial buy | `0.01 ETH` |
| Total `launchAndBuy` `msg.value` | `0.0105 ETH` |
| `minTokensOut` | `1` |

Broadcast receipt confirmation:

- `LaunchFeePaid` amount data = `500000000000000` wei (`0.0005 ETH`)
- `InitialBuyExecuted` quote amount = `10000000000000000` wei (`0.01 ETH`)
- Transaction value = `10500000000000000` wei (`0.0105 ETH`)

Post-launch treasury balance observed during forensics:

```text
0.000500000000000000 ETH
```

This matched the expected HELLO launch fee. This observation is not asserted as a complete historical accounting of all treasury activity beyond the observed canary state.

---

## 6. Initial buyer result

HELLO creator wallet token balance after launch (independent live read):

```text
4900587286892655476445861
```

With 18 decimals:

```text
4,900,587.286892655476445861 HELLO
```

The same amount appears in the broadcast receipt as:

- `InitialBuyExecuted.tokensBought`
- HELLO `Transfer` to the creator wallet

The initial buy therefore delivered non-zero HELLO to the intended creator wallet.

---

## 7. Factory custody invariants

Post-launch live reads:

| Balance | Value | Result |
|---------|--------|--------|
| Factory ETH balance | `0` | PASS |
| Factory HELLO balance | `0` | PASS |

The Factory retained neither native ETH nor HELLO following completion of the canary launch.

---

## 8. Factory launch record

Independent post-launch `getLaunch(HELLO_TOKEN)` matched:

| Field | Value |
|-------|--------|
| `token` | `0x2284ed0e4d446c6D78aC2d49a68BAE822Fd87373` |
| `deployer` | `0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C` |
| `creatorId` | `0xffcbd42160aa8079474ac1074616a9c5f6e1e73a422c5a596a2f2cc978fa39ef` |
| `quoteAsset` | `0x0000000000000000000000000000000000000000` |
| `feeDistributor` | `0x187E2c017bcc52094A9086abAC94Dde7B680a988` |
| `liquidityLocker` | `0xAa8445659A2424ee1BA33C232Ec05569c975193f` |
| `poolId` | `0xe9ee30525faa467bcc5742f330a47c7d516a56a06f6fd9b302a8599f344f5abc` |
| `lpTokenId` | `2004846` |

Native ETH quote is represented by `address(0)`.

---

## 9. LP custody

Live PositionManager `ownerOf(2004846)`:

```text
0xAa8445659A2424ee1BA33C232Ec05569c975193f
```

This exactly matches the Scoop liquidity locker.

```text
LP CUSTODY: PASS
```

Broadcast receipt consistency: PositionManager ERC-721 `Transfer` minted token ID `2004846` (`0x1e976e`) to the liquidity locker.

---

## 10. LP liquidity

Live position liquidity:

```text
44835990424433065953574
```

Liquidity was non-zero after the launch.

---

## 11. Pool configuration

Live pool/position `PoolKey`:

| Field | Value |
|-------|--------|
| `currency0` | `0x0000000000000000000000000000000000000000` |
| `currency1` | `0x2284ed0e4d446c6D78aC2d49a68BAE822Fd87373` |
| `fee` | `10000` |
| `tickSpacing` | `10` |
| `hooks` | `0x0000000000000000000000000000000000000000` |

Interpretation:

```text
native ETH / HELLO
fee = 10000
tickSpacing = 10
no hooks
```

```text
POOL CONFIGURATION: PASS
```

Broadcast receipt consistency: PoolManager `Initialize` for the HELLO pool ID includes currency0 = native zero address and currency1 = HELLO token.

---

## 12. Event / receipt verification

Canonical broadcast artifact:

```text
broadcast/LaunchHello.s.sol/4663/run-latest.json
```

Mainnet receipt confirmation from that artifact:

- status SUCCESS
- originated from the dedicated HELLO creator (`0x35AF…Cf9C`)
- targeted the production ScoopFactory (`0x15E8…0833`)
- included CREATE2 deployments of ScoopToken, ScoopFeeDistributor, and ScoopLiquidityLocker at the predicted addresses
- contained the expected launch / deployment / pool / LP / initial-buy activity

Topic matches present in the receipt (non-exhaustive of all V4 peripheral logs):

| Flow step | Evidence in receipt |
|-----------|---------------------|
| Launch fee payment | `LaunchFeePaid` from Factory; amount `0.0005 ETH` |
| Scoop token creation | CREATE2 ScoopToken + Factory `ScoopTokenCreated` |
| Token launch | Factory `TokenLaunched` (token, deployer, creatorId indexed) |
| V4 pool initialization | PoolManager `Initialize` for HELLO pool id |
| LP position creation | PositionManager ERC-721 mint of LP NFT `2004846` to locker |
| Initial buy execution | Factory `InitialBuyExecuted` (`0.01 ETH` in → `4900587286892655476445861` HELLO out) |
| Token transfer to creator | HELLO `Transfer` to creator for the initial-buy amount |

No event fields beyond those present in the broadcast receipt are asserted here.

---

## 13. Forensic checklist

```text
[x] Mainnet transaction succeeded
[x] HELLO token matched predicted CREATE2 address
[x] FeeDistributor matched prediction
[x] LiquidityLocker matched prediction
[x] Token metadata exact
[x] Token socials exact
[x] Creator exact
[x] creatorId exact
[x] Native ETH quote exact
[x] Factory launch record exact
[x] ETH/HELLO pool initialized
[x] Pool configuration exact
[x] LP liquidity non-zero
[x] LP NFT owned by Scoop liquidity locker
[x] Initial buy executed
[x] Creator received HELLO
[x] Launch fee routed correctly
[x] Factory retained zero ETH
[x] Factory retained zero HELLO
[x] Receipt/event flow consistent with expected launch
[x] No second token launched during 5E
```

---

## 14. Final conclusion

```text
MILESTONE 5E COMPLETE

HELLO MAINNET CANARY FORENSICS: PASS
```

SCOOP V1 has successfully demonstrated its complete production launch lifecycle on Robinhood Chain mainnet using the controlled HELLO canary.

The deployed V1 protocol remains frozen.

The HELLO launch and associated production deployment records now form the canonical production baseline for the next application-layer phase.

Passing the canary does **not** by itself enable public launches.

```text
NEXT PHASE:
Phase 6A — SCOOP Production Data Architecture
```
