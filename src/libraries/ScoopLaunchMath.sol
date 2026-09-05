// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/**
 * @title ScoopLaunchMath
 * @notice Pure pricing mathematics for SCOOP V1 $5,000 FDV launches on Uniswap v4.
 * @dev No storage, authority, oracle reads, or Factory coupling. Callers supply
 *      `quotePriceUsd` (typically from ScoopPriceOracle, 1e18 = $1.00).
 *
 *      Unit derivation (canonical):
 *      - Economic supply = 1_000_000_000 whole tokens
 *      - ERC20 `TOKEN_SUPPLY` = 1_000_000_000e18 base units
 *      - `TARGET_FDV_USD` = 5_000e18
 *      - Target launched-token USD price =
 *          TARGET_FDV_USD * 10^TOKEN_DECIMALS / TOKEN_SUPPLY
 *        = 5_000e18 * 1e18 / 1_000_000_000e18
 *        = 5e12
 *        i.e. $0.000005 at 1e18 USD precision
 *
 *      Quote-per-token (whole quote units, 1e18 precision) =
 *          TOKEN_USD_PRICE * 1e18 / quotePriceUsd
 *
 *      Raw Uniswap price amount1/amount0 depends on currency ordering:
 *      - quote = currency0, launched = currency1:
 *          price = quotePriceUsd * 10^tokenDecimals / (TOKEN_USD_PRICE * 10^quoteDecimals)
 *      - launched = currency0, quote = currency1:
 *          price = TOKEN_USD_PRICE * 10^quoteDecimals / (quotePriceUsd * 10^tokenDecimals)
 *
 *      sqrtPriceX96 = sqrt(amount1/amount0) * 2^96 via FullMath + integer sqrt.
 *      The pool initializes at this exact oracle-derived sqrt — it is NOT quantized to a tick.
 *
 *      One-sided max-range LP (PAR-aligned geometry; SCOOP economics unchanged):
 *      Always provide ONLY the launched token (quote principal = 0).
 *      - launched = currency1 → [minUsableTick(spacing), floorToSpacing(openingTick)]
 *        LiquidityAmounts amount1-only when sqrtPrice >= sqrt(tickUpper).
 *      - launched = currency0 → [ceilToSpacing(openingTick + 1), maxUsableTick(spacing)]
 *        LiquidityAmounts amount0-only when sqrtPrice <= sqrt(tickLower).
 *      Tick spacing = 10 (matches live PAR / Robinhood Uniswap v4 launches).
 *
 *      Stock Token uiMultiplier is NOT applied here — quotePriceUsd from ScoopPriceOracle
 *      is already the correct per-token USD for Robinhood equity feeds.
 */
