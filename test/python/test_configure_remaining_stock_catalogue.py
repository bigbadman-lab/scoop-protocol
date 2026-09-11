#!/usr/bin/env python3
"""Unit tests for canonical stock catalogue runner (no live chain writes)."""

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

CANONICAL_QR = "0xE3782bef83cfB17B5a84B2649405a944dc58e40C"
CANONICAL_PO = "0x346a84fbAB49a50a2255F2808fd6BCe812DaFe5c"
HISTORICAL_QR = "0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD"
HISTORICAL_PO = "0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12"


def _targets() -> runner.ScoopTargets:
    return runner.ScoopTargets(quote_registry=CANONICAL_QR.lower(), price_oracle=CANONICAL_PO.lower())


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


def _complete_state(entry: dict[str, Any]) -> runner.StockLiveState:
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


class ManifestTests(unittest.TestCase):
    def test_manifest_validation(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        self.assertEqual(len(m), 20)
        self.assertEqual(m[0]["symbol"], "AAPL")
        self.assertEqual(m[1]["symbol"], "AMD")
        for e in m:
            self.assertEqual(e["maxAge"], 345600)
            self.assertEqual(e["quoteType"], 2)
            self.assertNotIn("tx1", e)
            self.assertNotIn("tx2", e)

    def test_manifest_rejects_embedded_tx_targets(self) -> None:
        entry = _sample_entry()
        entry["tx1"] = {"target": HISTORICAL_PO, "calldata": "0x"}
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.json"
            # pad to 20 with variants — easier: load real and inject one tx
            m = runner.load_manifest(MANIFEST_PATH)
            m[0] = dict(m[0])
            m[0]["tx1"] = {"target": HISTORICAL_PO, "calldata": "0x"}
            p.write_text(json.dumps(m))
            with self.assertRaises(runner.Abort) as ctx:
                runner.load_manifest(p)
            self.assertIn("tx1/tx2", str(ctx.exception))

    def test_manifest_wrong_count_aborts(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "bad.json"
            p.write_text(json.dumps([_sample_entry()]))
            with self.assertRaises(runner.Abort):
                runner.load_manifest(p)

    def test_production_module_has_no_historical_qr_po_constants(self) -> None:
        src = Path(runner.__file__).read_text()
        self.assertNotIn(HISTORICAL_QR, src)
        self.assertNotIn(HISTORICAL_PO, src)
        self.assertNotIn("0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD", src)
        self.assertNotIn("0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12", src)


class EnvTargetTests(unittest.TestCase):
    def test_missing_quote_registry_env(self) -> None:
        with mock.patch.dict(os.environ, {"SCOOP_PRICE_ORACLE": CANONICAL_PO}, clear=False):
            os.environ.pop("SCOOP_QUOTE_REGISTRY", None)
            with self.assertRaises(runner.Abort) as ctx:
                runner.load_scoop_targets_from_env()
            self.assertIn("SCOOP_QUOTE_REGISTRY", str(ctx.exception))

    def test_missing_price_oracle_env(self) -> None:
        with mock.patch.dict(os.environ, {"SCOOP_QUOTE_REGISTRY": CANONICAL_QR}, clear=False):
            os.environ.pop("SCOOP_PRICE_ORACLE", None)
            with self.assertRaises(runner.Abort) as ctx:
                runner.load_scoop_targets_from_env()
            self.assertIn("SCOOP_PRICE_ORACLE", str(ctx.exception))

    def test_env_driven_targets(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"SCOOP_QUOTE_REGISTRY": CANONICAL_QR, "SCOOP_PRICE_ORACLE": CANONICAL_PO},
            clear=False,
        ):
            t = runner.load_scoop_targets_from_env()
            self.assertEqual(t.quote_registry, CANONICAL_QR.lower())
            self.assertEqual(t.price_oracle, CANONICAL_PO.lower())


class SymbolSelectionTests(unittest.TestCase):
    def test_select_preserves_catalogue_order(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        selected = runner.select_symbols(m, "TSLA,AAPL,NVDA")
        self.assertEqual([e["symbol"] for e in selected], ["AAPL", "NVDA", "TSLA"])

    def test_unknown_symbol_aborts(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        with self.assertRaises(runner.Abort) as ctx:
            runner.select_symbols(m, "AAPL,FAKE")
        self.assertIn("unknown symbol", str(ctx.exception).lower())

    def test_duplicate_symbol_aborts(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        with self.assertRaises(runner.Abort) as ctx:
            runner.select_symbols(m, "AAPL,AMD,AAPL")
        self.assertIn("duplicate", str(ctx.exception).lower())

    def test_empty_selection_aborts(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        with self.assertRaises(runner.Abort):
            runner.select_symbols(m, "")
        with self.assertRaises(runner.Abort):
            runner.select_symbols(m, " , , ")


class ClassificationTests(unittest.TestCase):
    def test_untouched(self) -> None:
        entry = _sample_entry("NVDA")
        st = runner.classify_from_reads(entry, configured=False, registered=False)
        self.assertEqual(st.classification, runner.StockState.UNTOUCHED)
        self.assertTrue(st.needs_tx1 and st.needs_tx2)

    def test_oracle_only(self) -> None:
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

    def test_complete(self) -> None:
        st = _complete_state(_sample_entry("MSFT"))
        self.assertEqual(st.classification, runner.StockState.COMPLETE)
        self.assertFalse(st.needs_tx1 or st.needs_tx2)

    def test_invalid_registered_without_oracle(self) -> None:
        entry = _sample_entry("NVDA")
        st = runner.classify_from_reads(entry, configured=False, registered=True, quote_enabled=True, quote_type=2)
        self.assertEqual(st.classification, runner.StockState.INVALID)

    def test_invalid_wrong_max_age(self) -> None:
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

    def test_expected_count_from_states(self) -> None:
        m = runner.load_manifest(MANIFEST_PATH)
        states = [
            _complete_state(m[0]),
            _complete_state(m[1]),
            runner.classify_from_reads(m[2], configured=False, registered=False),
        ]
        # pad with untouched for remaining entries so COMPLETE count is 2
        for e in m[3:]:
            states.append(runner.classify_from_reads(e, configured=False, registered=False))
        self.assertEqual(runner.expected_quote_count_from_states(states), 4)


class GuardTests(unittest.TestCase):
    def test_stale_feed_aborts(self) -> None:
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

    def test_wrong_chain_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = 1
        with self.assertRaises(runner.Abort) as ctx:
            runner.global_preflight(
                rpc, _targets(), runner.load_manifest(MANIFEST_PATH), runner.AUTHORITY, require_balance=False
            )
        self.assertIn("chainId", str(ctx.exception))

    def test_wrong_authority_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        rpc.codesize.return_value = 100
        with mock.patch.object(
            runner, "parse_address", side_effect=["0x1111111111111111111111111111111111111111", runner.AUTHORITY]
        ):
            with self.assertRaises(runner.Abort) as ctx:
                runner.global_preflight(
                    rpc, _targets(), runner.load_manifest(MANIFEST_PATH), runner.AUTHORITY, require_balance=False
                )
        self.assertIn("registryAuthority", str(ctx.exception))

    def test_signer_mismatch_aborts(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        rpc.codesize.return_value = 100
        with mock.patch.object(runner, "parse_address", return_value=runner.AUTHORITY):
            with self.assertRaises(runner.Abort) as ctx:
                runner.global_preflight(
                    rpc,
                    _targets(),
                    runner.load_manifest(MANIFEST_PATH),
                    "0x1111111111111111111111111111111111111111",
                    require_balance=False,
                )
        self.assertIn("signer", str(ctx.exception).lower())

    def test_insufficient_eth_blocks_broadcast(self) -> None:
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        rpc.codesize.return_value = 100
        rpc.balance_wei.return_value = 0
        manifest = runner.load_manifest(MANIFEST_PATH)

        with mock.patch.object(runner, "parse_address", return_value=runner.AUTHORITY), mock.patch.object(
            runner, "assert_eth_healthy"
        ), mock.patch.object(runner, "assert_usdg_healthy"), mock.patch.object(
            runner, "assert_registered_set_canonical"
        ), mock.patch.object(
            runner,
            "classify_stock",
            side_effect=lambda rpc, targets, e: runner.classify_from_reads(e, configured=False, registered=False),
        ), mock.patch.object(runner, "read_quote_count", return_value=2):
            with self.assertRaises(runner.Abort) as ctx:
                runner.global_preflight(rpc, _targets(), manifest, runner.AUTHORITY, require_balance=True)
        self.assertIn("ETH balance", str(ctx.exception))
        self.assertEqual(runner.MIN_AUTHORITY_ETH_WEI, 10**16)


class ProcessStockTests(unittest.TestCase):
    def _fresh(self) -> None:
        self._p1 = mock.patch.object(runner, "assert_feed_fresh")
        self._p1.start()
        self.addCleanup(self._p1.stop)

    def test_tx1_failure_stops(self) -> None:
        self._fresh()
        entry = _sample_entry("NVDA")
        state = runner.classify_from_reads(entry, configured=False, registered=False)
        rpc = mock.Mock()
        rpc.send_calldata.side_effect = runner.Abort("tx1 send failed")
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with mock.patch.object(runner, "build_configure_feed_calldata", return_value="0xabc"):
                with self.assertRaises(runner.Abort):
                    runner.process_stock(
                        rpc,
                        _targets(),
                        entry,
                        state,
                        broadcast=True,
                        private_key="0x" + "11" * 32,
                        log=log,
                        log_path=path,
                    )
            self.assertEqual(rpc.send_calldata.call_count, 1)

    def test_tx1_bad_readback_no_tx2(self) -> None:
        self._fresh()
        entry = _sample_entry("NVDA")
        state = runner.classify_from_reads(entry, configured=False, registered=False)
        rpc = mock.Mock()
        rpc.send_calldata.return_value = {
            "status": "0x1",
            "transactionHash": "0x" + "ab" * 32,
            "blockNumber": "0x10",
            "gasUsed": "0x5208",
            "to": CANONICAL_PO,
            "from": runner.AUTHORITY,
        }
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with mock.patch.object(runner, "build_configure_feed_calldata", return_value="0xabc"), mock.patch.object(
                runner, "verify_oracle_after_tx1", side_effect=runner.Abort("bad readback")
            ):
                with self.assertRaises(runner.Abort) as ctx:
                    runner.process_stock(
                        rpc,
                        _targets(),
                        entry,
                        state,
                        broadcast=True,
                        private_key="0x" + "11" * 32,
                        log=log,
                        log_path=path,
                    )
            self.assertIn("NOT sending TX2", str(ctx.exception))
            self.assertEqual(rpc.send_calldata.call_count, 1)

    def test_oracle_only_sends_tx2_to_quote_registry(self) -> None:
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
            with mock.patch.object(runner, "build_register_quote_calldata", return_value="0xdef"):
                with self.assertRaises(runner.Abort):
                    runner.process_stock(
                        rpc,
                        _targets(),
                        entry,
                        state,
                        broadcast=True,
                        private_key="0x" + "11" * 32,
                        log=log,
                        log_path=path,
                    )
            self.assertEqual(rpc.send_calldata.call_count, 1)
            self.assertEqual(rpc.send_calldata.call_args.kwargs["to"], CANONICAL_QR.lower())

    def test_oracle_before_register_order(self) -> None:
        self._fresh()
        entry = _sample_entry("NVDA")
        state = runner.classify_from_reads(entry, configured=False, registered=False)
        rpc = mock.Mock()
        calls: list[str] = []

        def send(**kwargs: Any) -> dict[str, Any]:
            calls.append(kwargs["to"])
            return {
                "status": "0x1",
                "transactionHash": "0x" + "cd" * 32,
                "blockNumber": "0x11",
                "gasUsed": "0x5208",
                "to": kwargs["to"],
                "from": runner.AUTHORITY,
            }

        rpc.send_calldata.side_effect = send
        log = runner.ExecutionLog()
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "log.json"
            with mock.patch.object(runner, "build_configure_feed_calldata", return_value="0x1"), mock.patch.object(
                runner, "build_register_quote_calldata", return_value="0x2"
            ), mock.patch.object(runner, "verify_oracle_after_tx1"), mock.patch.object(
                runner, "verify_after_tx2"
            ):
                runner.process_stock(
                    rpc,
                    _targets(),
                    entry,
                    state,
                    broadcast=True,
                    private_key="0x" + "11" * 32,
                    log=log,
                    log_path=path,
                )
        self.assertEqual(calls, [CANONICAL_PO.lower(), CANONICAL_QR.lower()])


class RunGateTests(unittest.TestCase):
    def _env(self) -> dict[str, str]:
        return {
            "ROBINHOOD_RPC_URL": "https://example.invalid",
            "AUTHORITY_PRIVATE_KEY": "0x" + "22" * 32,
            "SCOOP_QUOTE_REGISTRY": CANONICAL_QR,
            "SCOOP_PRICE_ORACLE": CANONICAL_PO,
        }

    def test_broadcast_requires_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "exec.json"
            with mock.patch.dict(os.environ, self._env(), clear=False), mock.patch.object(
                runner, "derive_signer_address", return_value=runner.AUTHORITY
            ):
                with self.assertRaises(runner.Abort) as ctx:
                    runner.run(
                        broadcast=True,
                        manifest_path=MANIFEST_PATH,
                        log_path=log_path,
                        symbols_csv=None,
                    )
                self.assertIn("requires explicit --symbols", str(ctx.exception))

    def test_broadcast_confirmation_tied_to_remaining_count(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "exec.json"
            with mock.patch.dict(os.environ, self._env(), clear=False), mock.patch.object(
                runner, "derive_signer_address", return_value=runner.AUTHORITY
            ), mock.patch.object(runner, "CastRpc"), mock.patch.object(
                runner, "global_preflight"
            ), mock.patch.object(
                runner,
                "classify_stock",
                side_effect=lambda rpc, targets, e: runner.classify_from_reads(
                    e, configured=False, registered=False
                ),
            ):
                with self.assertRaises(runner.Abort) as ctx:
                    runner.run(
                        broadcast=True,
                        manifest_path=MANIFEST_PATH,
                        log_path=log_path,
                        symbols_csv="AAPL,AMD",
                        confirm_fn=lambda _p: "BROADCAST 99 STOCKS",
                    )
                self.assertIn("confirmation", str(ctx.exception).lower())

    def test_dry_run_without_symbols_inspects_full_catalogue(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "exec.json"
            classified: list[str] = []

            def classify(_rpc: Any, _targets: Any, e: dict[str, Any]) -> runner.StockLiveState:
                classified.append(e["symbol"])
                return runner.classify_from_reads(e, configured=False, registered=False)

            with mock.patch.dict(os.environ, self._env(), clear=False), mock.patch.object(
                runner, "derive_signer_address", return_value=runner.AUTHORITY
            ), mock.patch.object(runner, "CastRpc"), mock.patch.object(
                runner, "global_preflight"
            ), mock.patch.object(runner, "classify_stock", side_effect=classify):
                code = runner.run(
                    broadcast=False, manifest_path=MANIFEST_PATH, log_path=log_path, symbols_csv=None
                )
            self.assertEqual(code, 0)
            self.assertEqual(len(classified), 20)
            self.assertFalse(log_path.exists())

    def test_dry_run_allowed_without_funding_floor(self) -> None:
        """require_balance=False path used for dry-run; funding floor only for broadcast."""
        rpc = mock.Mock()
        rpc.chain_id.return_value = runner.CHAIN_ID
        rpc.codesize.return_value = 100
        rpc.balance_wei.return_value = 0
        manifest = runner.load_manifest(MANIFEST_PATH)
        with mock.patch.object(runner, "parse_address", return_value=runner.AUTHORITY), mock.patch.object(
            runner, "assert_eth_healthy"
        ), mock.patch.object(runner, "assert_usdg_healthy"), mock.patch.object(
            runner, "assert_registered_set_canonical"
        ), mock.patch.object(
            runner,
            "classify_stock",
            side_effect=lambda rpc, targets, e: runner.classify_from_reads(e, configured=False, registered=False),
        ), mock.patch.object(runner, "read_quote_count", return_value=2):
            # Should not raise despite zero balance when require_balance=False
            runner.global_preflight(rpc, _targets(), manifest, runner.AUTHORITY, require_balance=False)

    def test_execution_log_no_secrets(self) -> None:
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


class FinalVerificationTests(unittest.TestCase):
    def test_final_verification_uses_derived_count(self) -> None:
        rpc = mock.Mock()
        manifest = runner.load_manifest(MANIFEST_PATH)
        selected = [manifest[0], manifest[1]]

        def classify(_rpc: Any, _targets: Any, entry: dict[str, Any]) -> runner.StockLiveState:
            if entry["symbol"] in ("AAPL", "AMD"):
                return _complete_state(entry)
            return runner.classify_from_reads(entry, configured=False, registered=False)

        with mock.patch.object(runner, "assert_eth_healthy"), mock.patch.object(
            runner, "assert_usdg_healthy"
        ), mock.patch.object(runner, "assert_registered_set_canonical"), mock.patch.object(
            runner, "classify_stock", side_effect=classify
        ), mock.patch.object(runner, "read_quote_count", return_value=4):
            runner.final_verification(rpc, _targets(), manifest, selected)

        with mock.patch.object(runner, "assert_eth_healthy"), mock.patch.object(
            runner, "assert_usdg_healthy"
        ), mock.patch.object(runner, "assert_registered_set_canonical"), mock.patch.object(
            runner, "classify_stock", side_effect=classify
        ), mock.patch.object(runner, "read_quote_count", return_value=3):
            with self.assertRaises(runner.Abort) as ctx:
                runner.final_verification(rpc, _targets(), manifest, selected)
            self.assertIn("expected 4", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
