# Milestone 5D — HELLO Production Canary

**Scope:** One mainnet HELLO canary launch only. Tooling under `script/LaunchHello.s.sol` + `script/ScoopHelloCanaryLaunch.sol`. Protocol `src/**` is frozen.

**Verdict target:**

```text
HELLO PRODUCTION CANARY TOOLING READY
```

## Preconditions

1. Milestone 5D Phase A complete and independently verified on-chain  
2. Milestone 5D Phase B complete and independently verified on-chain  
3. Native ETH quote registered + enabled; ETH/USD oracle live  
4. ETH feed `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`, `maxAge == 86400`, decimals `8`  
5. AAPL intentionally **not** production-enabled  
6. HELLO production image CID locked (below)  
7. HELLO creator wallet funded (≥ `0.0105 ETH` + gas)  
8. HELLO creator nonce checked (dedicated wallet; canary should start at nonce `0`)  

## Locked production metadata

| Field | Value |
|-------|--------|
| Name | `Hello World` |
| Symbol | `HELLO` |
| Quote | native ETH (`address(0)`) |
| Description | `Hello, world. This is a test.` |
| Image URI | `ipfs://bafybeihzgw4e5bppt5wu2eqrm524xdme6g73rzdoifo5hujjavnm7exwyi` |
| Twitter | `https://x.com/scoopterminal` |
| Telegram / Discord / Farcaster | empty |
| Website | `https://scoop.fun` |

## Locked creator + salt

| Field | Value |
|-------|--------|
| Creator wallet | `0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C` |
| creatorId | `0xffcbd42160aa8079474ac1074616a9c5f6e1e73a422c5a596a2f2cc978fa39ef` |
| Salt | `0x6b7c218e53e0f6a3131e7d4ff2fdd1a214495bdb54eaa2e4201a22ee5d0e3a68` |
| Launch fee | `0.0005 ETH` |
| Initial buy | `0.01 ETH` |
| Total `msg.value` | `0.0105 ETH` |
| `minTokensOut` | `1` |
| Factory | `0x15E874Bc667435ddbF2a67c0362701DC23C90833` |

Do **not** regenerate the salt. Do **not** change metadata or creator wallet.

## Simulation (no chain submit)

```bash
set -a && source .env && set +a

# Ensure:
#   SCOOP_FACTORY=0x15E874Bc667435ddbF2a67c0362701DC23C90833
#   HELLO_CREATOR_ADDRESS=0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C
#   SCOOP_BROADCAST=false

forge script script/LaunchHello.s.sol:LaunchHello \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --sender "$HELLO_CREATOR_ADDRESS" \
  -vvvv
```

### STOP — review simulation

- Confirm predicted token / feeDistributor / liquidityLocker  
- Confirm CREATE2 slots empty  
- Confirm stack assertions (ETH quote/oracle, fee, AAPL off, creatorId)  
- Confirm post-launch assertions in the sim log  
- **Do not broadcast yet**

## Signer-accurate dry-run (still no forge `--broadcast`)

```bash
# Loads HELLO_CREATOR_PRIVATE_KEY. Does NOT submit unless you also pass --broadcast.
SCOOP_BROADCAST=true forge script script/LaunchHello.s.sol:LaunchHello \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  -vvvv
```

### STOP — review dry-run

Human review of manifest + predicted addresses before any real submit.

## Explicit broadcast (mainnet canary)

```bash
SCOOP_BROADCAST=true forge script script/LaunchHello.s.sol:LaunchHello \
  --rpc-url "$ROBINHOOD_RPC_URL" \
  --broadcast \
  -vvvv
```

### STOP after broadcast

```text
STOP - perform mainnet canary forensics before any additional launch
HELLO_CANARY_COMPLETE = true
```

**No second launch** until Milestone **5E** forensic review is complete.

## Post-launch forensic checklist

- [ ] Token address matches prediction  
- [ ] `name == Hello World`, `symbol == HELLO`  
- [ ] Logo / description / socials match locked metadata  
- [ ] `deployer == HELLO creator`, `launchFactory == Factory`  
- [ ] Launch record: correct `creatorId`, `quoteAsset == address(0)`  
- [ ] Fee distributor + liquidity locker non-zero with code  
- [ ] LP NFT owned by liquidity locker  
- [ ] Initial buy tokens held by HELLO creator (`> 0`)  
- [ ] Factory ETH balance `0`; Factory HELLO balance `0`  
- [ ] Launch fee `0.0005 ETH` received by treasury  
- [ ] Events: `LaunchFeePaid`, `ScoopTokenCreated`, `TokenLaunched`, `InitialBuyExecuted`  
- [ ] Hand off to 5E — **no** additional launches  

## Tooling tests

```bash
forge test --match-contract ScoopHelloProductionLaunchToolingForkTest -vvvv
```

## Prohibitions

- Do not change `src/**`  
- Do not enable AAPL or any equity quote for this canary  
- Do not change `SCOOP_ETH_MAX_AGE`  
- Do not build general-purpose public launch tooling yet  
- Do not print or commit private keys  
- Do not launch any second token until 5E completes  
