#!/usr/bin/env python3
"""Guarded, resumable production runner for SCOOP stock quotes (canonical stack).

Default mode is DRY RUN / PREFLIGHT ONLY (no transactions).

Dry-run (full catalogue or selected symbols):
  ROBINHOOD_RPC_URL=... AUTHORITY_PRIVATE_KEY=... \\
    SCOOP_QUOTE_REGISTRY=... SCOOP_PRICE_ORACLE=... \\
    python3 script/configure_remaining_stock_catalogue.py [--symbols AAPL,AMD]

Broadcast (explicit symbols REQUIRED — DO NOT run unless intended):
  ROBINHOOD_RPC_URL=... AUTHORITY_PRIVATE_KEY=... \\
    SCOOP_QUOTE_REGISTRY=... SCOOP_PRICE_ORACLE=... \\
    python3 script/configure_remaining_stock_catalogue.py --symbols AAPL,AMD --broadcast
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

# ── Canonical production constants (non-deployment identities) ───────────────

CHAIN_ID = 4663
AUTHORITY = "0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7"

USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
USDG_USD_FEED = "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2"
ETH_USD_FEED = "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9"
ETH = "0x0000000000000000000000000000000000000000"
ETH_MAX_AGE = 86_400
USDG_MAX_AGE = 86_400

STOCK_MAX_AGE = 345_600
STOCK_QUOTE_TYPE = 2  # QuoteType.Stock
STOCK_FEED_DECIMALS = 8

# Safety floor for authority ETH before any write.
# Intentionally conservative — do not lower merely to enable broadcast.
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


@dataclass(frozen=True)
class ScoopTargets:
    """Runtime QR/PO from SCOOP_QUOTE_REGISTRY / SCOOP_PRICE_ORACLE."""

    quote_registry: str
    price_oracle: str


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
    quoteRegistry: Optional[str] = None
    priceOracle: Optional[str] = None
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


def load_scoop_targets_from_env() -> ScoopTargets:
    qr = os.environ.get("SCOOP_QUOTE_REGISTRY", "").strip()
    po = os.environ.get("SCOOP_PRICE_ORACLE", "").strip()
    if not qr:
        raise Abort("SCOOP_QUOTE_REGISTRY required")
    if not po:
        raise Abort("SCOOP_PRICE_ORACLE required")
    return ScoopTargets(quote_registry=_norm(qr), price_oracle=_norm(po))


def load_manifest(path: Path) -> list[dict[str, Any]]:
    raw = json.loads(path.read_text())
    if not isinstance(raw, list):
        raise Abort("manifest must be a JSON array")
    if len(raw) != 20:
        raise Abort(f"manifest count must be 20, got {len(raw)}")
    symbols = []
    for i, entry in enumerate(raw):
        for key in ("symbol", "token", "feed", "feedDecimals", "maxAge", "quoteType"):
            if key not in entry:
                raise Abort(f"manifest[{i}] missing {key}")
        if entry["maxAge"] != STOCK_MAX_AGE:
            raise Abort(f"{entry['symbol']}: maxAge must be {STOCK_MAX_AGE}")
        if entry["quoteType"] != STOCK_QUOTE_TYPE:
            raise Abort(f"{entry['symbol']}: quoteType must be {STOCK_QUOTE_TYPE}")
        if entry["feedDecimals"] != STOCK_FEED_DECIMALS:
            raise Abort(f"{entry['symbol']}: feedDecimals must be {STOCK_FEED_DECIMALS}")
        # Deployment targets must not control production routing.
        if "tx1" in entry or "tx2" in entry:
            raise Abort(
                f"{entry['symbol']}: manifest must not include tx1/tx2 deployment targets; "
                "transactions are constructed from SCOOP_QUOTE_REGISTRY / SCOOP_PRICE_ORACLE"
            )
        _norm(entry["token"])
        _norm(entry["feed"])
        symbols.append(entry["symbol"])
    if len(set(symbols)) != 20:
        raise Abort("manifest symbols must be unique")
    return raw


def select_symbols(manifest: list[dict[str, Any]], symbols_csv: Optional[str]) -> list[dict[str, Any]]:
    """Return catalogue entries for selected symbols in canonical catalogue order."""
    if symbols_csv is None or symbols_csv.strip() == "":
        raise Abort("symbol selection required (empty)")
    raw_parts = [p.strip() for p in symbols_csv.split(",") if p.strip() != ""]
    if not raw_parts:
        raise Abort("symbol selection required (empty)")
    seen: set[str] = set()
    ordered_unique: list[str] = []
    for sym in raw_parts:
        if sym in seen:
            raise Abort(f"duplicate symbol in selection: {sym}")
        seen.add(sym)
        ordered_unique.append(sym)

    by_symbol = {e["symbol"]: e for e in manifest}
    for sym in ordered_unique:
        if sym not in by_symbol:
            raise Abort(f"unknown symbol (not in frozen 20-stock catalogue): {sym}")

    # Preserve catalogue order, not CLI order.
    selected = [e for e in manifest if e["symbol"] in seen]
    return selected


def build_configure_feed_calldata(token: str, feed: str, max_age: int = STOCK_MAX_AGE) -> str:
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


# ── RPC via cast ─────────────────────────────────────────────────────────────


class CastRpc:
    def __init__(self, rpc_url: str):
        if not rpc_url.startswith(("http://", "https://")):
            raise Abort("ROBINHOOD_RPC_URL must be http(s)")
        self.rpc_url = rpc_url

    def _run(self, args: list[str], *, sensitive: bool = False) -> str:
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

    def codesize(self, address: str) -> int:
        out = self._run(["cast", "codesize", address, "--rpc-url", self.rpc_url])
        return int(out.split()[0], 0)

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
            tx_hash = raw.splitlines()[-1].strip()
            if not tx_hash.startswith("0x"):
                raise Abort("cast send did not return JSON receipt or tx hash")
            receipt = self.wait_receipt(tx_hash)
            return receipt
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
    token = line.split()[0]
    return int(token, 0)


def parse_address(out: str) -> str:
    line = out.splitlines()[0].strip().split()[0]
    if not line.startswith("0x"):
        raise Abort(f"expected address, got {out!r}")
    return line


def parse_feed_config(out: str) -> FeedConfig:
    text = out.strip()
    if text.startswith("(") and text.endswith(")"):
        text = text[1:-1]
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


def read_oracle_configured(rpc: CastRpc, targets: ScoopTargets, asset: str) -> bool:
    return parse_bool(rpc.call(targets.price_oracle, "isConfigured(address)(bool)", asset))


def read_oracle_enabled(rpc: CastRpc, targets: ScoopTargets, asset: str) -> bool:
    return parse_bool(rpc.call(targets.price_oracle, "isEnabled(address)(bool)", asset))


def read_feed_config(rpc: CastRpc, targets: ScoopTargets, asset: str) -> FeedConfig:
    out = rpc.call(
        targets.price_oracle, "getFeedConfig(address)((address,uint48,uint8,bool))", asset
    )
    return parse_feed_config(out)


def read_price_usd(rpc: CastRpc, targets: ScoopTargets, asset: str) -> int:
    return parse_uint(rpc.call(targets.price_oracle, "getPriceUsd(address)(uint256)", asset))


def read_registered(rpc: CastRpc, targets: ScoopTargets, asset: str) -> bool:
    return parse_bool(rpc.call(targets.quote_registry, "isRegistered(address)(bool)", asset))


def read_quote_enabled(rpc: CastRpc, targets: ScoopTargets, asset: str) -> bool:
    return parse_bool(rpc.call(targets.quote_registry, "isEnabled(address)(bool)", asset))


def read_quote_type(rpc: CastRpc, targets: ScoopTargets, asset: str) -> int:
    return parse_uint(rpc.call(targets.quote_registry, "quoteType(address)(uint8)", asset))


def read_quote_count(rpc: CastRpc, targets: ScoopTargets) -> int:
    return parse_uint(rpc.call(targets.quote_registry, "registeredQuoteCount()(uint256)"))


def read_registered_quote_at(rpc: CastRpc, targets: ScoopTargets, index: int) -> str:
    return parse_address(
        rpc.call(targets.quote_registry, "registeredQuoteAt(uint256)(address)", str(index))
    )


def enumerate_registered_quotes(rpc: CastRpc, targets: ScoopTargets) -> list[str]:
    count = read_quote_count(rpc, targets)
    return [read_registered_quote_at(rpc, targets, i) for i in range(count)]


def allowed_quote_assets(manifest: list[dict[str, Any]]) -> set[str]:
    allowed = {_norm(ETH), _norm(USDG)}
    for e in manifest:
        allowed.add(_norm(e["token"]))
    return allowed


def assert_registered_set_canonical(rpc: CastRpc, targets: ScoopTargets, manifest: list[dict[str, Any]]) -> None:
    """Every registered asset must be ETH, USDG, or a catalogue stock token."""
    allowed = allowed_quote_assets(manifest)
    registered = enumerate_registered_quotes(rpc, targets)
    unexpected = [a for a in registered if _norm(a) not in allowed]
    if unexpected:
        raise Abort(f"unexpected registered quote asset(s): {unexpected}")
    # Count must match enumeration length (sanity).
    if len(registered) != read_quote_count(rpc, targets):
        raise Abort("registeredQuoteCount does not match enumeration")


def expected_quote_count_from_states(states: list[StockLiveState]) -> int:
    """Canonical intended count = ETH + USDG + COMPLETE stocks."""
    complete_n = sum(1 for s in states if s.classification == StockState.COMPLETE)
    return 2 + complete_n


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
    if rpc.codesize(feed) == 0:
        raise Abort(f"feed {feed}: no bytecode")
    dec = parse_uint(rpc.call(feed, "decimals()(uint8)"))
    if dec != STOCK_FEED_DECIMALS:
        raise Abort(f"feed {feed}: decimals must be {STOCK_FEED_DECIMALS}, got {dec}")
    out = rpc.call(
        feed,
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)",
    )
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    vals = []
    for ln in lines:
        token = ln.split()[0]
        try:
            vals.append(int(token, 0))
        except ValueError:
            continue
    if len(vals) < 5:
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


def assert_eth_healthy(rpc: CastRpc, targets: ScoopTargets) -> None:
    zero = ETH
    if not read_registered(rpc, targets, zero):
        raise Abort("ETH: not registered")
    if not read_quote_enabled(rpc, targets, zero):
        raise Abort("ETH: not enabled")
    if read_quote_type(rpc, targets, zero) != 0:
        raise Abort("ETH: quoteType must be Native (0)")
    if not read_oracle_configured(rpc, targets, zero):
        raise Abort("ETH: oracle not configured")
    if not read_oracle_enabled(rpc, targets, zero):
        raise Abort("ETH: oracle not enabled")
    cfg = read_feed_config(rpc, targets, zero)
    if not _checksum_eq(cfg.feed, ETH_USD_FEED):
        raise Abort("ETH: feed mismatch")
    if cfg.max_age != ETH_MAX_AGE:
        raise Abort(f"ETH: maxAge mismatch ({cfg.max_age})")
    if not cfg.enabled:
        raise Abort("ETH: feed disabled")
    if read_price_usd(rpc, targets, zero) <= 0:
        raise Abort("ETH: getPriceUsd <= 0")


def assert_usdg_healthy(rpc: CastRpc, targets: ScoopTargets) -> None:
    if not read_registered(rpc, targets, USDG):
        raise Abort("USDG: not registered")
    if not read_quote_enabled(rpc, targets, USDG):
        raise Abort("USDG: not enabled")
    if read_quote_type(rpc, targets, USDG) != 1:
        raise Abort("USDG: quoteType must be Scoop (1)")
    if not read_oracle_configured(rpc, targets, USDG):
        raise Abort("USDG: oracle not configured")
    if not read_oracle_enabled(rpc, targets, USDG):
        raise Abort("USDG: oracle not enabled")
    cfg = read_feed_config(rpc, targets, USDG)
    if not _checksum_eq(cfg.feed, USDG_USD_FEED):
        raise Abort("USDG: feed mismatch")
    if cfg.max_age != USDG_MAX_AGE:
        raise Abort(f"USDG: maxAge mismatch ({cfg.max_age})")
    if cfg.feed_decimals != 8:
        raise Abort("USDG: feedDecimals must be 8")
    if not cfg.enabled:
        raise Abort("USDG: feed disabled")
    if read_price_usd(rpc, targets, USDG) <= 0:
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


def classify_stock(rpc: CastRpc, targets: ScoopTargets, entry: dict[str, Any]) -> StockLiveState:
    token = entry["token"]
    configured = read_oracle_configured(rpc, targets, token)
    registered = read_registered(rpc, targets, token)

    feed_config = None
    price = None
    oracle_enabled = False
    quote_enabled = False
    quote_type = None

    if configured:
        oracle_enabled = read_oracle_enabled(rpc, targets, token)
        feed_config = read_feed_config(rpc, targets, token)
        try:
            price = read_price_usd(rpc, targets, token)
        except Abort:
            price = None

    if registered:
        quote_enabled = read_quote_enabled(rpc, targets, token)
        quote_type = read_quote_type(rpc, targets, token)

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


def verify_oracle_after_tx1(rpc: CastRpc, targets: ScoopTargets, entry: dict[str, Any]) -> None:
    token = entry["token"]
    if not read_oracle_configured(rpc, targets, token):
        raise Abort(f"{entry['symbol']}: after TX1 isConfigured=false")
    if not read_oracle_enabled(rpc, targets, token):
        raise Abort(f"{entry['symbol']}: after TX1 isEnabled=false")
    cfg = read_feed_config(rpc, targets, token)
    if not _checksum_eq(cfg.feed, entry["feed"]):
        raise Abort(f"{entry['symbol']}: after TX1 feed mismatch")
    if cfg.max_age != STOCK_MAX_AGE:
        raise Abort(f"{entry['symbol']}: after TX1 maxAge mismatch")
    if cfg.feed_decimals != STOCK_FEED_DECIMALS:
        raise Abort(f"{entry['symbol']}: after TX1 feedDecimals mismatch")
    if not cfg.enabled:
        raise Abort(f"{entry['symbol']}: after TX1 feed disabled")
    if read_price_usd(rpc, targets, token) <= 0:
        raise Abort(f"{entry['symbol']}: after TX1 getPriceUsd <= 0")
    if read_registered(rpc, targets, token):
        raise Abort(f"{entry['symbol']}: after TX1 unexpectedly registered")


def verify_after_tx2(rpc: CastRpc, targets: ScoopTargets, entry: dict[str, Any]) -> None:
    token = entry["token"]
    if not read_registered(rpc, targets, token):
        raise Abort(f"{entry['symbol']}: after TX2 not registered")
    if not read_quote_enabled(rpc, targets, token):
        raise Abort(f"{entry['symbol']}: after TX2 not enabled")
    if read_quote_type(rpc, targets, token) != STOCK_QUOTE_TYPE:
        raise Abort(f"{entry['symbol']}: after TX2 quoteType != Stock")
    if not read_oracle_configured(rpc, targets, token) or not read_oracle_enabled(rpc, targets, token):
        raise Abort(f"{entry['symbol']}: after TX2 oracle not configured/enabled")
    cfg = read_feed_config(rpc, targets, token)
    if not oracle_matches_manifest(cfg, entry, read_price_usd(rpc, targets, token)):
        raise Abort(f"{entry['symbol']}: after TX2 oracle readback mismatch")


def receipt_ok(receipt: dict[str, Any], *, expected_to: str, expected_from: str) -> tuple[str, int, int]:
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
    to = receipt.get("to") or receipt.get("To")
    frm = receipt.get("from") or receipt.get("From")
    if to is not None and not _checksum_eq(str(to), expected_to):
        raise Abort(f"receipt to mismatch: got {to}, expected {expected_to}")
    if frm is not None and not _checksum_eq(str(frm), expected_from):
        raise Abort(f"receipt from mismatch: got {frm}, expected {expected_from}")
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
        quoteRegistry=data.get("quoteRegistry"),
        priceOracle=data.get("priceOracle"),
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
    blob = json.dumps(payload)
    if "AUTHORITY_PRIVATE_KEY" in blob:
        raise Abort("refusing to write log that appears to contain secrets")
    lowered = blob.lower()
    if "private_key" in lowered or "privatekey" in lowered:
        raise Abort("refusing to write log that appears to contain secrets")
    atomic_write_json(path, payload)


# ── Global preflight ─────────────────────────────────────────────────────────


def validate_targets(rpc: CastRpc, targets: ScoopTargets) -> None:
    if _norm(targets.quote_registry) == "0x0000000000000000000000000000000000000000":
        raise Abort("SCOOP_QUOTE_REGISTRY is zero")
    if _norm(targets.price_oracle) == "0x0000000000000000000000000000000000000000":
        raise Abort("SCOOP_PRICE_ORACLE is zero")
    if rpc.codesize(targets.quote_registry) == 0:
        raise Abort(f"QuoteRegistry has no bytecode: {targets.quote_registry}")
    if rpc.codesize(targets.price_oracle) == 0:
        raise Abort(f"PriceOracle has no bytecode: {targets.price_oracle}")
    reg_auth = parse_address(rpc.call(targets.quote_registry, "registryAuthority()(address)"))
    ora_auth = parse_address(rpc.call(targets.price_oracle, "oracleAuthority()(address)"))
    if not _checksum_eq(reg_auth, AUTHORITY):
        raise Abort("registryAuthority mismatch")
    if not _checksum_eq(ora_auth, AUTHORITY):
        raise Abort("oracleAuthority mismatch")


def global_preflight(
    rpc: CastRpc,
    targets: ScoopTargets,
    full_manifest: list[dict[str, Any]],
    signer: str,
    *,
    require_balance: bool,
) -> None:
    if rpc.chain_id() != CHAIN_ID:
        raise Abort(f"wrong chainId: expected {CHAIN_ID}")
    validate_targets(rpc, targets)
    if not _checksum_eq(signer, AUTHORITY):
        raise Abort("signer is not production authority — abort before any transaction")

    assert_eth_healthy(rpc, targets)
    assert_usdg_healthy(rpc, targets)
    assert_registered_set_canonical(rpc, targets, full_manifest)

    # Count must equal ETH+USDG+COMPLETE stocks derived from live classification.
    full_states = [classify_stock(rpc, targets, e) for e in full_manifest]
    for st in full_states:
        if st.classification == StockState.INVALID:
            raise Abort(f"{st.symbol}: invalid live state — {st.note}")
    expected = expected_quote_count_from_states(full_states)
    actual = read_quote_count(rpc, targets)
    if actual != expected:
        raise Abort(
            f"registeredQuoteCount mismatch: got {actual}, expected {expected} "
            f"(ETH+USDG+{expected - 2} COMPLETE stocks)"
        )

    if require_balance:
        bal = rpc.balance_wei(AUTHORITY)
        if bal < MIN_AUTHORITY_ETH_WEI:
            raise Abort(
                f"authority ETH balance {bal} wei < safety floor {MIN_AUTHORITY_ETH_WEI} wei "
                f"({MIN_AUTHORITY_ETH_WEI / 10**18} ETH)"
            )


def final_verification(
    rpc: CastRpc,
    targets: ScoopTargets,
    full_manifest: list[dict[str, Any]],
    selected: list[dict[str, Any]],
) -> None:
    assert_eth_healthy(rpc, targets)
    assert_usdg_healthy(rpc, targets)
    assert_registered_set_canonical(rpc, targets, full_manifest)

    for entry in selected:
        st = classify_stock(rpc, targets, entry)
        if st.classification != StockState.COMPLETE:
            raise Abort(f"final verification failed for {entry['symbol']}: {st.classification} {st.note}")

    full_states = [classify_stock(rpc, targets, e) for e in full_manifest]
    expected = expected_quote_count_from_states(full_states)
    actual = read_quote_count(rpc, targets)
    if actual != expected:
        raise Abort(f"final registeredQuoteCount expected {expected}, got {actual}")


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


def print_dry_run(
    signer: str,
    targets: ScoopTargets,
    plan: dict[str, Any],
    *,
    mode: str,
    selected_symbols: list[str],
) -> None:
    print("SCOOP STOCK MAINNET RUNNER")
    print(f"chainId: {CHAIN_ID}")
    print(f"authority: {signer}")
    print(f"quoteRegistry: {targets.quote_registry}")
    print(f"priceOracle: {targets.price_oracle}")
    print(f"selected: {', '.join(selected_symbols)}")
    print("already complete (in selection):")
    for sym in plan["complete"]:
        print(f"  {sym}")
    if not plan["complete"]:
        print("  (none)")
    print()
    print("remaining (in selection):")
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


def print_final_table(selected: list[dict[str, Any]], expected_count: int) -> None:
    for entry in selected:
        print(f"{entry['symbol']:<6} COMPLETE")
    print()
    print(f"{len(selected)}/{len(selected)} SELECTED STOCKS COMPLETE")
    print(f"REGISTERED_QUOTE_COUNT={expected_count}")


# ── Per-stock processing ─────────────────────────────────────────────────────


def process_stock(
    rpc: CastRpc,
    targets: ScoopTargets,
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
        return

    assert_feed_fresh(rpc, entry["feed"])

    log_entry = StockLogEntry(
        symbol=symbol,
        token=entry["token"],
        feed=entry["feed"],
        initialState=state.classification.value,
    )

    if private_key is None:
        raise Abort("broadcast requested but AUTHORITY_PRIVATE_KEY missing")

    if state.needs_tx1:
        print(f">>> {symbol}: sending TX1 configureFeed ...")
        calldata = build_configure_feed_calldata(entry["token"], entry["feed"], entry["maxAge"])
        try:
            receipt = rpc.send_calldata(
                to=targets.price_oracle,
                calldata=calldata,
                private_key=private_key,
                from_addr=AUTHORITY,
            )
            txh, block, gas = receipt_ok(
                receipt, expected_to=targets.price_oracle, expected_from=AUTHORITY
            )
        except Abort as e:
            log_entry.error = str(e)
            upsert_stock_log(log, log_entry)
            save_log(log_path, log)
            raise

        log_entry.tx1Hash = txh
        log_entry.tx1Block = block
        log_entry.tx1GasUsed = gas
        try:
            verify_oracle_after_tx1(rpc, targets, entry)
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

    assert_feed_fresh(rpc, entry["feed"])

    if state.needs_tx2:
        print(f">>> {symbol}: sending TX2 registerQuote ...")
        calldata = build_register_quote_calldata(entry["token"], entry["quoteType"])
        try:
            receipt = rpc.send_calldata(
                to=targets.quote_registry,
                calldata=calldata,
                private_key=private_key,
                from_addr=AUTHORITY,
            )
            txh, block, gas = receipt_ok(
                receipt, expected_to=targets.quote_registry, expected_from=AUTHORITY
            )
        except Abort as e:
            log_entry.error = str(e)
            upsert_stock_log(log, log_entry)
            save_log(log_path, log)
            raise

        log_entry.tx2Hash = txh
        log_entry.tx2Block = block
        log_entry.tx2GasUsed = gas
        try:
            verify_after_tx2(rpc, targets, entry)
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
    symbols_csv: Optional[str] = None,
    confirm_fn: Optional[Callable[[str], str]] = None,
) -> int:
    rpc_url = os.environ.get("ROBINHOOD_RPC_URL", "").strip()
    private_key = os.environ.get("AUTHORITY_PRIVATE_KEY", "").strip()
    if not rpc_url:
        raise Abort("ROBINHOOD_RPC_URL required")
    if not private_key:
        raise Abort("AUTHORITY_PRIVATE_KEY required (used to verify signer; never printed)")

    if not private_key.startswith("0x"):
        private_key = "0x" + private_key

    os.chdir(REPO_ROOT)
    full_manifest = load_manifest(manifest_path)
    targets = load_scoop_targets_from_env()

    if broadcast and (symbols_csv is None or symbols_csv.strip() == ""):
        raise Abort("broadcast requires explicit --symbols selection (refusing full-catalogue broadcast)")

    # Dry-run without --symbols inspects the full catalogue.
    if symbols_csv is None or symbols_csv.strip() == "":
        selected = list(full_manifest)
    else:
        selected = select_symbols(full_manifest, symbols_csv)

    rpc = CastRpc(rpc_url)
    signer = derive_signer_address(private_key)

    global_preflight(rpc, targets, full_manifest, signer, require_balance=broadcast)

    states = [classify_stock(rpc, targets, entry) for entry in selected]
    for st in states:
        if st.classification == StockState.INVALID:
            raise Abort(f"{st.symbol}: invalid live state — {st.note}")

    plan = plan_from_states(states)
    mode = "BROADCAST" if broadcast else "DRY_RUN"
    selected_symbols = [e["symbol"] for e in selected]
    print_dry_run(signer, targets, plan, mode=mode, selected_symbols=selected_symbols)

    remaining_n = len(plan["remaining"])
    writes = plan["writes"]

    if remaining_n == 0:
        print()
        print("Nothing remaining in selection — running final verification...")
        final_verification(rpc, targets, full_manifest, selected)
        full_states = [classify_stock(rpc, targets, e) for e in full_manifest]
        print_final_table(selected, expected_quote_count_from_states(full_states))
        return 0

    if not broadcast:
        print()
        print(
            f"Dry-run complete. Remaining in selection: {remaining_n}. "
            f"Expected writes if broadcast: {writes}."
        )
        return 0

    log = load_log(log_path)
    if not log.startedAt:
        log.startedAt = utc_now()
    log.mode = mode
    log.authority = AUTHORITY
    log.chainId = CHAIN_ID
    log.quoteRegistry = targets.quote_registry
    log.priceOracle = targets.price_oracle
    save_log(log_path, log)

    print()
    print("Selected symbols for broadcast:")
    for sym in selected_symbols:
        print(f"  {sym}")
    expected = f"BROADCAST {remaining_n} STOCKS"
    prompt = f"Type {expected} to continue: "
    fn = confirm_fn or input
    typed = fn(prompt)
    if typed.strip() != expected:
        raise Abort("confirmation mismatch — aborting without transactions")

    state_by_symbol = {s.symbol: s for s in states}

    for entry in selected:
        st = state_by_symbol[entry["symbol"]]
        if st.classification == StockState.COMPLETE:
            continue
        live = classify_stock(rpc, targets, entry)
        if live.classification == StockState.INVALID:
            raise Abort(f"{entry['symbol']}: invalid before write — {live.note}")
        if live.classification == StockState.COMPLETE:
            continue
        process_stock(
            rpc,
            targets,
            entry,
            live,
            broadcast=True,
            private_key=private_key,
            log=log,
            log_path=log_path,
        )

    print()
    print("Selected remaining stocks processed — final verification...")
    final_verification(rpc, targets, full_manifest, selected)
    full_states = [classify_stock(rpc, targets, e) for e in full_manifest]
    print_final_table(selected, expected_quote_count_from_states(full_states))
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="SCOOP stock catalogue production runner (canonical)")
    parser.add_argument(
        "--broadcast",
        action="store_true",
        help="Enable live writes (default is dry-run / preflight only)",
    )
    parser.add_argument(
        "--symbols",
        type=str,
        default=None,
        help="Comma-separated symbols from the frozen catalogue (required for --broadcast)",
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
        return run(
            broadcast=args.broadcast,
            manifest_path=args.manifest,
            log_path=args.log,
            symbols_csv=args.symbols,
        )
    except Abort as e:
        print(f"ABORT: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
