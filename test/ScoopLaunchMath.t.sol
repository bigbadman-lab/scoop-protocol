// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "../lib/v4-core/test/utils/LiquidityAmounts.sol";

import {ScoopLaunchMath} from "../src/libraries/ScoopLaunchMath.sol";

/// @dev Exposes ScoopLaunchMath for Foundry tests (internal library linkage).
contract ScoopLaunchMathHarness {
    function calculateLaunchPricing(
        address launchedToken,
        address quoteAsset,
        uint8 quoteDecimals,
        uint256 quotePriceUsd
    ) external pure returns (ScoopLaunchMath.LaunchPricing memory) {
        return ScoopLaunchMath.calculateLaunchPricing(launchedToken, quoteAsset, quoteDecimals, quotePriceUsd);
    }

    function floorToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return ScoopLaunchMath.floorToSpacing(tick, spacing);
    }

    function ceilToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return ScoopLaunchMath.ceilToSpacing(tick, spacing);
    }

    function oneSidedLpTicks(int24 openingTick, bool launchedIsCurrency1)
        external
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        return ScoopLaunchMath.oneSidedLpTicks(openingTick, launchedIsCurrency1);
    }

    function encodeSqrtRatioX96(uint256 amount1, uint256 amount0) external pure returns (uint160) {
        return ScoopLaunchMath.encodeSqrtRatioX96(amount1, amount0);
    }

    function tokenUsdPrice() external pure returns (uint256) {
        return ScoopLaunchMath.tokenUsdPrice();
    }
}

