#!/usr/bin/env python3
"""Unit tests for stock mainnet runner (no live chain writes)."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Optional
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "script"))

import configure_remaining_stock_catalogue as runner  # noqa: E402


MANIFEST_PATH = REPO_ROOT / "audit" / "final-production-stock-manifest-20.json"


def _sample_entry(symbol: str = "NVDA") -> dict[str, Any]:
    manifest = runner.load_manifest(MANIFEST_PATH)
    for e in manifest:
        if e["symbol"] == symbol:
            return dict(e)
    raise AssertionError(f"missing {symbol}")


def _good_cfg(entry: dict[str, Any]) -> runner.FeedConfig:
    return runner.FeedConfig(
        feed=entry["feed"],
        max_age=runner.STOCK_MAX_AGE,
        feed_decimals=8,
        enabled=True,
    )


class ManifestTests(unittest.TestCase):
    def test_01_manifest_validation(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        self.assertEqual(len(m), 20)
        self.assertEqual(m[0]["symbol"], "AAPL")
        self.assertEqual(m[1]["symbol"], "AMD")
        for e in m:
            self.assertEqual(e["maxAge"], 345600)
            self.assertEqual(e["quoteType"], 2)

    def test_01b_manifest_wrong_count_aborts(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.json"
            p.write_text(json.dumps([_sample_entry()]))
            with self.assertRaises(runner.Abort):
                runner.load_manifest(p)


class ClassificationTests(unittest.TestCase):
    def test_02_aapl_amd_complete(self) -> None:
        for sym in ("AAPL", "AMD"):
            entry = _sample_entry(sym)
            st = runner.classify_from_reads(
                entry,
                configured=True,
                registered=True,
                oracle_enabled=True,
                feed_config=_good_cfg(entry),
                price=100 * 10**8,
                quote_enabled=True,
                quote_type=2,
            )
            self.assertEqual(st.classification, runner.StockState.COMPLETE)
            self.assertFalse(st.needs_tx1)
            self.assertFalse(st.needs_tx2)

    def test_03_untouched(self) -> None:
        entry = _sample_entry("NVDA")
        st = runner.classify_from_reads(entry, configured=False, registered=False)
        self.assertEqual(st.classification, runner.StockState.UNTOUCHED)
        self.assertTrue(st.needs_tx1)
        self.assertTrue(st.needs_tx2)

    def test_04_oracle_only_resumes_tx2(self) -> None:
        entry = _sample_entry("TSLA")
        st = runner.classify_from_reads(
            entry,
            configured=True,
            registered=False,
            oracle_enabled=True,
            feed_config=_good_cfg(entry),
            price=200 * 10**8,
        )
        self.assertEqual(st.classification, runner.StockState.ORACLE_ONLY)
        self.assertFalse(st.needs_tx1)
        self.assertTrue(st.needs_tx2)

    def test_05_complete_skips_writes(self) -> None:
        entry = _sample_entry("MSFT")
        st = runner.classify_from_reads(
            entry,
            configured=True,
            registered=True,
            oracle_enabled=True,
            feed_config=_good_cfg(entry),
            price=1,
            quote_enabled=True,
            quote_type=2,
        )
        plan = runner.plan_from_states([st])
        self.assertEqual(plan["writes"], 0)
        self.assertEqual(plan["complete"], ["MSFT"])

    def test_06_registered_without_oracle_invalid(self) -> None:
        entry = _sample_entry("NVDA")
        st = runner.classify_from_reads(entry, configured=False, registered=True, quote_enabled=True, quote_type=2)
        self.assertEqual(st.classification, runner.StockState.INVALID)

    def test_07_mismatched_feed_invalid(self) -> None:
        entry = _sample_entry("NVDA")
        bad = _good_cfg(entry)
        bad.feed = "0x0000000000000000000000000000000000000001"
        st = runner.classify_from_reads(
            entry,
            configured=True,
            registered=False,
            oracle_enabled=True,
            feed_config=bad,
            price=1,
        )
        self.assertEqual(st.classification, runner.StockState.INVALID)

    def test_08_wrong_max_age_invalid(self) -> None:
        entry = _sample_entry("NVDA")
        bad = _good_cfg(entry)
        bad.max_age = 86_400
        st = runner.classify_from_reads(
            entry,
            configured=True,
            registered=True,
            oracle_enabled=True,
            feed_config=bad,
            price=1,
            quote_enabled=True,
            quote_type=2,
        )
        self.assertEqual(st.classification, runner.StockState.INVALID)

    def test_09_wrong_quote_type_invalid(self) -> None:
        entry = _sample_entry("NVDA")
        st = runner.classify_from_reads(
            entry,
            configured=True,
            registered=True,
            oracle_enabled=True,
            feed_config=_good_cfg(entry),
            price=1,
            quote_enabled=True,
            quote_type=1,
        )
        self.assertEqual(st.classification, runner.StockState.INVALID)


class GuardTests(unittest.TestCase):
    def test_10_stale_feed_aborts(self) -> None:
        now = 2_000_000
        with self.assertRaises(runner.Abort) as ctx:
            runner.check_feed_round(
                round_id=1,
                answer=100,
                updated_at=now - runner.STOCK_MAX_AGE - 1,
                answered_in_round=1,
                now_ts=now,
            )
        self.assertIn("stale", str(ctx.exception))

    def test_11_wrong_chain_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = 1
        with self.assertRaises(runner.Abort) as ctx:
            runner.global_preflight(rpc, runner.load_manifest(MANIFEST_PATH), runner.AUTHORITY, require_balance=False)
        self.assertIn("chainId", str(ctx.exception))

    def test_12_wrong_authority_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        # registryAuthority / oracleAuthority returned via call — short-circuit by making call raise after chain id
        # Use real flow: monkeypatch parse helpers by patching rpc.call sequence
        with mock.patch.object(runner, "parse_address", side_effect=["0x1111111111111111111111111111111111111111", runner.AUTHORITY]):
            with self.assertRaises(runner.Abort) as ctx:
                runner.global_preflight(
                    rpc, runner.load_manifest(MANIFEST_PATH), runner.AUTHORITY, require_balance=False
                )
        self.assertIn("registryAuthority", str(ctx.exception))

    def test_12b_signer_mismatch_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        with mock.patch.object(runner, "parse_address", return_value=runner.AUTHORITY):
            with self.assertRaises(runner.Abort) as ctx:
                runner.global_preflight(
                    rpc,
                    runner.load_manifest(MANIFEST_PATH),
                    "0x1111111111111111111111111111111111111111",
                    require_balance=False,
                )
        self.assertIn("signer", str(ctx.exception).lower())

    def test_13_insufficient_eth_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        rpc.balance_wei.return_value = 0
        manifest = runner.load_manifest(MANIFEST_PATH)

        with mock.patch.object(runner, "parse_address", return_value=runner.AUTHORITY), mock.patch.object(
            runner, "assert_calldata_matches_manifest"
        ), mock.patch.object(runner, "assert_eth_healthy"), mock.patch.object(
            runner, "assert_usdg_healthy"
        ), mock.patch.object(
            runner,
            "classify_stock",
            return_value=runner.StockLiveState(
                symbol="AAPL",
                token=manifest[0]["token"],
                oracle_configured=True,
                oracle_enabled=True,
                feed_config=_good_cfg(manifest[0]),
                price_usd=1,
                registered=True,
                quote_enabled=True,
                quote_type=2,
                classification=runner.StockState.COMPLETE,
                needs_tx1=False,
                needs_tx2=False,
            ),
        ), mock.patch.object(runner, "read_quote_count", return_value=4):
            with self.assertRaises(runner.Abort) as ctx:
                runner.global_preflight(rpc, manifest, runner.AUTHORITY, require_balance=True)
        self.assertIn("ETH balance", str(ctx.exception))

    def test_14_calldata_mismatch_aborts(self) -> None:
        entry = _sample_entry("NVDA")
        entry = dict(entry)
        entry["tx1"] = dict(entry["tx1"])
        entry["tx1"]["calldata"] = "0xdead"
        with self.assertRaises(runner.Abort) as ctx:
            runner.assert_calldata_matches_manifest(entry)
        self.assertIn("TX1 calldata mismatch", str(ctx.exception))


class ProcessStockTests(unittest.TestCase):
    def _fresh(self) -> None:
        # patch freshness + calldata so process_stock focuses on send/verify
        self._p1 = mock.patch.object(runner, "assert_feed_fresh")
        self._p2 = mock.patch.object(runner, "assert_calldata_matches_manifest")
        self._p1.start()
        self._p2.start()
        self.addCleanup(self._p1.stop)
        self.addCleanup(self._p2.stop)

    def test_15_tx1_failure_stops(self) -> None:
        self._fresh()
        entry = _sample_entry("NVDA")
        state = runner.classify_from_reads(entry, configured=False, registered=False)
        rpc = mock.Mock()
        rpc.send_calldata.side_effect = runner.Abort("tx1 send failed")
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with self.assertRaises(runner.Abort):
                runner.process_stock(
                    rpc, entry, state, broadcast=True, private_key="0x" + "11" * 32, log=log, log_path=path
                )
            self.assertEqual(rpc.send_calldata.call_count, 1)
            saved = json.loads(path.read_text())
            self.assertTrue(any(s.get("error") for s in saved["stocks"]))

    def test_16_tx1_success_bad_readback_no_tx2(self) -> None:
        self._fresh()
        entry = _sample_entry("NVDA")
        state = runner.classify_from_reads(entry, configured=False, registered=False)
        rpc = mock.Mock()
        rpc.send_calldata.return_value = {
            "status": "0x1",
            "transactionHash": "0x" + "ab" * 32,
            "blockNumber": "0x10",
            "gasUsed": "0x5208",
        }
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with mock.patch.object(runner, "verify_oracle_after_tx1", side_effect=runner.Abort("bad readback")):
                with self.assertRaises(runner.Abort) as ctx:
                    runner.process_stock(
                        rpc, entry, state, broadcast=True, private_key="0x" + "11" * 32, log=log, log_path=path
                    )
            self.assertIn("NOT sending TX2", str(ctx.exception))
            self.assertEqual(rpc.send_calldata.call_count, 1)

    def test_17_tx2_failure_stops(self) -> None:
        self._fresh()
        entry = _sample_entry("NVDA")
        state = runner.classify_from_reads(
            entry,
            configured=True,
            registered=False,
            oracle_enabled=True,
            feed_config=_good_cfg(entry),
            price=1,
        )
        rpc = mock.Mock()
        rpc.send_calldata.side_effect = runner.Abort("tx2 send failed")
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with self.assertRaises(runner.Abort):
                runner.process_stock(
                    rpc, entry, state, broadcast=True, private_key="0x" + "11" * 32, log=log, log_path=path
                )
            # Only TX2 attempted for oracle-only
            self.assertEqual(rpc.send_calldata.call_count, 1)
            self.assertEqual(rpc.send_calldata.call_args.kwargs["to"], runner.QUOTE_REGISTRY)


class DryRunAndFinalTests(unittest.TestCase):
    def test_18_dry_run_zero_writes(self) -> None:
        entry = _sample_entry("NVDA")
        states = [
            runner.classify_from_reads(
                _sample_entry("AAPL"),
                configured=True,
                registered=True,
                oracle_enabled=True,
                feed_config=_good_cfg(_sample_entry("AAPL")),
                price=1,
                quote_enabled=True,
                quote_type=2,
            ),
            runner.classify_from_reads(
                _sample_entry("AMD"),
                configured=True,
                registered=True,
                oracle_enabled=True,
                feed_config=_good_cfg(_sample_entry("AMD")),
                price=1,
                quote_enabled=True,
                quote_type=2,
            ),
            runner.classify_from_reads(entry, configured=False, registered=False),
        ]
        # Pad remaining symbols as untouched for plan sizing only
        plan = runner.plan_from_states(states)
        self.assertGreater(plan["writes"], 0)

        rpc = mock.Mock()
        rpc.send_calldata = mock.Mock(side_effect=AssertionError("must not send"))
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            # process_stock dry path should not call send
            runner.process_stock(
                rpc,
                entry,
                states[2],
                broadcast=False,
                private_key=None,
                log=log,
                log_path=path,
            )
            rpc.send_calldata.assert_not_called()

        # run() dry-run must not mutate execution log
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "exec.json"
            env = {
                "ROBINHOOD_RPC_URL": "https://example.invalid",
                "AUTHORITY_PRIVATE_KEY": "0x" + "22" * 32,
            }
            with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(
                runner, "derive_signer_address", return_value=runner.AUTHORITY
            ), mock.patch.object(runner, "CastRpc") as rpc_cls, mock.patch.object(
                runner, "global_preflight"
            ), mock.patch.object(
                runner,
                "classify_stock",
                side_effect=lambda rpc, e: runner.classify_from_reads(
                    e,
                    configured=e["symbol"] in ("AAPL", "AMD"),
                    registered=e["symbol"] in ("AAPL", "AMD"),
                    oracle_enabled=e["symbol"] in ("AAPL", "AMD"),
                    feed_config=_good_cfg(e) if e["symbol"] in ("AAPL", "AMD") else None,
                    price=1 if e["symbol"] in ("AAPL", "AMD") else None,
                    quote_enabled=e["symbol"] in ("AAPL", "AMD"),
                    quote_type=2 if e["symbol"] in ("AAPL", "AMD") else None,
                ),
            ):
                rpc_cls.return_value = mock.Mock()
                code = runner.run(broadcast=False, manifest_path=MANIFEST_PATH, log_path=log_path)
            self.assertEqual(code, 0)
            self.assertFalse(log_path.exists())

    def test_19_final_verification_requires_22(self) -> None:
        rpc = mock.Mock()
        manifest = runner.load_manifest(MANIFEST_PATH)

        def classify(_rpc: Any, entry: dict[str, Any]) -> runner.StockLiveState:
            return runner.classify_from_reads(
                entry,
                configured=True,
                registered=True,
                oracle_enabled=True,
                feed_config=_good_cfg(entry),
                price=1,
                quote_enabled=True,
                quote_type=2,
            )

        with mock.patch.object(runner, "assert_eth_healthy"), mock.patch.object(
            runner, "assert_usdg_healthy"
        ), mock.patch.object(runner, "classify_stock", side_effect=classify), mock.patch.object(
            runner, "read_quote_count", return_value=21
        ):
            with self.assertRaises(runner.Abort) as ctx:
                runner.final_verification(rpc, manifest)
            self.assertIn("22", str(ctx.exception))

        with mock.patch.object(runner, "assert_eth_healthy"), mock.patch.object(
            runner, "assert_usdg_healthy"
        ), mock.patch.object(runner, "classify_stock", side_effect=classify), mock.patch.object(
            runner, "read_quote_count", return_value=22
        ):
            runner.final_verification(rpc, manifest)

    def test_20_execution_log_no_secrets(self) -> None:
        log = runner.ExecutionLog()
        log.stocks.append(
            {
                "symbol": "NVDA",
                "token": _sample_entry("NVDA")["token"],
                "feed": _sample_entry("NVDA")["feed"],
                "tx1Hash": "0x" + "ab" * 32,
            }
        )
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            runner.save_log(path, log)
            blob = path.read_text()
            self.assertNotIn("AUTHORITY_PRIVATE_KEY", blob)
            self.assertNotIn("private_key", blob.lower())
            self.assertIn("tx1Hash", blob)

        # Refuse payloads that embed private-key field names
        bad = runner.ExecutionLog()
        bad.stocks.append({"symbol": "X", "private_key": "0x" + "ab" * 32})
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with self.assertRaises(runner.Abort):
                runner.save_log(path, bad)


class ConfirmGateTests(unittest.TestCase):
    def test_broadcast_requires_exact_confirmation(self) -> None:
        env = {
            "ROBINHOOD_RPC_URL": "https://example.invalid",
            "AUTHORITY_PRIVATE_KEY": "0x" + "22" * 32,
        }
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "exec.json"
            with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(
                runner, "derive_signer_address", return_value=runner.AUTHORITY
            ), mock.patch.object(runner, "CastRpc"), mock.patch.object(
                runner, "global_preflight"
            ), mock.patch.object(
                runner,
                "classify_stock",
                side_effect=lambda rpc, e: runner.classify_from_reads(e, configured=False, registered=False),
            ):
                with self.assertRaises(runner.Abort) as ctx:
                    runner.run(
                        broadcast=True,
                        manifest_path=MANIFEST_PATH,
                        log_path=log_path,
                        confirm_fn=lambda _p: "nope",
                    )
                self.assertIn("confirmation", str(ctx.exception).lower())


if __name__ == "__main__":
    unittest.main()
