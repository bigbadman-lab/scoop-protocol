// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {ScoopLaunchMath} from "../../src/libraries/ScoopLaunchMath.sol";

/**
 * @title ScoopLiquidityCurveHelpers
 * @notice ANALYSIS-ONLY helpers for Milestone 4I liquidity-curve study.
 * @dev Not production code. Does not modify ScoopLaunchMath; reuses its opening-price math
 *      and provides candidate one-sided ranges of arbitrary spacing-aligned width.
 */
library ScoopLiquidityCurveHelpers {
    /// @dev Matches production ScoopLaunchMath.TICK_SPACING after Milestone 4I.2.
    int24 internal constant SPACING = 10;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant TARGET_FDV = 5_000e18;

    error WidthNotAligned(int24 width);
    error RangeNotOneSided();
    error RangeOutOfBounds();

    struct CandidateRange {
        int24 openingTick;
        int24 tickLower;
        int24 tickUpper;
        int24 width;
        bool launchedIsCurrency1;
        bool oneSidedAtOpening;
    }

    /// @dev Same floor semantics as ScoopLaunchMath (toward -∞).
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @dev Same ceil semantics as ScoopLaunchMath (toward +∞).
    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed++;
        return compressed * spacing;
    }

    function minUsableTick() internal pure returns (int24) {
        return TickMath.minUsableTick(SPACING);
    }

    function maxUsableTick() internal pure returns (int24) {
        return TickMath.maxUsableTick(SPACING);
    }

    /**
     * @notice One-sided candidate range of `width` ticks (must be multiple of SPACING).
     * @dev Width is distance tickUpper - tickLower. Production uses max-practical width.
     */
    function candidateOneSidedRange(int24 openingTick, bool launchedIsCurrency1, int24 width)
        internal
        pure
        returns (CandidateRange memory r)
    {
        if (width <= 0 || width % SPACING != 0) revert WidthNotAligned(width);

        r.openingTick = openingTick;
        r.width = width;
        r.launchedIsCurrency1 = launchedIsCurrency1;

        if (launchedIsCurrency1) {
            // Match production opening-side: floor(opening); then extend `width` downward.
            r.tickUpper = floorToSpacing(openingTick, SPACING);
            r.tickLower = r.tickUpper - width;
            r.oneSidedAtOpening = openingTick >= r.tickUpper;
        } else {
            r.tickLower = ceilToSpacing(openingTick + 1, SPACING);
            r.tickUpper = r.tickLower + width;
            r.oneSidedAtOpening = openingTick < r.tickLower;
        }

        if (!r.oneSidedAtOpening) revert RangeNotOneSided();
        if (r.tickLower < minUsableTick() || r.tickUpper > maxUsableTick()) revert RangeOutOfBounds();
        if (r.tickLower >= r.tickUpper) revert RangeOutOfBounds();
    }

    /// @notice Widest spacing-aligned one-sided range (production ScoopLaunchMath geometry).
    function maxPracticalOneSidedRange(int24 openingTick, bool launchedIsCurrency1)
        internal
        pure
        returns (CandidateRange memory r)
    {
        if (launchedIsCurrency1) {
            r.tickUpper = floorToSpacing(openingTick, SPACING);
            r.tickLower = minUsableTick();
        } else {
            r.tickLower = ceilToSpacing(openingTick + 1, SPACING);
            r.tickUpper = maxUsableTick();
        }
        r.openingTick = openingTick;
        r.width = r.tickUpper - r.tickLower;
        r.launchedIsCurrency1 = launchedIsCurrency1;
        r.oneSidedAtOpening = launchedIsCurrency1 ? (openingTick >= r.tickUpper) : (openingTick < r.tickLower);
        if (!r.oneSidedAtOpening) revert RangeNotOneSided();
        if (r.tickLower >= r.tickUpper) revert RangeOutOfBounds();
    }

    /// @notice True full-range [minUsable, maxUsable] always contains openingTick → not one-sided.
    function fullRangeContainsOpening(int24 openingTick) internal pure returns (bool) {
        return openingTick > minUsableTick() && openingTick < maxUsableTick();
    }

    function reconstructTokenUsd(uint160 sqrtPriceX96, bool launchedIsCurrency1, uint8 quoteDecimals, uint256 quoteUsd)
        internal
        pure
        returns (uint256 tokenUsd)
    {
        uint256 tokenUnits = 1e18;
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        uint256 quoteRaw = launchedIsCurrency1
            ? _mulDivInversePrice(tokenUnits, sqrtPriceX96)
            : _mulDivPrice(tokenUnits, sqrtPriceX96);
        uint256 quotePerToken1e18 = FullMath.mulDiv(quoteRaw, 1e18, quoteScale);
        tokenUsd = FullMath.mulDiv(quotePerToken1e18, quoteUsd, 1e18);
    }

    function reconstructFdv(uint160 sqrtPriceX96, bool launchedIsCurrency1, uint8 quoteDecimals, uint256 quoteUsd)
        internal
        pure
        returns (uint256 fdv)
    {
        fdv = reconstructTokenUsd(sqrtPriceX96, launchedIsCurrency1, quoteDecimals, quoteUsd) * 1_000_000_000;
    }

    function fdvAtTick(int24 tick, bool launchedIsCurrency1, uint8 quoteDecimals, uint256 quoteUsd)
        internal
        pure
        returns (uint256)
    {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        return reconstructFdv(sqrtP, launchedIsCurrency1, quoteDecimals, quoteUsd);
    }

    /// @notice Boundary tick where one-sided liquidity ends (exhaustion).
    function exhaustionTick(CandidateRange memory r) internal pure returns (int24) {
        return r.launchedIsCurrency1 ? r.tickLower : r.tickUpper;
    }

    /// @notice Max spot FDV while still inside active candidate liquidity (at the inner boundary).
    function maxFdvInsideRange(CandidateRange memory r, uint8 quoteDecimals, uint256 quoteUsd)
        internal
        pure
        returns (uint256)
    {
        // For c1 (range below): buying drives price down → FDV falls below $5k (token cheaper).
        // SCOOP buy pressure sells launched token for quote → token price RISES in quote terms when
        // quote is c0? Wait:
        //   zeroForOne: sell c0 (quote/ETH), buy c1 (token) → sqrtPrice decreases.
        //   price = amount1/amount0 = token/ETH decreases → more tokens per ETH → token CHEAPER in ETH.
        //
        // That can't be right for a buy of tokens... If you buy tokens with ETH, token price in ETH
        // should rise (fewer tokens per ETH).
        //
        // Uniswap: zeroForOne decreases sqrtPrice. If token is c1 and ETH is c0,
        // price = token/ETH. Decreasing price means fewer tokens per ETH = token more expensive in ETH.
        // Yes: price amount1/amount0 falling means token appreciates vs ETH.
        //
        // Opening ~$5k. Buying tokens moves toward tickLower. At lower tick, sqrtPrice is smaller,
        // token/ETH price is smaller numerically = token MORE expensive. FDV RISES as we go down ticks
        // when quote is c0 and token is c1.
        //
        // Verify with numbers from 4G: opening 200130, after buy 199904 — tick decreased.
        // FDV after buy should be higher than $5k.
        //
        // Exhaustion at tickLower → MAXIMUM FDV for the buy direction.
        // For c0 launched (range above): buy increases tick → exhaustion at tickUpper → max FDV.
        return fdvAtTick(exhaustionTick(r), r.launchedIsCurrency1, quoteDecimals, quoteUsd);
    }

    function openingPricing(address token, address quote, uint8 quoteDecimals, uint256 quoteUsd)
        internal
        pure
        returns (ScoopLaunchMath.LaunchPricing memory)
    {
        return ScoopLaunchMath.calculateLaunchPricing(token, quote, quoteDecimals, quoteUsd);
    }

    function _mulDivPrice(uint256 amount, uint160 sqrtP) private pure returns (uint256) {
        uint256 a = FullMath.mulDiv(amount, sqrtP, FixedPoint96.Q96);
        return FullMath.mulDiv(a, sqrtP, FixedPoint96.Q96);
    }

    function _mulDivInversePrice(uint256 amount, uint160 sqrtP) private pure returns (uint256) {
        uint256 a = FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtP);
        return FullMath.mulDiv(a, FixedPoint96.Q96, sqrtP);
    }
}