library ScoopLaunchMath {
    uint256 internal constant TARGET_FDV_USD = 5_000e18;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000_000 ether;
    uint8 internal constant TOKEN_DECIMALS = 18;
    /// @dev TARGET_FDV_USD * 10^TOKEN_DECIMALS / TOKEN_SUPPLY = $0.000005 at 1e18
    uint256 internal constant TOKEN_USD_PRICE = 5e12;
    int24 internal constant TICK_SPACING = 10;

    error ZeroQuotePrice();
    error IdenticalCurrencies();
    error UnsupportedTokenDecimals(uint8 decimals);
    error PriceOutOfRange();
    error TickRangeOutOfBounds();
    error ZeroAmountRatio();

    struct LaunchPricing {
        uint160 sqrtPriceX96;
        int24 openingTick;
        int24 tickLower;
        int24 tickUpper;
        bool launchedIsCurrency1;
    }

    /**
     * @notice Compute opening sqrtPriceX96, tick, and one-sided max-range LP for a $5k FDV launch.
     * @param launchedToken Address of the new ScoopToken (non-zero).
     * @param quoteAsset Quote asset; `address(0)` = native ETH.
     * @param quoteDecimals ERC20/native decimals of the quote asset (0..18).
     * @param quotePriceUsd USD price of one whole quote unit, 1e18 = $1 (from ScoopPriceOracle).
     */
    function calculateLaunchPricing(
        address launchedToken,
        address quoteAsset,
        uint8 quoteDecimals,
        uint256 quotePriceUsd
    ) internal pure returns (LaunchPricing memory result) {
        if (quotePriceUsd == 0) revert ZeroQuotePrice();
        if (launchedToken == quoteAsset) revert IdenticalCurrencies();
        if (quoteDecimals > 18) revert UnsupportedTokenDecimals(quoteDecimals);

        bool launchedIsCurrency1 = uint160(launchedToken) > uint160(quoteAsset);
        result.launchedIsCurrency1 = launchedIsCurrency1;

        result.sqrtPriceX96 = _encodeOpeningSqrtPriceX96(launchedIsCurrency1, quoteDecimals, quotePriceUsd);

        if (result.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || result.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }

        result.openingTick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
        (result.tickLower, result.tickUpper) = oneSidedLpTicks(result.openingTick, launchedIsCurrency1);
    }

    /// @notice Opening sqrtPriceX96 only (same inputs as calculateLaunchPricing).
    function calculateOpeningSqrtPriceX96(
        address launchedToken,
        address quoteAsset,
        uint8 quoteDecimals,
        uint256 quotePriceUsd
    ) internal pure returns (uint160 sqrtPriceX96) {
        return calculateLaunchPricing(launchedToken, quoteAsset, quoteDecimals, quotePriceUsd).sqrtPriceX96;
    }

    /**
     * @notice Max-range one-sided LP bounds on the launched-token side of `openingTick`.
     * @dev Currency1: tickLower = minUsableTick; tickUpper = floorToSpacing(openingTick)
     *         (largest spacing-aligned boundary <= openingTick; amount1-only at init).
     *      Currency0: tickLower = ceilToSpacing(openingTick + 1); tickUpper = maxUsableTick
     *         (smallest spacing-aligned boundary strictly above openingTick; amount0-only at init).
     *      Opening-side alignment only — sqrtPriceX96 itself is never quantized here.
     */
    function oneSidedLpTicks(int24 openingTick, bool launchedIsCurrency1)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 spacing = TICK_SPACING;
        int24 minU = TickMath.minUsableTick(spacing);
        int24 maxU = TickMath.maxUsableTick(spacing);

        if (launchedIsCurrency1) {
            tickUpper = floorToSpacing(openingTick, spacing);
            tickLower = minU;
        } else {
            tickLower = ceilToSpacing(openingTick + 1, spacing);
            tickUpper = maxU;
        }

        if (tickLower >= tickUpper) revert TickRangeOutOfBounds();
        if (tickLower % spacing != 0 || tickUpper % spacing != 0) revert TickRangeOutOfBounds();
        if (tickLower < minU || tickUpper > maxU) revert TickRangeOutOfBounds();
        // Must still be one-sided relative to opening (not merely a valid Uniswap range).
        if (launchedIsCurrency1) {
            if (tickUpper > openingTick) revert TickRangeOutOfBounds();
        } else {
            if (tickLower <= openingTick) revert TickRangeOutOfBounds();
        }
    }

    /// @dev Floor tick to a multiple of spacing (toward -∞). Correct for negative ticks.
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        // solc truncates toward zero; adjust when negative and not exact.
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @dev Ceil tick to a multiple of spacing (toward +∞). Correct for negative ticks.
    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }

    /// @notice Canonical target launched-token USD price at 1e18 ($0.000005 → 5e12).
    function tokenUsdPrice() internal pure returns (uint256) {
        return TOKEN_USD_PRICE;
    }

    /// @dev Build sqrtPriceX96 from economic inputs and currency orientation.
    function _encodeOpeningSqrtPriceX96(bool launchedIsCurrency1, uint8 quoteDecimals, uint256 quotePriceUsd)
        private
        pure
        returns (uint160)
    {
        uint256 tokenScale = 10 ** uint256(TOKEN_DECIMALS);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);

        // Raw ratio factors (see NatSpec). Avoid intermediate overflow via FullMath.
        uint256 amount1;
        uint256 amount0;

        if (launchedIsCurrency1) {
            // price = amount1/amount0 = quoteUsd * 10^td / (tokenUsd * 10^qd)
            amount1 = FullMath.mulDiv(quotePriceUsd, tokenScale, 1);
            amount0 = FullMath.mulDiv(TOKEN_USD_PRICE, quoteScale, 1);
        } else {
            // price = amount1/amount0 = tokenUsd * 10^qd / (quoteUsd * 10^td)
            amount1 = FullMath.mulDiv(TOKEN_USD_PRICE, quoteScale, 1);
            amount0 = FullMath.mulDiv(quotePriceUsd, tokenScale, 1);
        }

        if (amount0 == 0 || amount1 == 0) revert ZeroAmountRatio();
        return encodeSqrtRatioX96(amount1, amount0);
    }

    /**
     * @notice sqrt(amount1/amount0) * 2^96 as uint160.
     * @dev Prefer `sqrt(FullMath.mulDiv(amount1, 2^192, amount0))` when the intermediate fits
     *      in uint256 (`amount1/amount0 < 2^63`). Otherwise use
     *      `FullMath.mulDiv(sqrt(amount1), 2^96, sqrt(amount0))` (FullMath-safe; no equal-shift
     *      reduction that can zero the smaller side).
     */
    function encodeSqrtRatioX96(uint256 amount1, uint256 amount0) internal pure returns (uint160 sqrtPriceX96) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmountRatio();

        uint256 root;
        if (amount1 / amount0 < (uint256(1) << 63)) {
            uint256 ratioX192 = FullMath.mulDiv(amount1, uint256(1) << 192, amount0);
            if (ratioX192 == 0) revert PriceOutOfRange();
            root = _sqrt(ratioX192);
        } else {
            uint256 r1 = _sqrt(amount1);
            uint256 r0 = _sqrt(amount0);
            if (r0 == 0) revert PriceOutOfRange();
            root = FullMath.mulDiv(r1, uint256(1) << 96, r0);
        }

        if (root == 0 || root > type(uint160).max) revert PriceOutOfRange();
        sqrtPriceX96 = uint160(root);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }
    }

    /// @dev Babylonian integer square root (floor).
    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) r <<= 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        uint256 r1 = x / r;
        return (r < r1 ? r : r1);
    }
}
