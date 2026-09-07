import json
import subprocess
import time
from pathlib import Path

INPUT = Path("audit/final-stock-candidates-20-qualified-input.json")
OUTPUT = Path("audit/final-stock-candidates-20-live-audit.json")

RPC = subprocess.check_output(
    ["bash", "-lc", 'printf "%s" "$ROBINHOOD_RPC_URL"'],
    text=True,
).strip()

if not RPC.startswith(("http://", "https://")):
    raise SystemExit("ROBINHOOD_RPC_URL is not loaded correctly")

WETH = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
QUOTER = "0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7"

REGISTRY = "0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD"
ORACLE = "0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12"

FEE_TIERS = [100, 500, 3000, 10000]

WETH_PROBE = 10**16
USDG_PROBE = 10 * 10**6


def run(args):
    p = subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def cast_call(address, sig, *args):
    return run([
        "cast",
        "call",
        address,
        sig,
        *map(str, args),
        "--rpc-url",
        RPC,
    ])


def cast_code(address):
    return run([
        "cast",
        "code",
        address,
        "--rpc-url",
        RPC,
    ])


def first_int(output):
    if not output:
        return None

    try:
        return int(output.splitlines()[0].split()[0])
    except (ValueError, IndexError):
        return None


def clean_string(output):
    return output.strip().strip('"')


def probe_route(token_in, token_out, amount_in):
    candidates = []

    for fee in FEE_TIERS:
        tuple_arg = (
            f"({token_in},{token_out},{amount_in},{fee},0)"
        )

        rc, out, _ = cast_call(
            QUOTER,
            "quoteExactInputSingle((address,address,uint256,uint24,uint160))"
            "(uint256,uint160,uint32,uint256)",
            tuple_arg,
        )

        amount_out = first_int(out) if rc == 0 else None

        if amount_out is not None and amount_out > 0:
            candidates.append({
                "fee": fee,
                "amountOut": amount_out,
            })

    if not candidates:
        return {
            "available": False,
            "bestFee": None,
            "amountOut": None,
            "allRoutes": [],
        }

    best = max(candidates, key=lambda x: x["amountOut"])

    return {
        "available": True,
        "bestFee": best["fee"],
        "amountOut": best["amountOut"],
        "allRoutes": candidates,
    }


rows = json.loads(INPUT.read_text())
now = int(time.time())
report = []

