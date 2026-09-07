#!/usr/bin/env python3
"""Guarded, resumable production runner for remaining SCOOP stock quotes.

Default mode is DRY RUN / PREFLIGHT ONLY (no transactions).

Broadcast (DO NOT run unless explicitly intended):
  ROBINHOOD_RPC_URL=... AUTHORITY_PRIVATE_KEY=... \\
    python3 script/configure_remaining_stock_catalogue.py --broadcast

Dry-run against live mainnet:
  ROBINHOOD_RPC_URL=... AUTHORITY_PRIVATE_KEY=... \\
    python3 script/configure_remaining_stock_catalogue.py
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Optional

# ── Canonical production constants (frozen) ──────────────────────────────────

CHAIN_ID = 4663
QUOTE_REGISTRY = "0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD"
PRICE_ORACLE = "0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12"
AUTHORITY = "0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7"

USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
USDG_USD_FEED = "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2"
ETH_USD_FEED = "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9"
ETH_MAX_AGE = 86_400
USDG_MAX_AGE = 86_400

STOCK_MAX_AGE = 345_600
STOCK_QUOTE_TYPE = 2  # QuoteType.Stock
STOCK_FEED_DECIMALS = 8

CANARY_SYMBOLS = ("AAPL", "AMD")

# Safety floor for authority ETH before any write.
# 18 remaining × 2 txs × ~150k gas ≈ ~5.4M gas; Robinhood fees are low.
# Floor is intentionally conservative and explicit — not silent.
MIN_AUTHORITY_ETH_WEI = 10**16  # 0.01 ETH

DEFAULT_MANIFEST = Path("audit/final-production-stock-manifest-20.json")
DEFAULT_LOG = Path("audit/stock-mainnet-execution-log.json")

REPO_ROOT = Path(__file__).resolve().parents[1]


class Abort(Exception):
    """Hard stop — do not continue to later stocks."""


class StockState(str, Enum):
    UNTOUCHED = "untouched"  # State A — TX1 then TX2
    ORACLE_ONLY = "oracle_only"  # State B — TX2 only
    COMPLETE = "complete"  # State C — skip
    INVALID = "invalid"


@dataclass
class FeedConfig:
    feed: str
    max_age: int
    feed_decimals: int
    enabled: bool


@dataclass
class StockLiveState:
    symbol: str
    token: str
    oracle_configured: bool
    oracle_enabled: bool
    feed_config: Optional[FeedConfig]
    price_usd: Optional[int]
    registered: bool
    quote_enabled: bool
    quote_type: Optional[int]
    classification: StockState
    needs_tx1: bool
    needs_tx2: bool
    note: str = ""


@dataclass
class StockLogEntry:
    symbol: str
    token: str
    feed: str
    initialState: str
    tx1Hash: Optional[str] = None
    tx1Block: Optional[int] = None
    tx1GasUsed: Optional[int] = None
    tx1Verified: Optional[bool] = None
    tx2Hash: Optional[str] = None
    tx2Block: Optional[int] = None
    tx2GasUsed: Optional[int] = None
    tx2Verified: Optional[bool] = None
    finalState: Optional[str] = None
    completedAt: Optional[str] = None
    error: Optional[str] = None


@dataclass
class ExecutionLog:
    chainId: int = CHAIN_ID
    authority: str = AUTHORITY
    startedAt: Optional[str] = None
    updatedAt: Optional[str] = None
    mode: str = "DRY_RUN"
    stocks: list[dict[str, Any]] = field(default_factory=list)


# ── Helpers ──────────────────────────────────────────────────────────────────


def _norm(addr: str) -> str:
    if not isinstance(addr, str) or not addr.startswith("0x") or len(addr) != 42:
        raise Abort(f"invalid address: {addr!r}")
    return addr.lower()


def _checksum_eq(a: str, b: str) -> bool:
    return _norm(a) == _norm(b)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, sort_keys=False)
            f.write("\n")
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def load_manifest(path: Path) -> list[dict[str, Any]]:
    raw = json.loads(path.read_text())
    if not isinstance(raw, list):
        raise Abort("manifest must be a JSON array")
    if len(raw) != 20:
        raise Abort(f"manifest count must be 20, got {len(raw)}")
    symbols = []
    for i, entry in enumerate(raw):
        for key in ("symbol", "token", "feed", "feedDecimals", "maxAge", "quoteType", "tx1", "tx2"):
            if key not in entry:
                raise Abort(f"manifest[{i}] missing {key}")
        if entry["maxAge"] != STOCK_MAX_AGE:
            raise Abort(f"{entry['symbol']}: maxAge must be {STOCK_MAX_AGE}")
        if entry["quoteType"] != STOCK_QUOTE_TYPE:
            raise Abort(f"{entry['symbol']}: quoteType must be {STOCK_QUOTE_TYPE}")
        if entry["feedDecimals"] != STOCK_FEED_DECIMALS:
            raise Abort(f"{entry['symbol']}: feedDecimals must be {STOCK_FEED_DECIMALS}")
        if not isinstance(entry["tx1"], dict) or "calldata" not in entry["tx1"]:
            raise Abort(f"{entry['symbol']}: tx1.calldata required")
        if not isinstance(entry["tx2"], dict) or "calldata" not in entry["tx2"]:
            raise Abort(f"{entry['symbol']}: tx2.calldata required")
        if not _checksum_eq(entry["tx1"]["target"], PRICE_ORACLE):
            raise Abort(f"{entry['symbol']}: tx1.target mismatch")
        if not _checksum_eq(entry["tx2"]["target"], QUOTE_REGISTRY):
            raise Abort(f"{entry['symbol']}: tx2.target mismatch")
        symbols.append(entry["symbol"])
    if len(set(symbols)) != 20:
        raise Abort("manifest symbols must be unique")
    for canary in CANARY_SYMBOLS:
        if canary not in symbols:
            raise Abort(f"manifest missing canary {canary}")
    return raw


def build_configure_feed_calldata(token: str, feed: str, max_age: int = STOCK_MAX_AGE) -> str:
    """Rebuild TX1 calldata via cast; must match frozen manifest exactly."""
    out = subprocess.check_output(
        [
            "cast",
            "calldata",
            "configureFeed(address,address,uint48)",
            token,
            feed,
            str(max_age),
        ],
        text=True,
    ).strip()
    if not out.startswith("0x"):
        raise Abort(f"cast calldata configureFeed failed: {out!r}")
    return out.lower()


def build_register_quote_calldata(token: str, quote_type: int = STOCK_QUOTE_TYPE) -> str:
    out = subprocess.check_output(
        [
            "cast",
            "calldata",
            "registerQuote(address,uint8)",
            token,
            str(quote_type),
        ],
        text=True,
    ).strip()
    if not out.startswith("0x"):
        raise Abort(f"cast calldata registerQuote failed: {out!r}")
    return out.lower()


def assert_calldata_matches_manifest(entry: dict[str, Any]) -> None:
    tx1 = build_configure_feed_calldata(entry["token"], entry["feed"], entry["maxAge"])
    tx2 = build_register_quote_calldata(entry["token"], entry["quoteType"])
    if tx1 != entry["tx1"]["calldata"].lower():
        raise Abort(
            f"{entry['symbol']}: TX1 calldata mismatch\n  local={tx1}\n  manifest={entry['tx1']['calldata'].lower()}"
        )
    if tx2 != entry["tx2"]["calldata"].lower():
        raise Abort(
            f"{entry['symbol']}: TX2 calldata mismatch\n  local={tx2}\n  manifest={entry['tx2']['calldata'].lower()}"
        )


# ── RPC via cast ─────────────────────────────────────────────────────────────


class CastRpc:
    def __init__(self, rpc_url: str):
        if not rpc_url.startswith(("http://", "https://")):
            raise Abort("ROBINHOOD_RPC_URL must be http(s)")
        self.rpc_url = rpc_url

    def _run(self, args: list[str], *, sensitive: bool = False) -> str:
        # Never include private keys in exception messages.
        try:
            p = subprocess.run(args, text=True, capture_output=True, check=False)
        except Exception as e:
            raise Abort(f"cast invocation failed: {type(e).__name__}") from None
        if p.returncode != 0:
            err = p.stderr.strip() or p.stdout.strip()
            if sensitive:
                err = "<redacted>"
            raise Abort(f"cast failed ({args[1] if len(args) > 1 else '?'}): {err[:400]}")
        return p.stdout.strip()

    def call(self, address: str, sig: str, *args: str) -> str:
        cmd = ["cast", "call", address, sig, *args, "--rpc-url", self.rpc_url]
        return self._run(cmd)

    def chain_id(self) -> int:
        return int(self._run(["cast", "chain-id", "--rpc-url", self.rpc_url]))

    def balance_wei(self, address: str) -> int:
        out = self._run(["cast", "balance", address, "--rpc-url", self.rpc_url])
        return int(out.split()[0], 0)

    def block_timestamp(self) -> int:
        out = self._run(
            ["cast", "block", "latest", "--field", "timestamp", "--rpc-url", self.rpc_url]
        )
        return int(out.split()[0], 0)

    def send_calldata(
        self,
        *,
        to: str,
        calldata: str,
        private_key: str,
        from_addr: str,
    ) -> dict[str, Any]:
        # cast send prints tx hash; receipt via cast receipt
        cmd = [
            "cast",
            "send",
            to,
            calldata,
            "--rpc-url",
            self.rpc_url,
            "--private-key",
            private_key,
            "--from",
            from_addr,
            "--json",
        ]
        raw = self._run(cmd, sensitive=True)
        try:
            receipt = json.loads(raw)
        except json.JSONDecodeError:
            # Fallback: treat stdout as hash then fetch receipt
            tx_hash = raw.splitlines()[-1].strip()
            if not tx_hash.startswith("0x"):
                raise Abort("cast send did not return JSON receipt or tx hash")
            receipt = self.wait_receipt(tx_hash)
            return receipt
        # Some cast versions return receipt JSON directly
        if "transactionHash" in receipt or "transaction_hash" in receipt:
            return receipt
        if "hash" in receipt:
            return self.wait_receipt(receipt["hash"])
        raise Abort("unexpected cast send JSON shape")

    def wait_receipt(self, tx_hash: str, timeout_s: int = 180) -> dict[str, Any]:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            p = subprocess.run(
                ["cast", "receipt", tx_hash, "--rpc-url", self.rpc_url, "--json"],
                text=True,
                capture_output=True,
            )
            if p.returncode == 0 and p.stdout.strip():
                try:
                    return json.loads(p.stdout)
                except json.JSONDecodeError:
                    pass
            time.sleep(2)
        raise Abort(f"timed out waiting for receipt {tx_hash}")


def derive_signer_address(private_key: str) -> str:
    # cast wallet address never echoes the key back in normal success output
    p = subprocess.run(
        ["cast", "wallet", "address", "--private-key", private_key],
        text=True,
        capture_output=True,
    )
    if p.returncode != 0:
        raise Abort("failed to derive signer address from AUTHORITY_PRIVATE_KEY")
    addr = p.stdout.strip()
    if not addr.startswith("0x") or len(addr) != 42:
        raise Abort("derived signer address malformed")
    return addr


def parse_bool(out: str) -> bool:
    v = out.splitlines()[0].strip().lower()
    if v in ("true", "1"):
        return True
    if v in ("false", "0"):
        return False
    raise Abort(f"expected bool, got {out!r}")


def parse_uint(out: str) -> int:
    line = out.splitlines()[0].strip()
    # cast may append scientific notation comments
    token = line.split()[0]
    return int(token, 0)


def parse_address(out: str) -> str:
    line = out.splitlines()[0].strip().split()[0]
    if not line.startswith("0x"):
        raise Abort(f"expected address, got {out!r}")
    return line


def parse_feed_config(out: str) -> FeedConfig:
    """Parse cast tuple output for getFeedConfig."""
    # Examples:
    # (0xabc..., 345600 [3.456e5], 8, true)
    text = out.strip()
    if text.startswith("(") and text.endswith(")"):
        text = text[1:-1]
    # Split carefully on commas not inside brackets — simple approach for our shape
    parts = []
    cur = []
    depth = 0
    for ch in text:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur).strip())
    if len(parts) < 4:
        raise Abort(f"unparseable feed config: {out!r}")
    feed = parts[0].split()[0]
    max_age = int(parts[1].split()[0], 0)
    decimals = int(parts[2].split()[0], 0)
    enabled = parts[3].split()[0].lower() in ("true", "1")
    return FeedConfig(feed=feed, max_age=max_age, feed_decimals=decimals, enabled=enabled)


# ── On-chain reads ───────────────────────────────────────────────────────────


def read_oracle_configured(rpc: CastRpc, asset: str) -> bool:
    return parse_bool(rpc.call(PRICE_ORACLE, "isConfigured(address)(bool)", asset))


def read_oracle_enabled(rpc: CastRpc, asset: str) -> bool:
    return parse_bool(rpc.call(PRICE_ORACLE, "isEnabled(address)(bool)", asset))


def read_feed_config(rpc: CastRpc, asset: str) -> FeedConfig:
    out = rpc.call(PRICE_ORACLE, "getFeedConfig(address)((address,uint48,uint8,bool))", asset)
    return parse_feed_config(out)


def read_price_usd(rpc: CastRpc, asset: str) -> int:
    return parse_uint(rpc.call(PRICE_ORACLE, "getPriceUsd(address)(uint256)", asset))


def read_registered(rpc: CastRpc, asset: str) -> bool:
    return parse_bool(rpc.call(QUOTE_REGISTRY, "isRegistered(address)(bool)", asset))


def read_quote_enabled(rpc: CastRpc, asset: str) -> bool:
    return parse_bool(rpc.call(QUOTE_REGISTRY, "isEnabled(address)(bool)", asset))


def read_quote_type(rpc: CastRpc, asset: str) -> int:
    return parse_uint(rpc.call(QUOTE_REGISTRY, "quoteType(address)(uint8)", asset))


def read_quote_count(rpc: CastRpc) -> int:
    return parse_uint(rpc.call(QUOTE_REGISTRY, "registeredQuoteCount()(uint256)"))


def check_feed_round(
    *,
    round_id: int,
    answer: int,
    updated_at: int,
    answered_in_round: int,
    now_ts: int,
    max_age: int = STOCK_MAX_AGE,
    feed: str = "feed",
) -> None:
    if answer <= 0:
        raise Abort(f"feed {feed}: answer <= 0")
    if updated_at <= 0:
        raise Abort(f"feed {feed}: updatedAt == 0")
    if updated_at > now_ts:
        raise Abort(f"feed {feed}: updatedAt > block timestamp")
    if now_ts - updated_at > max_age:
        raise Abort(f"feed {feed}: stale age={now_ts - updated_at} > maxAge={max_age}")
    if answered_in_round < round_id:
        raise Abort(f"feed {feed}: incomplete round answeredInRound < roundId")


def assert_feed_fresh(rpc: CastRpc, feed: str, max_age: int = STOCK_MAX_AGE) -> None:
    out = rpc.call(
        feed,
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)",
    )
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    # cast may print one value per line
    vals = []
    for ln in lines:
        token = ln.split()[0]
        try:
            vals.append(int(token, 0))
        except ValueError:
            continue
    if len(vals) < 5:
        # try single-line tuple
        text = out.strip()
        if text.startswith("(") and ")" in text:
            inner = text[1 : text.index(")")]
            vals = []
            for part in inner.split(","):
                token = part.strip().split()[0]
                vals.append(int(token, 0))
    if len(vals) < 5:
        raise Abort(f"unparseable latestRoundData for {feed}: {out!r}")
    round_id, answer, _started, updated_at, answered_in_round = vals[:5]
    now_ts = rpc.block_timestamp()
    check_feed_round(
        round_id=round_id,
        answer=answer,
        updated_at=updated_at,
        answered_in_round=answered_in_round,
        now_ts=now_ts,
        max_age=max_age,
        feed=feed,
    )

def assert_eth_healthy(rpc: CastRpc) -> None:
    # native ETH quote is address(0)
    zero = "0x0000000000000000000000000000000000000000"
    if not read_registered(rpc, zero):
        raise Abort("ETH: not registered")
    if not read_quote_enabled(rpc, zero):
        raise Abort("ETH: not enabled")
    if not read_oracle_configured(rpc, zero):
        raise Abort("ETH: oracle not configured")
    if not read_oracle_enabled(rpc, zero):
        raise Abort("ETH: oracle not enabled")
    cfg = read_feed_config(rpc, zero)
    if not _checksum_eq(cfg.feed, ETH_USD_FEED):
        raise Abort("ETH: feed mismatch")
    if cfg.max_age != ETH_MAX_AGE:
        raise Abort(f"ETH: maxAge mismatch ({cfg.max_age})")
    if not cfg.enabled:
        raise Abort("ETH: feed disabled")
    if read_price_usd(rpc, zero) <= 0:
        raise Abort("ETH: getPriceUsd <= 0")


def assert_usdg_healthy(rpc: CastRpc) -> None:
    if not read_registered(rpc, USDG):
        raise Abort("USDG: not registered")
    if not read_quote_enabled(rpc, USDG):
        raise Abort("USDG: not enabled")
    if read_quote_type(rpc, USDG) != 1:  # QuoteType.Scoop
        raise Abort("USDG: quoteType must be Scoop (1)")
    if not read_oracle_configured(rpc, USDG):
        raise Abort("USDG: oracle not configured")
    if not read_oracle_enabled(rpc, USDG):
        raise Abort("USDG: oracle not enabled")
    cfg = read_feed_config(rpc, USDG)
    if not _checksum_eq(cfg.feed, USDG_USD_FEED):
        raise Abort("USDG: feed mismatch")
    if cfg.max_age != USDG_MAX_AGE:
        raise Abort(f"USDG: maxAge mismatch ({cfg.max_age})")
    if cfg.feed_decimals != 8:
        raise Abort("USDG: feedDecimals must be 8")
    if not cfg.enabled:
        raise Abort("USDG: feed disabled")
    if read_price_usd(rpc, USDG) <= 0:
        raise Abort("USDG: getPriceUsd <= 0")


def oracle_matches_manifest(cfg: FeedConfig, entry: dict[str, Any], price: Optional[int]) -> bool:
    return (
        _checksum_eq(cfg.feed, entry["feed"])
        and cfg.max_age == STOCK_MAX_AGE
        and cfg.feed_decimals == STOCK_FEED_DECIMALS
        and cfg.enabled is True
        and price is not None
        and price > 0
    )


def registry_matches_manifest(
    *,
    registered: bool,
    enabled: bool,
    quote_type: Optional[int],
) -> bool:
    return registered is True and enabled is True and quote_type == STOCK_QUOTE_TYPE


def classify_from_reads(
    entry: dict[str, Any],
    *,
    configured: bool,
    registered: bool,
    oracle_enabled: bool = False,
    feed_config: Optional[FeedConfig] = None,
    price: Optional[int] = None,
    quote_enabled: bool = False,
    quote_type: Optional[int] = None,
) -> StockLiveState:
    """Pure state-machine classification (unit-testable without RPC)."""
    token = entry["token"]
    symbol = entry["symbol"]

    if registered and not configured:
        return StockLiveState(
            symbol=symbol,
            token=token,
            oracle_configured=configured,
            oracle_enabled=oracle_enabled,
            feed_config=feed_config,
            price_usd=price,
            registered=registered,
            quote_enabled=quote_enabled,
            quote_type=quote_type,
            classification=StockState.INVALID,
            needs_tx1=False,
            needs_tx2=False,
            note="registered without oracle",
        )

    if not configured and not registered:
        return StockLiveState(
            symbol=symbol,
            token=token,
            oracle_configured=False,
            oracle_enabled=False,
            feed_config=None,
            price_usd=None,
            registered=False,
            quote_enabled=False,
            quote_type=None,
            classification=StockState.UNTOUCHED,
            needs_tx1=True,
            needs_tx2=True,
        )

    if configured and not registered:
        assert feed_config is not None
        if not oracle_matches_manifest(feed_config, entry, price):
            return StockLiveState(
                symbol=symbol,
                token=token,
                oracle_configured=True,
                oracle_enabled=oracle_enabled,
                feed_config=feed_config,
                price_usd=price,
                registered=False,
                quote_enabled=False,
                quote_type=None,
                classification=StockState.INVALID,
                needs_tx1=False,
                needs_tx2=False,
                note="oracle-only but config does not match manifest",
            )
        return StockLiveState(
            symbol=symbol,
            token=token,
            oracle_configured=True,
            oracle_enabled=oracle_enabled,
            feed_config=feed_config,
            price_usd=price,
            registered=False,
            quote_enabled=False,
            quote_type=None,
            classification=StockState.ORACLE_ONLY,
            needs_tx1=False,
            needs_tx2=True,
        )

    assert feed_config is not None
    if not oracle_matches_manifest(feed_config, entry, price) or not registry_matches_manifest(
        registered=registered, enabled=quote_enabled, quote_type=quote_type
    ):
        return StockLiveState(
            symbol=symbol,
            token=token,
            oracle_configured=True,
            oracle_enabled=oracle_enabled,
            feed_config=feed_config,
            price_usd=price,
            registered=True,
            quote_enabled=quote_enabled,
            quote_type=quote_type,
            classification=StockState.INVALID,
            needs_tx1=False,
            needs_tx2=False,
            note="fully present but readback does not match manifest",
        )

    return StockLiveState(
        symbol=symbol,
        token=token,
        oracle_configured=True,
        oracle_enabled=True,
        feed_config=feed_config,
        price_usd=price,
        registered=True,
        quote_enabled=True,
        quote_type=STOCK_QUOTE_TYPE,
        classification=StockState.COMPLETE,
        needs_tx1=False,
        needs_tx2=False,
    )


def classify_stock(rpc: CastRpc, entry: dict[str, Any]) -> StockLiveState:
    token = entry["token"]
    configured = read_oracle_configured(rpc, token)
    registered = read_registered(rpc, token)

    feed_config = None
    price = None
    oracle_enabled = False
    quote_enabled = False
    quote_type = None

    if configured:
        oracle_enabled = read_oracle_enabled(rpc, token)
        feed_config = read_feed_config(rpc, token)
        try:
            price = read_price_usd(rpc, token)
        except Abort:
            price = None

    if registered:
        quote_enabled = read_quote_enabled(rpc, token)
        quote_type = read_quote_type(rpc, token)

    return classify_from_reads(
        entry,
        configured=configured,
        registered=registered,
        oracle_enabled=oracle_enabled,
        feed_config=feed_config,
        price=price,
        quote_enabled=quote_enabled,
        quote_type=quote_type,
    )


def verify_oracle_after_tx1(rpc: CastRpc, entry: dict[str, Any]) -> None:
    token = entry["token"]
    if not read_oracle_configured(rpc, token):
        raise Abort(f"{entry['symbol']}: after TX1 isConfigured=false")
    if not read_oracle_enabled(rpc, token):
        raise Abort(f"{entry['symbol']}: after TX1 isEnabled=false")
    cfg = read_feed_config(rpc, token)
    if not _checksum_eq(cfg.feed, entry["feed"]):
        raise Abort(f"{entry['symbol']}: after TX1 feed mismatch")
    if cfg.max_age != STOCK_MAX_AGE:
        raise Abort(f"{entry['symbol']}: after TX1 maxAge mismatch")
    if cfg.feed_decimals != STOCK_FEED_DECIMALS:
        raise Abort(f"{entry['symbol']}: after TX1 feedDecimals mismatch")
    if not cfg.enabled:
        raise Abort(f"{entry['symbol']}: after TX1 feed disabled")
    if read_price_usd(rpc, token) <= 0:
        raise Abort(f"{entry['symbol']}: after TX1 getPriceUsd <= 0")
    if read_registered(rpc, token):
        raise Abort(f"{entry['symbol']}: after TX1 unexpectedly registered")


def verify_after_tx2(rpc: CastRpc, entry: dict[str, Any]) -> None:
    token = entry["token"]
    if not read_registered(rpc, token):
        raise Abort(f"{entry['symbol']}: after TX2 not registered")
    if not read_quote_enabled(rpc, token):
        raise Abort(f"{entry['symbol']}: after TX2 not enabled")
    if read_quote_type(rpc, token) != STOCK_QUOTE_TYPE:
        raise Abort(f"{entry['symbol']}: after TX2 quoteType != Stock")
    if not read_oracle_configured(rpc, token) or not read_oracle_enabled(rpc, token):
        raise Abort(f"{entry['symbol']}: after TX2 oracle not configured/enabled")
    cfg = read_feed_config(rpc, token)
    if not oracle_matches_manifest(cfg, entry, read_price_usd(rpc, token)):
        raise Abort(f"{entry['symbol']}: after TX2 oracle readback mismatch")


def receipt_ok(receipt: dict[str, Any]) -> tuple[str, int, int]:
    status = receipt.get("status", receipt.get("Status"))
    if isinstance(status, str):
        status_i = int(status, 0)
    else:
        status_i = int(status)
    if status_i != 1:
        raise Abort(f"receipt status != 1 ({status})")
    tx_hash = receipt.get("transactionHash") or receipt.get("transaction_hash") or receipt.get("hash")
    if not tx_hash:
        raise Abort("receipt missing transactionHash")
    block = receipt.get("blockNumber") or receipt.get("block_number")
    gas = receipt.get("gasUsed") or receipt.get("gas_used")
    if isinstance(block, str):
        block = int(block, 0)
    if isinstance(gas, str):
        gas = int(gas, 0)
    return str(tx_hash), int(block), int(gas)


# ── Execution log ────────────────────────────────────────────────────────────


def load_log(path: Path) -> ExecutionLog:
    if not path.exists():
        return ExecutionLog()
    data = json.loads(path.read_text())
    return ExecutionLog(
        chainId=data.get("chainId", CHAIN_ID),
        authority=data.get("authority", AUTHORITY),
        startedAt=data.get("startedAt"),
        updatedAt=data.get("updatedAt"),
        mode=data.get("mode", "DRY_RUN"),
        stocks=list(data.get("stocks") or []),
    )


def upsert_stock_log(log: ExecutionLog, entry: StockLogEntry) -> None:
    found = False
    for i, existing in enumerate(log.stocks):
        if existing.get("symbol") == entry.symbol:
            log.stocks[i] = asdict(entry)
            found = True
            break
    if not found:
        log.stocks.append(asdict(entry))
    log.updatedAt = utc_now()


def save_log(path: Path, log: ExecutionLog) -> None:
    payload = asdict(log)
    # Never persist private-key material. Tx hashes are 32-byte hex and are allowed.
    blob = json.dumps(payload)
    if "AUTHORITY_PRIVATE_KEY" in blob:
        raise Abort("refusing to write log that appears to contain secrets")
    lowered = blob.lower()
    if "private_key" in lowered or "privatekey" in lowered:
        raise Abort("refusing to write log that appears to contain secrets")
    atomic_write_json(path, payload)


# ── Global preflight ─────────────────────────────────────────────────────────


def global_preflight(
    rpc: CastRpc,
    manifest: list[dict[str, Any]],
    signer: str,
    *,
    require_balance: bool,
) -> None:
    if rpc.chain_id() != CHAIN_ID:
        raise Abort(f"wrong chainId: expected {CHAIN_ID}")
    reg_auth = parse_address(rpc.call(QUOTE_REGISTRY, "registryAuthority()(address)"))
    ora_auth = parse_address(rpc.call(PRICE_ORACLE, "oracleAuthority()(address)"))
    if not _checksum_eq(reg_auth, AUTHORITY):
        raise Abort("registryAuthority mismatch")
    if not _checksum_eq(ora_auth, AUTHORITY):
        raise Abort("oracleAuthority mismatch")
    if not _checksum_eq(signer, AUTHORITY):
        raise Abort("signer is not production authority — abort before any transaction")

    for entry in manifest:
        assert_calldata_matches_manifest(entry)

    assert_eth_healthy(rpc)
    assert_usdg_healthy(rpc)

    by_symbol = {e["symbol"]: e for e in manifest}
    for canary in CANARY_SYMBOLS:
        st = classify_stock(rpc, by_symbol[canary])
        if st.classification != StockState.COMPLETE:
            raise Abort(f"canary {canary} not fully live matching manifest ({st.classification}: {st.note})")

    count = read_quote_count(rpc)
    if count < 4:
        raise Abort(f"registeredQuoteCount expected >= 4 (ETH+USDG+AAPL+AMD), got {count}")

    if require_balance:
        bal = rpc.balance_wei(AUTHORITY)
        if bal < MIN_AUTHORITY_ETH_WEI:
            raise Abort(
                f"authority ETH balance {bal} wei < safety floor {MIN_AUTHORITY_ETH_WEI} wei "
                f"({MIN_AUTHORITY_ETH_WEI / 10**18} ETH)"
            )


def final_verification(rpc: CastRpc, manifest: list[dict[str, Any]]) -> None:
    assert_eth_healthy(rpc)
    assert_usdg_healthy(rpc)
    for entry in manifest:
        st = classify_stock(rpc, entry)
        if st.classification != StockState.COMPLETE:
            raise Abort(f"final verification failed for {entry['symbol']}: {st.classification} {st.note}")
    count = read_quote_count(rpc)
    if count != 22:
        raise Abort(f"final registeredQuoteCount expected 22, got {count}")


# ── Planning / printing ──────────────────────────────────────────────────────


def plan_from_states(states: list[StockLiveState]) -> dict[str, Any]:
    complete = [s.symbol for s in states if s.classification == StockState.COMPLETE]
    remaining = [s for s in states if s.classification in (StockState.UNTOUCHED, StockState.ORACLE_ONLY)]
    invalid = [s for s in states if s.classification == StockState.INVALID]
    writes = sum((1 if s.needs_tx1 else 0) + (1 if s.needs_tx2 else 0) for s in remaining)
    return {
        "complete": complete,
        "remaining": remaining,
        "invalid": invalid,
        "writes": writes,
    }


def print_dry_run(signer: str, plan: dict[str, Any], *, mode: str) -> None:
    print("SCOOP STOCK MAINNET RUNNER")
    print(f"chainId: {CHAIN_ID}")
    print(f"authority: {signer}")
    print("manifest: 20")
    print("already complete:")
    for sym in plan["complete"]:
        print(f"  {sym}")
    if not plan["complete"]:
        print("  (none)")
    print()
    print("remaining:")
    for s in plan["remaining"]:
        tag = "TX1+TX2" if s.needs_tx1 else "TX2-only"
        print(f"  {s.symbol}  ({tag})")
    if not plan["remaining"]:
        print("  (none)")
    print()
    print(f"writes required: {plan['writes']}")
    print(f"mode: {mode}")
    if mode == "DRY_RUN":
        print("NO TRANSACTIONS SENT")


def print_final_table(manifest: list[dict[str, Any]]) -> None:
    for entry in manifest:
        print(f"{entry['symbol']:<6} COMPLETE")
    print()
    print("20/20 STOCKS COMPLETE")
    print("REGISTERED_QUOTE_COUNT=22")


# ── Per-stock processing ─────────────────────────────────────────────────────


def process_stock(
    rpc: CastRpc,
    entry: dict[str, Any],
    state: StockLiveState,
    *,
    broadcast: bool,
    private_key: Optional[str],
    log: ExecutionLog,
    log_path: Path,
) -> None:
    symbol = entry["symbol"]
    if state.classification == StockState.COMPLETE:
        upsert_stock_log(
            log,
            StockLogEntry(
                symbol=symbol,
                token=entry["token"],
                feed=entry["feed"],
                initialState=state.classification.value,
                finalState="complete",
                completedAt=utc_now(),
            ),
        )
        save_log(log_path, log)
        return

    if state.classification == StockState.INVALID:
        raise Abort(f"{symbol}: invalid state — {state.note}")

    if not broadcast:
        # Dry-run path: no freshness/calldata/RPC writes (run() never reaches here).
        return

    assert_calldata_matches_manifest(entry)
    assert_feed_fresh(rpc, entry["feed"])

    log_entry = StockLogEntry(
        symbol=symbol,
        token=entry["token"],
        feed=entry["feed"],
        initialState=state.classification.value,
    )

    if private_key is None:
        raise Abort("broadcast requested but AUTHORITY_PRIVATE_KEY missing")

    # TX1
    if state.needs_tx1:
        print(f">>> {symbol}: sending TX1 configureFeed ...")
        try:
            receipt = rpc.send_calldata(
                to=PRICE_ORACLE,
                calldata=entry["tx1"]["calldata"],
                private_key=private_key,
                from_addr=AUTHORITY,
            )
            txh, block, gas = receipt_ok(receipt)
        except Abort as e:
            log_entry.error = str(e)
            upsert_stock_log(log, log_entry)
            save_log(log_path, log)
            raise

        log_entry.tx1Hash = txh
        log_entry.tx1Block = block
        log_entry.tx1GasUsed = gas
        try:
            verify_oracle_after_tx1(rpc, entry)
            log_entry.tx1Verified = True
        except Abort as e:
            log_entry.tx1Verified = False
            log_entry.error = str(e)
            upsert_stock_log(log, log_entry)
            save_log(log_path, log)
            raise Abort(f"{symbol}: TX1 succeeded but readback failed — NOT sending TX2: {e}") from e
        upsert_stock_log(log, log_entry)
        save_log(log_path, log)
        print(f">>> {symbol}: TX1 verified ({txh})")

    # Re-check freshness immediately before TX2
    assert_feed_fresh(rpc, entry["feed"])
    assert_calldata_matches_manifest(entry)

    # TX2 (UNTOUCHED has needs_tx2=True; ORACLE_ONLY resumes at TX2)
    if state.needs_tx2:
        print(f">>> {symbol}: sending TX2 registerQuote ...")
        try:
            receipt = rpc.send_calldata(
                to=QUOTE_REGISTRY,
                calldata=entry["tx2"]["calldata"],
                private_key=private_key,
                from_addr=AUTHORITY,
            )
            txh, block, gas = receipt_ok(receipt)
        except Abort as e:
            log_entry.error = str(e)
            upsert_stock_log(log, log_entry)
            save_log(log_path, log)
            raise

        log_entry.tx2Hash = txh
        log_entry.tx2Block = block
        log_entry.tx2GasUsed = gas
        try:
            verify_after_tx2(rpc, entry)
            log_entry.tx2Verified = True
            log_entry.finalState = "complete"
            log_entry.completedAt = utc_now()
        except Abort as e:
            log_entry.tx2Verified = False
            log_entry.error = str(e)
            upsert_stock_log(log, log_entry)
            save_log(log_path, log)
            raise
        upsert_stock_log(log, log_entry)
        save_log(log_path, log)
        print(f">>> {symbol}: TX2 verified ({txh}) COMPLETE")


# ── Main ─────────────────────────────────────────────────────────────────────


def run(
    *,
    broadcast: bool,
    manifest_path: Path,
    log_path: Path,
    confirm_fn: Optional[Callable[[str], str]] = None,
) -> int:
    rpc_url = os.environ.get("ROBINHOOD_RPC_URL", "").strip()
    private_key = os.environ.get("AUTHORITY_PRIVATE_KEY", "").strip()
    if not rpc_url:
        raise Abort("ROBINHOOD_RPC_URL required")
    if not private_key:
        raise Abort("AUTHORITY_PRIVATE_KEY required (used to verify signer; never printed)")

    # Normalize key for cast (no logging)
    if not private_key.startswith("0x"):
        private_key = "0x" + private_key

    os.chdir(REPO_ROOT)
    manifest = load_manifest(manifest_path)
    rpc = CastRpc(rpc_url)
    signer = derive_signer_address(private_key)

    global_preflight(rpc, manifest, signer, require_balance=broadcast)

    states = [classify_stock(rpc, entry) for entry in manifest]
    for st in states:
        if st.classification == StockState.INVALID:
            raise Abort(f"{st.symbol}: invalid live state — {st.note}")

    plan = plan_from_states(states)
    mode = "BROADCAST" if broadcast else "DRY_RUN"
    print_dry_run(signer, plan, mode=mode)

    remaining_n = len(plan["remaining"])
    writes = plan["writes"]

    if remaining_n == 0:
        print()
        print("Nothing remaining — running final verification...")
        final_verification(rpc, manifest)
        print_final_table(manifest)
        return 0

    if not broadcast:
        # Dry-run: zero chain writes and zero execution-log mutations.
        print()
        print(f"Dry-run complete. Remaining stocks: {remaining_n}. Expected writes if broadcast: {writes}.")
        return 0

    log = load_log(log_path)
    if not log.startedAt:
        log.startedAt = utc_now()
    log.mode = mode
    log.authority = AUTHORITY
    log.chainId = CHAIN_ID
    save_log(log_path, log)

    # Human confirmation gate
    expected = f"BROADCAST {remaining_n} STOCKS"
    prompt = f"Type {expected} to continue: "
    fn = confirm_fn or input
    typed = fn(prompt)
    if typed.strip() != expected:
        raise Abort("confirmation mismatch — aborting without transactions")

    state_by_symbol = {s.symbol: s for s in states}

    for entry in manifest:
        st = state_by_symbol[entry["symbol"]]
        if st.classification == StockState.COMPLETE:
            continue
        # Re-classify live immediately before acting (chain is source of truth)
        live = classify_stock(rpc, entry)
        if live.classification == StockState.INVALID:
            raise Abort(f"{entry['symbol']}: invalid before write — {live.note}")
        if live.classification == StockState.COMPLETE:
            continue
        process_stock(
            rpc,
            entry,
            live,
            broadcast=True,
            private_key=private_key,
            log=log,
            log_path=log_path,
        )

    print()
    print("All remaining stocks processed — final verification...")
    final_verification(rpc, manifest)
    print_final_table(manifest)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="SCOOP remaining stock catalogue production runner")
    parser.add_argument(
        "--broadcast",
        action="store_true",
        help="Enable live writes (default is dry-run / preflight only)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help="Path to frozen 20-stock manifest",
    )
    parser.add_argument(
        "--log",
        type=Path,
        default=DEFAULT_LOG,
        help="Path to execution log JSON",
    )
    args = parser.parse_args(argv)
    try:
        return run(broadcast=args.broadcast, manifest_path=args.manifest, log_path=args.log)
    except Abort as e:
        print(f"ABORT: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