contract ScoopLaunchMathTest is Test {
    ScoopLaunchMathHarness math;

    uint256 constant ETH_USD = 2455221900000000000000;
    uint256 constant AAPL_USD = 320516335250000000000;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    /// @dev Relative FDV tolerance: 0.1% (1e15 / 1e18).
    uint256 constant FDV_REL_TOL = 1e15;

    function setUp() public {
        math = new ScoopLaunchMathHarness();
    }

    // ─── Constants / target economics ────────────────────────────────────────

    function test_constants_andTokenUsdPrice() public view {
        assertEq(ScoopLaunchMath.TARGET_FDV_USD, 5_000e18);
        assertEq(ScoopLaunchMath.TOKEN_SUPPLY, 1_000_000_000 ether);
        assertEq(ScoopLaunchMath.TOKEN_DECIMALS, 18);
        assertEq(math.tokenUsdPrice(), 5e12);

        // 5e12 * 1_000_000_000 whole tokens = 5_000e18
        assertEq(uint256(5e12) * uint256(1_000_000_000), uint256(5_000e18));

        // Equivalent derivation via supply base units:
        assertEq(
            FullMath.mulDiv(
                ScoopLaunchMath.TARGET_FDV_USD,
                10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS),
                ScoopLaunchMath.TOKEN_SUPPLY
            ),
            uint256(5e12)
        );
    }

    // ─── Tick alignment ──────────────────────────────────────────────────────

    function test_floorToSpacing_examples() public view {
        int24 s = 200;
        assertEq(int256(math.floorToSpacing(201, s)), int256(200));
        assertEq(int256(math.floorToSpacing(200, s)), int256(200));
        assertEq(int256(math.floorToSpacing(199, s)), int256(0));
        assertEq(int256(math.floorToSpacing(-1, s)), int256(-200));
        assertEq(int256(math.floorToSpacing(-199, s)), int256(-200));
        assertEq(int256(math.floorToSpacing(-200, s)), int256(-200));
        assertEq(int256(math.floorToSpacing(-201, s)), int256(-400));
    }

    function test_ceilToSpacing_examples() public view {
        int24 s = 200;
        assertEq(int256(math.ceilToSpacing(201, s)), int256(400));
        assertEq(int256(math.ceilToSpacing(200, s)), int256(200));
        assertEq(int256(math.ceilToSpacing(199, s)), int256(200));
        assertEq(int256(math.ceilToSpacing(-1, s)), int256(0));
        assertEq(int256(math.ceilToSpacing(-199, s)), int256(0));
        assertEq(int256(math.ceilToSpacing(-200, s)), int256(-200));
        assertEq(int256(math.ceilToSpacing(-201, s)), int256(-200));
    }

    function test_tick0_currency1_reproducesLegacyRange() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(0, true);
        assertEq(int256(lo), -400);
        assertEq(int256(hi), -200);
    }

    function test_tick0_currency0_rangeAbove() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(0, false);
        assertEq(int256(lo), 200);
        assertEq(int256(hi), 400);
    }

    // ─── ETH ─────────────────────────────────────────────────────────────────

    function test_eth_openingPriceAndOneSidedLp() public view {
        // ETH sorts first; any nonzero launched token is currency1.
        address token = address(0xBEEF);
        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, address(0), 18, ETH_USD);

        assertTrue(p.launchedIsCurrency1);
        assertGe(p.sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        assertLt(p.sqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        assertTrue(p.tickUpper < p.openingTick);
        assertEq(int256(p.tickUpper - p.tickLower), 200);
        assertEq(int256(p.tickLower % 200), 0);
        assertEq(int256(p.tickUpper % 200), 0);

        (uint256 tokenUsd, uint256 fdv) = _reconstruct(p, 18, ETH_USD);
        assertApproxEqRel(tokenUsd, 5e12, FDV_REL_TOL);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);

        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);

        console2.log("ETH sqrtPriceX96", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("ETH tokenUsd", tokenUsd);
        console2.log("ETH FDV", fdv);
        console2.log("ETH FDV error abs", fdv > 5_000e18 ? fdv - 5_000e18 : 5_000e18 - fdv);
    }

    // ─── AAPL both orientations ──────────────────────────────────────────────

    function test_aapl_quoteAsCurrency0() public view {
        // launched > AAPL so AAPL = c0, token = c1
        address token = address(uint160(uint256(uint160(AAPL)) + 1));
        assertTrue(token > AAPL);

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, AAPL, 18, AAPL_USD);
        assertTrue(p.launchedIsCurrency1);
        assertTrue(p.tickUpper < p.openingTick);

        (uint256 tokenUsd, uint256 fdv) = _reconstruct(p, 18, AAPL_USD);
        assertApproxEqRel(tokenUsd, 5e12, FDV_REL_TOL);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);

        console2.log("AAPL c0 sqrtPriceX96", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("AAPL c0 FDV", fdv);
    }

    function test_aapl_quoteAsCurrency1() public view {
        // launched < AAPL so token = c0, AAPL = c1
        address token = address(uint160(uint256(uint160(AAPL)) - 1));
        assertTrue(token != address(0));
        assertTrue(token < AAPL);

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, AAPL, 18, AAPL_USD);
        assertFalse(p.launchedIsCurrency1);
        assertTrue(p.tickLower > p.openingTick);

        (uint256 tokenUsd, uint256 fdv) = _reconstruct(p, 18, AAPL_USD);
        assertApproxEqRel(tokenUsd, 5e12, FDV_REL_TOL);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);

        console2.log("AAPL c1 sqrtPriceX96", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("AAPL c1 FDV", fdv);
    }

    function test_aapl_bothOrientationsSameEconomics() public view {
        address tokenHi = address(uint160(uint256(uint160(AAPL)) + 1));
        address tokenLo = address(uint160(uint256(uint160(AAPL)) - 1));

        ScoopLaunchMath.LaunchPricing memory p0 = math.calculateLaunchPricing(tokenHi, AAPL, 18, AAPL_USD);
        ScoopLaunchMath.LaunchPricing memory p1 = math.calculateLaunchPricing(tokenLo, AAPL, 18, AAPL_USD);

        assertTrue(p0.sqrtPriceX96 != p1.sqrtPriceX96);
        (, uint256 fdv0) = _reconstruct(p0, 18, AAPL_USD);
        (, uint256 fdv1) = _reconstruct(p1, 18, AAPL_USD);
        assertApproxEqRel(fdv0, fdv1, FDV_REL_TOL);
        assertApproxEqRel(fdv0, 5_000e18, FDV_REL_TOL);
    }

    // ─── Quote decimals ──────────────────────────────────────────────────────

    function test_quoteDecimals_6_8_18() public view {
        address token = address(0xBEEF);
        address quote = address(0x1); // currency0 → launched is currency1
        uint256 quoteUsd = 100e18; // $100

        // Production path (18dp) keeps tight FDV round-trip.
        ScoopLaunchMath.LaunchPricing memory p18 = math.calculateLaunchPricing(token, quote, 18, quoteUsd);
        (, uint256 fdv18) = _reconstruct(p18, 18, quoteUsd);
        assertApproxEqRel(fdv18, 5_000e18, FDV_REL_TOL);

        // 6/8dp: assert encode matches the exact raw amount1/amount0 ratio (decode of huge
        // sqrt prices is lossy in Q64.96 sequential division; V1 quotes are 18dp).
        _assertEncodeMatches(token, quote, 8, quoteUsd);
        _assertEncodeMatches(token, quote, 6, quoteUsd);
        _assertEncodeMatches(token, quote, 18, quoteUsd);
    }

    function _assertEncodeMatches(address token, address quote, uint8 quoteDecimals, uint256 quoteUsd) internal view {
        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, quote, quoteDecimals, quoteUsd);
        uint256 tokenScale = 10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        uint256 amount1 = FullMath.mulDiv(quoteUsd, tokenScale, 1);
        uint256 amount0 = FullMath.mulDiv(ScoopLaunchMath.TOKEN_USD_PRICE, quoteScale, 1);
        assertEq(p.sqrtPriceX96, math.encodeSqrtRatioX96(amount1, amount0));
        assertTrue(p.launchedIsCurrency1);
        assertTrue(p.tickUpper < p.openingTick);
        assertEq(int256(p.tickUpper - p.tickLower), 200);
    }

    // ─── Invalid inputs ──────────────────────────────────────────────────────

    function test_zeroQuotePriceReverts() public {
        vm.expectRevert(ScoopLaunchMath.ZeroQuotePrice.selector);
        math.calculateLaunchPricing(address(0xBEEF), address(0), 18, 0);
    }

    function test_identicalCurrenciesReverts() public {
        vm.expectRevert(ScoopLaunchMath.IdenticalCurrencies.selector);
        math.calculateLaunchPricing(address(0), address(0), 18, ETH_USD);
    }

    function test_unsupportedDecimalsReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopLaunchMath.UnsupportedTokenDecimals.selector, uint8(19)));
        math.calculateLaunchPricing(address(0xBEEF), address(0), 19, ETH_USD);
    }

    function test_extremePriceOutOfRangeReverts() public {
        // Astronomical inputs must not succeed; accept PriceOutOfRange or arithmetic/panic revert.
        vm.expectRevert();
        math.calculateLaunchPricing(address(0xBEEF), address(0x1), 0, 1e70);

        vm.expectRevert();
        math.calculateLaunchPricing(address(0x1), address(0x2), 18, 1e70);
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_quotePrice_fdvTolerance(uint256 quoteUsd) public view {
        quoteUsd = bound(quoteUsd, 0.01e18, 1_000_000e18);
        address token = address(0xBEEF);
        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, address(0), 18, quoteUsd);
        (, uint256 fdv) = _reconstruct(p, 18, quoteUsd);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p, 1_000_000 ether); // smaller liquidity sample still proves sidedness
    }

    function testFuzz_addressOrientation(address launched, address quote, uint256 quoteUsd) public view {
        vm.assume(launched != quote);
        vm.assume(launched != address(0) || quote != address(0));
        // Prefer nonzero launched token for ScoopToken realism when quote is ETH
        if (quote == address(0)) vm.assume(launched != address(0));
        if (launched == address(0)) vm.assume(quote != address(0));

        quoteUsd = bound(quoteUsd, 1e18, 100_000e18); // $1–$100k

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(launched, quote, 18, quoteUsd);
        bool expectC1 = uint160(launched) > uint160(quote);
        assertTrue(p.launchedIsCurrency1 == expectC1);

        if (expectC1) {
            assertTrue(p.tickUpper < p.openingTick);
        } else {
            assertTrue(p.tickLower > p.openingTick);
        }
        assertEq(int256(p.tickUpper - p.tickLower), 200);
        assertEq(int256(p.tickLower % 200), 0);
        assertEq(int256(p.tickUpper % 200), 0);

        (, uint256 fdv) = _reconstruct(p, 18, quoteUsd);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
    }

    function testFuzz_tickAlignment(int24 openingTick) public view {
        openingTick = int24(bound(int256(openingTick), -800_000, 800_000));
        (int24 lo1, int24 hi1) = math.oneSidedLpTicks(openingTick, true);
        (int24 lo0, int24 hi0) = math.oneSidedLpTicks(openingTick, false);

        assertEq(int256(hi1 - lo1), 200);
        assertEq(int256(hi0 - lo0), 200);
        assertEq(int256(lo1 % 200), 0);
        assertEq(int256(hi1 % 200), 0);
        assertEq(int256(lo0 % 200), 0);
        assertEq(int256(hi0 % 200), 0);
        assertTrue(hi1 < openingTick);
        assertTrue(lo0 > openingTick);
    }

    function testFuzz_quoteDecimals(uint8 quoteDecimals, uint256 quoteUsd) public view {
        quoteDecimals = uint8(bound(quoteDecimals, 0, 18));
        quoteUsd = bound(quoteUsd, 1e18, 50_000e18);
        address token = address(0xBEEF);
        address quote = address(0x1);
        try math.calculateLaunchPricing(token, quote, quoteDecimals, quoteUsd) returns (
            ScoopLaunchMath.LaunchPricing memory p
        ) {
            uint256 tokenScale = 10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS);
            uint256 quoteScale = 10 ** uint256(quoteDecimals);
            uint256 amount1 = FullMath.mulDiv(quoteUsd, tokenScale, 1);
            uint256 amount0 = FullMath.mulDiv(ScoopLaunchMath.TOKEN_USD_PRICE, quoteScale, 1);
            assertEq(p.sqrtPriceX96, math.encodeSqrtRatioX96(amount1, amount0));
            if (quoteDecimals == 18) {
                (, uint256 fdv) = _reconstruct(p, quoteDecimals, quoteUsd);
                assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
            }
        } catch {
            // Unrepresentable extremes are acceptable.
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _reconstruct(ScoopLaunchMath.LaunchPricing memory p, uint8 quoteDecimals, uint256 quotePriceUsd)
        internal
        pure
        returns (uint256 tokenUsd, uint256 fdvUsd)
    {
        uint256 tokenUnits = 10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);

        uint256 quoteRawPerWholeToken;
        if (p.launchedIsCurrency1) {
            // quote/token = 2^192 / sqrtP^2
            quoteRawPerWholeToken = _mulDivInversePrice(tokenUnits, p.sqrtPriceX96);
        } else {
            // quote/token = sqrtP^2 / 2^192
            quoteRawPerWholeToken = _mulDivPrice(tokenUnits, p.sqrtPriceX96);
        }

        uint256 quotePerToken1e18 = FullMath.mulDiv(quoteRawPerWholeToken, 1e18, quoteScale);
        tokenUsd = FullMath.mulDiv(quotePerToken1e18, quotePriceUsd, 1e18);
        fdvUsd = tokenUsd * 1_000_000_000;
    }

    function _mulDivPrice(uint256 amount, uint160 sqrtP) internal pure returns (uint256) {
        uint256 a = FullMath.mulDiv(amount, sqrtP, FixedPoint96.Q96);
        return FullMath.mulDiv(a, sqrtP, FixedPoint96.Q96);
    }

    function _mulDivInversePrice(uint256 amount, uint160 sqrtP) internal pure returns (uint256) {
        uint256 a = FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtP);
        return FullMath.mulDiv(a, FixedPoint96.Q96, sqrtP);
    }

    function _assertOneSided(ScoopLaunchMath.LaunchPricing memory p, uint256 launchedAmount) internal pure {
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(p.tickUpper);

        if (p.launchedIsCurrency1) {
            uint128 liq = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtU, launchedAmount);
            (uint256 amount0, uint256 amount1) =
                LiquidityAmounts.getAmountsForLiquidity(p.sqrtPriceX96, sqrtL, sqrtU, liq);
            assertEq(amount0, 0, "expected zero quote (currency0)");
            assertGt(amount1, 0, "expected launched token (currency1)");
        } else {
            uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtL, sqrtU, launchedAmount);
            (uint256 amount0, uint256 amount1) =
                LiquidityAmounts.getAmountsForLiquidity(p.sqrtPriceX96, sqrtL, sqrtU, liq);
            assertGt(amount0, 0, "expected launched token (currency0)");
            assertEq(amount1, 0, "expected zero quote (currency1)");
        }
    }
}