for i, row in enumerate(rows, 1):
    sym = row["symbol"]
    token = row["token"]
    feed = row["oracleFeed"]
    max_age = int(row["scoopMaxAge"])

    print(f"[{i:02d}/20] {sym} ...", flush=True)

    result = dict(row)
    checks = {}
    errors = []

    # Token bytecode
    rc, out, _ = cast_code(token)
    has_code = rc == 0 and out not in ("", "0x")
    checks["hasCode"] = has_code

    if not has_code:
        errors.append("TOKEN_NO_CODE")

    # Token symbol
    rc, out, _ = cast_call(token, "symbol()(string)")
    live_symbol = clean_string(out) if rc == 0 else None
    checks["liveSymbol"] = live_symbol
    checks["symbolMatches"] = live_symbol == sym

    if not checks["symbolMatches"]:
        errors.append("SYMBOL_MISMATCH")

    # Token decimals
    rc, out, _ = cast_call(token, "decimals()(uint8)")
    token_decimals = first_int(out) if rc == 0 else None
    checks["tokenDecimals"] = token_decimals
    checks["decimals18"] = token_decimals == 18

    if not checks["decimals18"]:
        errors.append("TOKEN_DECIMALS_NOT_18")

    # Robinhood token oracle pause state
    rc, out, _ = cast_call(token, "oraclePaused()(bool)")
    oracle_paused = (
        clean_string(out).lower() == "true"
        if rc == 0
        else None
    )
    checks["oraclePaused"] = oracle_paused

    if oracle_paused is not False:
        errors.append("ORACLE_PAUSED_OR_UNREADABLE")

    # UI multiplier
    rc, out, _ = cast_call(token, "uiMultiplier()(uint256)")
    checks["uiMultiplier"] = (
        first_int(out)
        if rc == 0
        else None
    )

    # Feed bytecode
    rc, out, _ = cast_code(feed)
    feed_has_code = rc == 0 and out not in ("", "0x")
    checks["feedHasCode"] = feed_has_code

    if not feed_has_code:
        errors.append("FEED_NO_CODE")

    # Feed description
    rc, out, _ = cast_call(feed, "description()(string)")
    checks["feedDescription"] = (
        clean_string(out)
        if rc == 0
        else None
    )

    # Feed decimals
    rc, out, _ = cast_call(feed, "decimals()(uint8)")
    feed_decimals = first_int(out) if rc == 0 else None
    checks["feedDecimals"] = feed_decimals
    checks["feedDecimals8"] = feed_decimals == 8

    if not checks["feedDecimals8"]:
        errors.append("FEED_DECIMALS_NOT_8")

    # Latest round / freshness
    rc, out, _ = cast_call(
        feed,
        "latestRoundData()(uint80,int256,uint256,uint256,uint80)",
    )

    if rc == 0:
        lines = out.splitlines()

        try:
            round_id = int(lines[0].split()[0])
            answer = int(lines[1].split()[0])
            updated_at = int(lines[3].split()[0])
            answered_in_round = int(lines[4].split()[0])

            age = now - updated_at

            checks["feedAnswer"] = answer
            checks["feedUpdatedAt"] = updated_at
            checks["feedAgeSeconds"] = age
            checks["feedPositive"] = answer > 0
            checks["feedFresh"] = 0 <= age <= max_age
            checks["roundComplete"] = (
                answered_in_round >= round_id
            )

            if answer <= 0:
                errors.append("NON_POSITIVE_PRICE")

            if not checks["feedFresh"]:
                errors.append("STALE_FEED")

            if not checks["roundComplete"]:
                errors.append("INCOMPLETE_ROUND")

        except (ValueError, IndexError):
            errors.append("ROUND_DATA_PARSE_ERROR")
    else:
        errors.append("ROUND_DATA_UNREADABLE")

    # Current production registry state
    rc, out, _ = cast_call(
        REGISTRY,
        "isRegistered(address)(bool)",
        token,
    )
    registered = (
        clean_string(out).lower() == "true"
        if rc == 0
        else None
    )
    checks["alreadyRegistered"] = registered

    # Current production oracle state
    rc, out, _ = cast_call(
        ORACLE,
        "isConfigured(address)(bool)",
        token,
    )
    configured = (
        clean_string(out).lower() == "true"
        if rc == 0
        else None
    )
    checks["alreadyOracleConfigured"] = configured

    # V3 routes
    weth_route = probe_route(
        WETH,
        token,
        WETH_PROBE,
    )

    usdg_route = probe_route(
        USDG,
        token,
        USDG_PROBE,
    )

    checks["wethRoute"] = weth_route
    checks["usdgRoute"] = usdg_route

    # ETH-originating route can be either direct WETH->stock,
    # or WETH->USDG->stock using the already-proven USDG route.
    checks["ethPaymentRouteAvailable"] = (
        weth_route["available"]
        or usdg_route["available"]
    )

    if not usdg_route["available"]:
        errors.append("NO_DIRECT_USDG_ROUTE")

    if not checks["ethPaymentRouteAvailable"]:
        errors.append("NO_ETH_ORIGIN_ROUTE")

    result["liveChecks"] = checks
    result["errors"] = errors
    result["hardPass"] = len(errors) == 0

    report.append(result)

OUTPUT.write_text(json.dumps(report, indent=2))

print()
print("=" * 86)
print("SCOOP STOCK CATALOGUE — LIVE READ-ONLY QUALIFICATION")
print("=" * 86)

print(
    f"{'SYM':5} "
    f"{'TOKEN':6} "
    f"{'FEED':6} "
    f"{'AGE(h)':>8} "
    f"{'PAUSED':>7} "
    f"{'WETH':>8} "
    f"{'USDG':>8} "
    f"{'STATUS':>8}"
)

print("-" * 86)

for r in report:
    c = r["liveChecks"]

    age = c.get("feedAgeSeconds")
    age_h = (
        f"{age / 3600:.1f}"
        if isinstance(age, int)
        else "ERR"
    )

    weth = c["wethRoute"]
    usdg = c["usdgRoute"]

    weth_text = (
        str(weth["bestFee"])
        if weth["available"]
        else "NONE"
    )

    usdg_text = (
        str(usdg["bestFee"])
        if usdg["available"]
        else "NONE"
    )

    token_ok = (
        c.get("hasCode")
        and c.get("symbolMatches")
        and c.get("decimals18")
    )

    feed_ok = (
        c.get("feedHasCode")
        and c.get("feedDecimals8")
        and c.get("feedFresh")
    )

    print(
        f"{r['symbol']:5} "
        f"{'PASS' if token_ok else 'FAIL':6} "
        f"{'PASS' if feed_ok else 'FAIL':6} "
        f"{age_h:>8} "
        f"{str(c.get('oraclePaused')):>7} "
        f"{weth_text:>8} "
        f"{usdg_text:>8} "
        f"{'PASS' if r['hardPass'] else 'FAIL':>8}"
    )

passes = sum(
    1
    for r in report
    if r["hardPass"]
)

print()
print(f"HARD_PASS={passes}")
print(f"FAIL={len(report) - passes}")

if passes != len(report):
    print()
    print("FAILURES:")

    for r in report:
        if not r["hardPass"]:
            print(
                r["symbol"],
                "=>",
                ", ".join(r["errors"]),
            )

print()
print("REPORT =", OUTPUT)
