// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "../lib/v4-core/test/utils/LiquidityAmounts.sol";

import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopLaunchMath} from "../src/libraries/ScoopLaunchMath.sol";

/// @dev Local harness (avoid importing unit-test file).
contract ScoopLaunchMathForkHarness {
    function calculateLaunchPricing(
        address launchedToken,
        address quoteAsset,
        uint8 quoteDecimals,
        uint256 quotePriceUsd
    ) external pure returns (ScoopLaunchMath.LaunchPricing memory) {
        return ScoopLaunchMath.calculateLaunchPricing(launchedToken, quoteAsset, quoteDecimals, quotePriceUsd);
    }
}

/**
 * @notice Live ScoopPriceOracle → ScoopLaunchMath proof on Robinhood fork.
 * @dev Does NOT create pools or modify ScoopFactory.
 */
contract ScoopLaunchMathForkTest is Test {
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    uint48 constant TEST_MAX_AGE = 7 days;
    uint256 constant FDV_REL_TOL = 1e15;

    ScoopPriceOracle oracle;
    ScoopLaunchMathForkHarness math;
    address authority;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        authority = makeAddr("oracleAuthority");
        oracle = new ScoopPriceOracle(authority);
        math = new ScoopLaunchMathForkHarness();

        vm.startPrank(authority);
        oracle.configureFeed(address(0), ETH_USD_FEED, TEST_MAX_AGE);
        oracle.configureFeed(AAPL_TOKEN, AAPL_USD_FEED, TEST_MAX_AGE);
        vm.stopPrank();
    }

    function test_liveEth_oracleToLaunchMath() public view {
        uint256 ethUsd = oracle.getPriceUsd(address(0));
        address token = address(0xBEEF);

        ScoopLaunchMath.LaunchPricing memory p = math.calculateLaunchPricing(token, address(0), 18, ethUsd);
        assertTrue(p.launchedIsCurrency1);
        assertGe(p.sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        assertLt(p.sqrtPriceX96, TickMath.MAX_SQRT_PRICE);

        (, uint256 fdv) = _reconstruct(p, 18, ethUsd);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        _assertOneSided(p);

        console2.log("live ETH USD", ethUsd);
        console2.log("ETH sqrtPriceX96", p.sqrtPriceX96);
        console2.logInt(p.openingTick);
        console2.logInt(p.tickLower);
        console2.logInt(p.tickUpper);
        console2.log("reconstructed FDV", fdv);
    }

    function test_liveAapl_bothOrientations() public view {
        uint256 aaplUsd = oracle.getPriceUsd(AAPL_TOKEN);
        address tokenHi = address(uint160(uint256(uint160(AAPL_TOKEN)) + 1));
        address tokenLo = address(uint160(uint256(uint160(AAPL_TOKEN)) - 1));

        ScoopLaunchMath.LaunchPricing memory pHi = math.calculateLaunchPricing(tokenHi, AAPL_TOKEN, 18, aaplUsd);
        ScoopLaunchMath.LaunchPricing memory pLo = math.calculateLaunchPricing(tokenLo, AAPL_TOKEN, 18, aaplUsd);

        assertTrue(pHi.launchedIsCurrency1);
        assertFalse(pLo.launchedIsCurrency1);

        (, uint256 fdvHi) = _reconstruct(pHi, 18, aaplUsd);
        (, uint256 fdvLo) = _reconstruct(pLo, 18, aaplUsd);
        assertApproxEqRel(fdvHi, 5_000e18, FDV_REL_TOL);
        assertApproxEqRel(fdvLo, 5_000e18, FDV_REL_TOL);
        assertApproxEqRel(fdvHi, fdvLo, FDV_REL_TOL);
        _assertOneSided(pHi);
        _assertOneSided(pLo);

        console2.log("live AAPL USD", aaplUsd);
        console2.log("AAPL c0 sqrt", pHi.sqrtPriceX96);
        console2.log("AAPL c1 sqrt", pLo.sqrtPriceX96);
        console2.log("FDV c0", fdvHi);
        console2.log("FDV c1", fdvLo);
    }

    function _reconstruct(ScoopLaunchMath.LaunchPricing memory p, uint8 quoteDecimals, uint256 quotePriceUsd)
        internal
        pure
        returns (uint256 tokenUsd, uint256 fdvUsd)
    {
        uint256 tokenUnits = 10 ** uint256(ScoopLaunchMath.TOKEN_DECIMALS);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        uint256 quoteRawPerWholeToken = p.launchedIsCurrency1
            ? _mulDivInversePrice(tokenUnits, p.sqrtPriceX96)
            : _mulDivPrice(tokenUnits, p.sqrtPriceX96);
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

    function _assertOneSided(ScoopLaunchMath.LaunchPricing memory p) internal pure {
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(p.tickUpper);
        if (p.launchedIsCurrency1) {
            uint128 liq = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtU, ScoopLaunchMath.TOKEN_SUPPLY);
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(p.sqrtPriceX96, sqrtL, sqrtU, liq);
            assertEq(a0, 0);
            assertGt(a1, 0);
        } else {
            uint128 liq = LiquidityAmounts.getLiquidityForAmount0(sqrtL, sqrtU, ScoopLaunchMath.TOKEN_SUPPLY);
            (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(p.sqrtPriceX96, sqrtL, sqrtU, liq);
            assertEq(a1, 0);
            assertGt(a0, 0);
        }
    }
}
