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

    int24 constant SPACING = 10;
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
        assertEq(ScoopLaunchMath.TICK_SPACING, 10);
        assertEq(math.tokenUsdPrice(), 5e12);

        assertEq(uint256(5e12) * uint256(1_000_000_000), uint256(5_000e18));
        assertEq(
            FullMath.mulDiv(
                ScoopLaunchMath.TARGET_FDV_USD,
                10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS),
                ScoopLaunchMath.TOKEN_SUPPLY
            ),
            uint256(5e12)
        );
        assertEq(int256(TickMath.minUsableTick(SPACING)), -887_270);
        assertEq(int256(TickMath.maxUsableTick(SPACING)), 887_270);
    }

    // ─── Tick alignment ──────────────────────────────────────────────────────

    function test_floorToSpacing_examples() public view {
        int24 s = SPACING;
        assertEq(int256(math.floorToSpacing(21, s)), int256(20));
        assertEq(int256(math.floorToSpacing(20, s)), int256(20));
        assertEq(int256(math.floorToSpacing(19, s)), int256(10));
        assertEq(int256(math.floorToSpacing(-1, s)), int256(-10));
        assertEq(int256(math.floorToSpacing(-9, s)), int256(-10));
        assertEq(int256(math.floorToSpacing(-10, s)), int256(-10));
        assertEq(int256(math.floorToSpacing(-11, s)), int256(-20));
    }

    function test_ceilToSpacing_examples() public view {
        int24 s = SPACING;
        assertEq(int256(math.ceilToSpacing(21, s)), int256(30));
        assertEq(int256(math.ceilToSpacing(20, s)), int256(20));
        assertEq(int256(math.ceilToSpacing(19, s)), int256(20));
        assertEq(int256(math.ceilToSpacing(-1, s)), int256(0));
        assertEq(int256(math.ceilToSpacing(-9, s)), int256(0));
        assertEq(int256(math.ceilToSpacing(-10, s)), int256(-10));
        assertEq(int256(math.ceilToSpacing(-11, s)), int256(-10));
    }

    function test_currency1_maxRange_openingAligned() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(69_500, true);
        assertEq(int256(lo), int256(TickMath.minUsableTick(SPACING)));
        assertEq(int256(hi), 69_500);
        assertGt(int256(hi - lo), int256(SPACING));
    }

    function test_currency1_maxRange_openingNotAligned() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(69_503, true);
        assertEq(int256(lo), int256(TickMath.minUsableTick(SPACING)));
        assertEq(int256(hi), 69_500); // floorToSpacing(69503)
        assertTrue(hi <= 69_503);
    }

    function test_currency0_maxRange_openingAligned() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(69_500, false);
        assertEq(int256(lo), 69_510); // ceil(69501) with spacing 10
        assertEq(int256(hi), int256(TickMath.maxUsableTick(SPACING)));
        assertTrue(lo > 69_500);
    }

    function test_currency0_maxRange_openingNotAligned() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(69_503, false);
        assertEq(int256(lo), 69_510); // ceil(69504)
        assertEq(int256(hi), int256(TickMath.maxUsableTick(SPACING)));
        assertTrue(lo > 69_503);
    }

    function test_tick0_currency1_maxRange() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(0, true);
        assertEq(int256(lo), int256(TickMath.minUsableTick(SPACING)));
        assertEq(int256(hi), 0);
    }

    function test_tick0_currency0_maxRange() public view {
        (int24 lo, int24 hi) = math.oneSidedLpTicks(0, false);
        assertEq(int256(lo), 10);
        assertEq(int256(hi), int256(TickMath.maxUsableTick(SPACING)));
    }

    // ─── ETH ─────────────────────────────────────────────────────────────────

    function test_eth_openingPriceAndMaxRangeLp() public view {
        address token = address(0xBEEF);
        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, address(0), 18, ETH_USD);

        assertTrue(p.launchedIsCurrency1);
        assertGe(p.sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        assertLt(p.sqrtPriceX96, TickMath.MAX_SQRT_PRICE);

        // sqrt is NOT quantized: round-trip tick from stored sqrt matches openingTick,
        // but LP upper is spacing-aligned and may equal opening when already aligned.
        assertEq(int256(TickMath.getTickAtSqrtPrice(p.sqrtPriceX96)), int256(p.openingTick));
        assertEq(
            p.sqrtPriceX96, math.encodeSqrtRatioX96(FullMath.mulDiv(ETH_USD, 1e18, 1), FullMath.mulDiv(5e12, 1e18, 1))
        );

        assertEq(int256(p.tickLower), int256(TickMath.minUsableTick(SPACING)));
        assertEq(int256(p.tickUpper), int256(math.floorToSpacing(p.openingTick, SPACING)));
        assertTrue(p.tickUpper <= p.openingTick);
        assertGt(int256(p.tickUpper - p.tickLower), int256(SPACING));
        assertEq(int256(p.tickLower % SPACING), 0);
        assertEq(int256(p.tickUpper % SPACING), 0);

        (uint256 tokenUsd, uint256 fdv) = _reconstruct(p, 18, ETH_USD);
        assertApproxEqRel(tokenUsd, 5e12, FDV_REL_TOL);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);

        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);

        console2.log("ETH sqrtPriceX96", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("ETH width", uint256(int256(p.tickUpper - p.tickLower)));
        console2.log("ETH tokenUsd", tokenUsd);
        console2.log("ETH FDV", fdv);
        console2.log("ETH FDV error abs", fdv > 5_000e18 ? fdv - 5_000e18 : 5_000e18 - fdv);
    }

    // ─── AAPL both orientations ──────────────────────────────────────────────

    function test_aapl_quoteAsCurrency0() public view {
        address token = address(uint160(uint256(uint160(AAPL)) + 1));
        assertTrue(token > AAPL);

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, AAPL, 18, AAPL_USD);
        assertTrue(p.launchedIsCurrency1);
        assertEq(int256(p.tickLower), int256(TickMath.minUsableTick(SPACING)));
        assertTrue(p.tickUpper <= p.openingTick);

        (uint256 tokenUsd, uint256 fdv) = _reconstruct(p, 18, AAPL_USD);
        assertApproxEqRel(tokenUsd, 5e12, FDV_REL_TOL);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);

        console2.log("AAPL c1-token sqrt", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("AAPL c1 FDV", fdv);
    }

    function test_aapl_quoteAsCurrency1() public view {
        address token = address(uint160(uint256(uint160(AAPL)) - 1));
        assertTrue(token != address(0));
        assertTrue(token < AAPL);

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, AAPL, 18, AAPL_USD);
        assertFalse(p.launchedIsCurrency1);
        assertEq(int256(p.tickUpper), int256(TickMath.maxUsableTick(SPACING)));
        assertTrue(p.tickLower > p.openingTick);

        (uint256 tokenUsd, uint256 fdv) = _reconstruct(p, 18, AAPL_USD);
        assertApproxEqRel(tokenUsd, 5e12, FDV_REL_TOL);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);

        console2.log("AAPL c0-token sqrt", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("AAPL c0 FDV", fdv);
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

    // ─── Old vs new comparison (informational) ───────────────────────────────

    function test_oldVsNew_rangeComparison() public view {
        // OLD production geometry (spacing 200, width 200) vs NEW max-range spacing 10.
        int24 opening = 200_130; // representative ETH-region opening from prior forks
        int24 oldSpacing = 200;
        int24 oldUpper = ScoopLaunchMath.floorToSpacing(opening - 1, oldSpacing);
        int24 oldLower = oldUpper - oldSpacing;
        int24 oldWidth = oldUpper - oldLower;

        (int24 newLower, int24 newUpper) = math.oneSidedLpTicks(opening, true);
        int24 newWidth = newUpper - newLower;

        // Raw price multiples ≈ 1.0001^width (log comparison via integer proxy).
        console2.log("OLD width", uint256(int256(oldWidth)));
        console2.log("NEW width", uint256(int256(newWidth)));
        console2.log("OLD raw multiple ~ 1.0001^width (approx log10)", _log10PriceMultiple(oldWidth));
        console2.log("NEW raw multiple ~ 1.0001^width (approx log10)", _log10PriceMultiple(newWidth));

        assertEq(int256(oldWidth), 200);
        assertGt(int256(newWidth), int256(oldWidth) * 4_000);
        assertEq(int256(newLower), int256(TickMath.minUsableTick(SPACING)));
    }

    // ─── Quote decimals ──────────────────────────────────────────────────────

    function test_quoteDecimals_6_8_18() public view {
        address token = address(0xBEEF);
        address quote = address(0x1);
        uint256 quoteUsd = 100e18;

        ScoopLaunchMath.LaunchPricing memory p18 = math.calculateLaunchPricing(token, quote, 18, quoteUsd);
        (, uint256 fdv18) = _reconstruct(p18, 18, quoteUsd);
        assertApproxEqRel(fdv18, 5_000e18, FDV_REL_TOL);

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
        assertEq(int256(p.tickLower), int256(TickMath.minUsableTick(SPACING)));
        assertTrue(p.tickUpper <= p.openingTick);
        assertGt(int256(p.tickUpper - p.tickLower), int256(SPACING));
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
        _assertOneSided(p, 1_000_000 ether);
    }

    function testFuzz_addressOrientation(address launched, address quote, uint256 quoteUsd) public view {
        vm.assume(launched != quote);
        vm.assume(launched != address(0) || quote != address(0));
        if (quote == address(0)) vm.assume(launched != address(0));
        if (launched == address(0)) vm.assume(quote != address(0));

        quoteUsd = bound(quoteUsd, 1e18, 100_000e18);

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(launched, quote, 18, quoteUsd);
        bool expectC1 = uint160(launched) > uint160(quote);
        assertTrue(p.launchedIsCurrency1 == expectC1);

        if (expectC1) {
            assertEq(int256(p.tickLower), int256(TickMath.minUsableTick(SPACING)));
            assertTrue(p.tickUpper <= p.openingTick);
        } else {
            assertEq(int256(p.tickUpper), int256(TickMath.maxUsableTick(SPACING)));
            assertTrue(p.tickLower > p.openingTick);
        }
        assertEq(int256(p.tickLower % SPACING), 0);
        assertEq(int256(p.tickUpper % SPACING), 0);
        assertGt(int256(p.tickUpper - p.tickLower), int256(SPACING));

        (, uint256 fdv) = _reconstruct(p, 18, quoteUsd);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p, ScoopLaunchMath.TOKEN_SUPPLY);
    }

    function testFuzz_tickAlignment(int24 openingTick) public view {
        int24 minU = TickMath.minUsableTick(SPACING);
        int24 maxU = TickMath.maxUsableTick(SPACING);
        // Leave headroom so max-range bounds are non-empty for both orientations.
        openingTick = int24(bound(int256(openingTick), int256(minU + SPACING), int256(maxU - SPACING - 1)));

        (int24 lo1, int24 hi1) = math.oneSidedLpTicks(openingTick, true);
        (int24 lo0, int24 hi0) = math.oneSidedLpTicks(openingTick, false);

        assertEq(int256(lo1), int256(minU));
        assertEq(int256(hi1), int256(math.floorToSpacing(openingTick, SPACING)));
        assertEq(int256(hi0), int256(maxU));
        assertEq(int256(lo0), int256(math.ceilToSpacing(openingTick + 1, SPACING)));
        assertEq(int256(lo1 % SPACING), 0);
        assertEq(int256(hi1 % SPACING), 0);
        assertEq(int256(lo0 % SPACING), 0);
        assertEq(int256(hi0 % SPACING), 0);
        assertTrue(hi1 <= openingTick);
        assertTrue(lo0 > openingTick);
        assertGe(int256(hi1 - lo1), int256(SPACING));
        assertGe(int256(hi0 - lo0), int256(SPACING));
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

    /// @dev Approximate log10(1.0001^width) = width * log10(1.0001) ≈ width * 4.3429448e-5
    function _log10PriceMultiple(int24 width) internal pure returns (uint256) {
        // Return scaled 1e6: width * 43429 / 1e9 * 1e6 ≈ width * 43429 / 1000
        uint256 w = uint256(int256(width));
        return (w * 43429) / 1000;
    }

    function _reconstruct(ScoopLaunchMath.LaunchPricing memory p, uint8 quoteDecimals, uint256 quotePriceUsd)
        internal
        pure
        returns (uint256 tokenUsd, uint256 fdvUsd)
    {
        uint256 tokenUnits = 10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);

        uint256 quoteRawPerWholeToken;
        if (p.launchedIsCurrency1) {
            quoteRawPerWholeToken = _mulDivInversePrice(tokenUnits, p.sqrtPriceX96);
        } else {
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
