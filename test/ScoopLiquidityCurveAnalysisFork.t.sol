// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../src/ScoopFactoryDeployer.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopLaunchMath} from "../src/libraries/ScoopLaunchMath.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";
import {ScoopLiquidityCurveHelpers} from "./helpers/ScoopLiquidityCurveHelpers.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice ANALYSIS-ONLY Milestone 4I liquidity curve study on Robinhood fork.
 * @dev Does not modify production contracts. All tests must pass (failures are asserted, not expected-fail).
 */
contract ScoopLiquidityCurveAnalysisForkTest is Test {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    uint8 constant CMD_V4_SWAP = 0x10;
    uint48 constant TEST_MAX_AGE = 7 days;
    uint256 constant SUPPLY = 1_000_000_000 ether;

    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopTokenDeployer tokenDeployer;
    ScoopLaunchDeployer launchDeployer;
    ScoopQuoteRegistry quoteRegistry;
    ScoopPriceOracle priceOracle;
    ScoopFactory factory;

    address authority;
    address quoteAuthority;
    address oracleAuthority;
    address buybackVault;
    address operations;
    address deployer;
    address walletCreator;
    address trader;
    bytes32 walletCreatorId;

    uint256 ethUsd;
    uint256 aaplUsd;

    uint256 saltNonce;

    struct BuySample {
        uint256 requested;
        uint256 consumed;
        uint256 unspent;
        uint256 tokensOut;
        int24 openingTick;
        int24 finalTick;
        uint160 openingSqrt;
        uint160 finalSqrt;
        bool reverted;
        uint256 spotFdv;
        int24 tickLower;
        int24 tickUpper;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        authority = makeAddr("verificationAuthority");
        quoteAuthority = makeAddr("quoteAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        deployer = makeAddr("launchDeployer");
        walletCreator = makeAddr("walletCreator");
        trader = makeAddr("trader");

        registry = new ScoopCreatorRegistry(authority);
        tokenDeployer = new ScoopTokenDeployer();
        launchDeployer = new ScoopLaunchDeployer(POSITION_MANAGER_ADDR);
        quoteRegistry = new ScoopQuoteRegistry(quoteAuthority);
        priceOracle = new ScoopPriceOracle(oracleAuthority);

        vm.startPrank(quoteAuthority);
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        quoteRegistry.registerQuote(AAPL_TOKEN, ScoopQuoteRegistry.QuoteType.Stock);
        vm.stopPrank();

        vm.startPrank(oracleAuthority);
        priceOracle.configureFeed(address(0), ETH_USD_FEED, TEST_MAX_AGE);
        priceOracle.configureFeed(AAPL_TOKEN, AAPL_USD_FEED, TEST_MAX_AGE);
        vm.stopPrank();

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(registry),
            POOL_MANAGER_ADDR,
            POSITION_MANAGER_ADDR,
            PERMIT2_ADDR,
            UNIVERSAL_ROUTER_ADDR,
            address(tokenDeployer),
            address(launchDeployer),
            address(quoteRegistry),
            address(priceOracle),
            buybackVault,
            operations
        );
        factory = protocol.factory();
        rewards = protocol.creatorRewards();
        walletCreatorId = registry.walletCreatorId(walletCreator);

        ethUsd = priceOracle.getPriceUsd(address(0));
        aaplUsd = priceOracle.getPriceUsd(AAPL_TOKEN);

        vm.deal(deployer, 500 ether);
        vm.deal(trader, 500 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PART A/B — Max-range ETH Factory curve (post-4I.2)
    // ═════════════════════════════════════════════════════════════════════════

    function test_partA_eth200TickBuyLadder() public {
        console2.log("=== PART A: ETH max-range Factory ladder ===");
        console2.log("ETH/USD", ethUsd);

        uint256[13] memory sizes = [
            uint256(0.001 ether),
            0.005 ether,
            0.01 ether,
            0.025 ether,
            0.05 ether,
            0.1 ether,
            0.25 ether,
            0.5 ether,
            1 ether,
            2 ether,
            5 ether,
            10 ether,
            20 ether
        ];

        for (uint256 i; i < sizes.length; ++i) {
            BuySample memory s = _sampleEthFactoryBuy(sizes[i]);
            _logBuySample("ETH", s);
            // Test itself always passes; samples may mark reverted=false with unspent>0.
            assertTrue(s.openingTick != 0 || s.openingSqrt != 0);
        }
    }

    function test_partB_ethExhaustionThreshold() public {
        console2.log("=== PART B: ETH max-range - no LP-bound walk-off in 0.5-20 ETH ===");
        // Pre-4I.2 width-200 exhausted near ~2 ETH. Max-range must keep these sizes in-band.
        uint256[5] memory sizes = [uint256(0.5 ether), 1 ether, 5 ether, 10 ether, 20 ether];
        uint256 largestOk;
        for (uint256 i; i < sizes.length; ++i) {
            BuySample memory s = _sampleEthFactoryBuy(sizes[i]);
            console2.log("size", sizes[i]);
            console2.log("tokensOut", s.tokensOut);
            console2.log("unspent", s.unspent);
            console2.logInt(s.finalTick);
            console2.logInt(s.tickLower);
            if (s.tokensOut > 0) {
                largestOk = sizes[i];
                assertFalse(_isRangeBoundaryExhausted(s));
                assertGe(s.finalTick, s.tickLower);
            }
        }
        assertGe(largestOk, 5 ether);
    }

    function test_partB_ethFiveEtherMechanism() public {
        console2.log("=== PART B: 5 ETH mechanism detail (max-range) ===");
        uint256 urBefore = UNIVERSAL_ROUTER_ADDR.balance;
        uint256 factoryBefore = address(factory).balance;
        uint256 buyerBefore = trader.balance;

        BuySample memory s = _sampleEthFactoryBuyFrom(trader, 5 ether);

        console2.log("requested", s.requested);
        console2.log("consumed", s.consumed);
        console2.log("unspent(buyer-level)", s.unspent);
        console2.log("tokensOut", s.tokensOut);
        console2.log("pctSupply1e4", (s.tokensOut * 10_000) / SUPPLY);
        console2.logInt(s.openingTick);
        console2.logInt(s.finalTick);
        console2.logInt(s.tickLower);
        console2.logInt(s.tickUpper);
        console2.log("spotFdv", s.spotFdv);
        console2.log("buyer delta ETH", buyerBefore - trader.balance);
        console2.log("factory ETH delta", address(factory).balance - factoryBefore);
        console2.log("UR ETH delta", UNIVERSAL_ROUTER_ADDR.balance - urBefore);

        assertGt(s.tokensOut, 0);
        assertEq(address(factory).balance, factoryBefore);
        assertGe(s.finalTick, s.tickLower);
        assertFalse(_isRangeBoundaryExhausted(s));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PART C — AAPL max-range
    // ═════════════════════════════════════════════════════════════════════════

    function test_partC_aapl200TickBuyLadder() public {
        console2.log("=== PART C: AAPL max-range Factory ladder (c0 orientation) ===");
        console2.log("AAPL/USD", aaplUsd);

        uint256[8] memory sizes = [uint256(0.01e18), 0.1e18, 0.5e18, 1e18, 2e18, 5e18, 10e18, 20e18];

        for (uint256 i; i < sizes.length; ++i) {
            BuySample memory s = _sampleAaplFactoryBuy(sizes[i], true);
            _logBuySample("AAPL_c0", s);
        }
    }

    function test_partC_aaplExhaustionThreshold() public {
        console2.log("=== PART C: AAPL max-range - no LP-bound walk-off in 1-20 AAPL ===");
        uint256[4] memory sizes = [uint256(1e18), 5e18, 10e18, 20e18];
        uint256 largestOk;
        for (uint256 i; i < sizes.length; ++i) {
            BuySample memory s = _sampleAaplFactoryBuy(sizes[i], true);
            console2.log("AAPL size", sizes[i]);
            console2.log("tokensOut", s.tokensOut);
            console2.log("reverted", s.reverted ? uint256(1) : uint256(0));
            if (s.tokensOut > 0 && !s.reverted) {
                largestOk = sizes[i];
                assertFalse(_isRangeBoundaryExhausted(s));
            }
        }
        assertGt(largestOk, 0);
    }

    function test_partC_aaplBothOrientationsExhaustion() public {
        console2.log("=== PART C: AAPL c1 orientation sample ===");
        BuySample memory ok = _sampleAaplFactoryBuy(0.1e18, false);
        BuySample memory big = _sampleAaplFactoryBuy(1e18, false);
        _logBuySample("AAPL_c1_0.1", ok);
        _logBuySample("AAPL_c1_1.0", big);
        assertGt(ok.tokensOut, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PART D/E/F — Candidate widths + FDV reachability (analytical + spot checks)
    // ═════════════════════════════════════════════════════════════════════════

    function test_partE_candidateMaxFdvMatrix() public {
        console2.log("=== PART E/F: Candidate max FDV matrix (analytical at exhaustion tick) ===");
        // Use a representative predicted token address orientation for ETH (token > 0).
        address fakeTokenEth = address(uint160(uint256(keccak256("eth-orient")) | 1)); // nonzero
        ScoopLaunchMath.LaunchPricing memory ethP =
            ScoopLaunchMath.calculateLaunchPricing(fakeTokenEth, address(0), 18, ethUsd);
        console2.logInt(ethP.openingTick);
        console2.log("ETH launchedIsC1", ethP.launchedIsCurrency1 ? uint256(1) : uint256(0));

        int24[7] memory widths = [int24(200), 1000, 2000, 5000, 10_000, 20_000, 40_000];

        console2.log("--- ETH candidates ---");
        for (uint256 i; i < widths.length; ++i) {
            ScoopLiquidityCurveHelpers.CandidateRange memory r = ScoopLiquidityCurveHelpers.candidateOneSidedRange(
                ethP.openingTick, ethP.launchedIsCurrency1, widths[i]
            );
            uint256 maxFdv = ScoopLiquidityCurveHelpers.maxFdvInsideRange(r, 18, ethUsd);
            console2.log("width", uint256(int256(widths[i])));
            console2.logInt(r.tickLower);
            console2.logInt(r.tickUpper);
            console2.log("maxFdv", maxFdv);
            console2.log("oneSided", r.oneSidedAtOpening ? uint256(1) : uint256(0));
            _logFdvReachability(maxFdv);
            assertTrue(r.oneSidedAtOpening);
            assertEq(uint256(int256(r.tickUpper - r.tickLower)), uint256(int256(widths[i])));
        }

        ScoopLiquidityCurveHelpers.CandidateRange memory maxR =
            ScoopLiquidityCurveHelpers.maxPracticalOneSidedRange(ethP.openingTick, ethP.launchedIsCurrency1);
        uint256 maxPracticalFdv = ScoopLiquidityCurveHelpers.maxFdvInsideRange(maxR, 18, ethUsd);
        console2.log("ETH maxPractical width", uint256(int256(maxR.width)));
        console2.logInt(maxR.tickLower);
        console2.logInt(maxR.tickUpper);
        console2.log("ETH maxPractical maxFdv", maxPracticalFdv);

        assertTrue(ScoopLiquidityCurveHelpers.fullRangeContainsOpening(ethP.openingTick));

        // AAPL c0 / c1 using real AAPL address orientations with synthetic tokens.
        address tokenGt = address(uint160(uint256(uint160(AAPL_TOKEN)) + 1));
        address tokenLt = address(uint160(uint256(uint160(AAPL_TOKEN)) - 1));
        _logAaplCandidateSet("AAPL_c0", tokenGt, true);
        _logAaplCandidateSet("AAPL_c1", tokenLt, false);
    }

    function test_partI_fullRangeOneSidedInfeasible() public {
        address fakeToken = address(uint160(uint256(keccak256("fullrange")) | 1));
        ScoopLaunchMath.LaunchPricing memory p =
            ScoopLaunchMath.calculateLaunchPricing(fakeToken, address(0), 18, ethUsd);

        assertTrue(ScoopLiquidityCurveHelpers.fullRangeContainsOpening(p.openingTick));

        // Attempting a "full range" candidate that includes opening is not one-sided.
        int24 minU = ScoopLiquidityCurveHelpers.minUsableTick();
        int24 maxU = ScoopLiquidityCurveHelpers.maxUsableTick();
        bool openingInside = p.openingTick > minU && p.openingTick < maxU;
        assertTrue(openingInside);

        // Max practical remains one-sided and excludes opening.
        ScoopLiquidityCurveHelpers.CandidateRange memory maxR =
            ScoopLiquidityCurveHelpers.maxPracticalOneSidedRange(p.openingTick, p.launchedIsCurrency1);
        assertTrue(maxR.oneSidedAtOpening);
        if (p.launchedIsCurrency1) {
            assertTrue(p.openingTick >= maxR.tickUpper);
            assertEq(maxR.tickLower, minU);
        } else {
            assertTrue(p.openingTick < maxR.tickLower);
            assertEq(maxR.tickUpper, maxU);
        }
        console2.log("full-range one-sided feasible? 0");
        console2.log("widest practical one-sided width", uint256(int256(maxR.width)));
    }

    function test_partE_candidateSwapSpotCheck_200_vs_2000() public {
        console2.log("=== PART E: fork spot-check width 200 vs 2000 (manual pool) ===");
        // Manual ETH market at production opening price with custom LP width.
        (BuySample memory s200,) = _manualEthBuy(200, 0.1 ether);
        (BuySample memory s2000,) = _manualEthBuy(2000, 0.1 ether);
        _logBuySample("manual_w200_0.1", s200);
        _logBuySample("manual_w2000_0.1", s2000);
        assertGt(s200.tokensOut, 0);
        assertGt(s2000.tokensOut, 0);
        // Wider range → less price impact for same quote → fewer tokens out typically (deeper curve).
        // Not asserting inequality direction strictly (fee/impact nonlinear); just both succeed.
    }

    function test_partH_analyticalMatchesFactoryOpening() public {
        (address token,,,, PoolId poolId) = _factoryLaunchEth();
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        uint256 fdv = ScoopLiquidityCurveHelpers.reconstructFdv(rec.openingSqrtPriceX96, true, 18, ethUsd);
        console2.log("factory opening FDV", fdv);
        assertApproxEqRel(fdv, 5_000e18, 1e15);
        (uint160 live,,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertEq(live, rec.openingSqrtPriceX96);
    }

    function test_partK_feeEstimateOnReachableBuys() public {
        console2.log("=== PART K: fee estimate from Factory ETH buys ===");
        // Rough: 1% LP fee on input; report 70/4/20/6 of that.
        uint256[4] memory sizes = [uint256(0.01 ether), 0.05 ether, 0.1 ether, 0.25 ether];
        for (uint256 i; i < sizes.length; ++i) {
            BuySample memory s = _sampleEthFactoryBuy(sizes[i]);
            if (s.reverted) continue;
            uint256 feeEst = s.consumed / 100; // 1% of consumed quote
            console2.log("consumed", s.consumed);
            console2.log("feeEst", feeEst);
            console2.log("creator70", (feeEst * 70) / 100);
            console2.log("deployer4", (feeEst * 4) / 100);
            console2.log("buyback20", (feeEst * 20) / 100);
            console2.log("ops6", (feeEst * 6) / 100);
            console2.log("spotFdv", s.spotFdv);
        }
    }

    function test_logOracleAndBaselineRanges() public {
        console2.log("=== BASELINE ORACLE / RANGES ===");
        console2.log("ETH/USD", ethUsd);
        console2.log("AAPL/USD", aaplUsd);

        (address ethTok,,,,) = _factoryLaunchEth();
        ScoopFactory.Launch memory ethRec = factory.getLaunch(ethTok);
        console2.logInt(ethRec.openingTick);
        console2.logInt(ethRec.tickLower);
        console2.logInt(ethRec.tickUpper);

        (address a0,,,,) = _factoryLaunchAapl(true);
        ScoopFactory.Launch memory a0Rec = factory.getLaunch(a0);
        console2.logInt(a0Rec.openingTick);
        console2.logInt(a0Rec.tickLower);
        console2.logInt(a0Rec.tickUpper);

        (address a1,,,,) = _factoryLaunchAapl(false);
        ScoopFactory.Launch memory a1Rec = factory.getLaunch(a1);
        console2.logInt(a1Rec.openingTick);
        console2.logInt(a1Rec.tickLower);
        console2.logInt(a1Rec.tickUpper);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════

    function _logBuySample(string memory tag, BuySample memory s) internal pure {
        console2.log(tag);
        console2.log(" requested", s.requested);
        console2.log(" consumed", s.consumed);
        console2.log(" unspent", s.unspent);
        console2.log(" tokensOut", s.tokensOut);
        console2.log(" pct1e4", s.reverted ? 0 : (s.tokensOut * 10_000) / SUPPLY);
        console2.logInt(s.openingTick);
        console2.logInt(s.finalTick);
        console2.log(" spotFdv", s.spotFdv);
        console2.log(" reverted", s.reverted ? uint256(1) : uint256(0));
    }

    function _logFdvReachability(uint256 maxFdv) internal pure {
        uint256[7] memory targets =
            [uint256(10_000e18), 25_000e18, 50_000e18, 100_000e18, 250_000e18, 500_000e18, 1_000_000e18];
        for (uint256 i; i < targets.length; ++i) {
            console2.log(targets[i] / 1e18, maxFdv >= targets[i] ? uint256(1) : uint256(0));
        }
    }

    function _logAaplCandidateSet(string memory tag, address token, bool expectC1) internal view {
        ScoopLaunchMath.LaunchPricing memory p = ScoopLaunchMath.calculateLaunchPricing(token, AAPL_TOKEN, 18, aaplUsd);
        assertEq(p.launchedIsCurrency1, expectC1);
        console2.log(tag);
        console2.logInt(p.openingTick);
        int24[4] memory widths = [int24(200), 2000, 10_000, 40_000];
        for (uint256 i; i < widths.length; ++i) {
            ScoopLiquidityCurveHelpers.CandidateRange memory r =
                ScoopLiquidityCurveHelpers.candidateOneSidedRange(p.openingTick, p.launchedIsCurrency1, widths[i]);
            uint256 maxFdv = ScoopLiquidityCurveHelpers.maxFdvInsideRange(r, 18, aaplUsd);
            console2.log(" width", uint256(int256(widths[i])));
            console2.log(" maxFdv", maxFdv);
            assertTrue(r.oneSidedAtOpening);
        }
    }

    function _isRangeBoundaryExhausted(BuySample memory s) internal pure returns (bool) {
        // Narrow/max LP geometry walk-off — NOT the same as token inventory exhaustion.
        if (s.finalTick < s.tickLower) return true;
        if (s.tickUpper > s.openingTick && s.finalTick > s.tickUpper) return true;
        return false;
    }

    function _isExhausted(BuySample memory s) internal view returns (bool) {
        if (s.reverted) return true;
        if (s.unspent > 0) return true; // native leftover on UR = partial exact-input after liquidity end
        if (_isRangeBoundaryExhausted(s)) return true;
        if (s.finalTick <= ScoopLiquidityCurveHelpers.minUsableTick() + 10) return true;
        if (s.tokensOut + 1000 >= SUPPLY) return true; // dust-only remainder
        return false;
    }

    function _nextSalt() internal returns (bytes32) {
        unchecked {
            ++saltNonce;
        }
        return bytes32(saltNonce + 1000);
    }

    function _factoryLaunchEth()
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId)
    {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Curve",
            symbol: "CRV",
            creatorId: walletCreatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: _nextSalt()
        });
        vm.prank(deployer);
        return factory.launch(params);
    }

    function _factoryLaunchAapl(bool tokenGreater)
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId)
    {
        // Unique user salt is required: launch-component CREATE2 depends on salt, not token name.
        bytes32 salt = _findUnusedAaplSalt(tokenGreater);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "ACurve",
            symbol: "ACR",
            creatorId: walletCreatorId,
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        return factory.launch(params);
    }

    mapping(bytes32 => bool) internal usedSalts;

    function _findUnusedAaplSalt(bool tokenGreater) internal returns (bytes32) {
        bytes32 domain = factory.TOKEN_DOMAIN();
        for (uint256 i = 1; i < 100_000; ++i) {
            bytes32 userSalt = bytes32(i + 77_777);
            if (usedSalts[userSalt]) continue;
            bytes32 launchSalt = keccak256(abi.encode(deployer, userSalt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, domain));
            address predicted = tokenDeployer.predictTokenAddress("ACurve", "ACR", address(factory), tokenSalt);
            bool ok = tokenGreater ? (predicted > AAPL_TOKEN) : (predicted < AAPL_TOKEN && predicted != address(0));
            if (!ok) continue;
            usedSalts[userSalt] = true;
            return userSalt;
        }
        revert("aapl salt not found");
    }

    function _findSaltFor(string memory name, string memory symbol, bool tokenGreater) internal returns (bytes32) {
        bytes32 domain = factory.TOKEN_DOMAIN();
        for (uint256 i = 1; i < 100_000; ++i) {
            bytes32 userSalt = bytes32(i + 88_888 + saltNonce);
            if (usedSalts[userSalt]) continue;
            bytes32 launchSalt = keccak256(abi.encode(deployer, userSalt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, domain));
            address predicted = tokenDeployer.predictTokenAddress(name, symbol, address(factory), tokenSalt);
            bool ok = tokenGreater ? (predicted > AAPL_TOKEN) : (predicted < AAPL_TOKEN && predicted != address(0));
            if (!ok) continue;
            usedSalts[userSalt] = true;
            return userSalt;
        }
        revert("salt not found");
    }

    function _sampleEthFactoryBuy(uint256 amount) internal returns (BuySample memory) {
        return _sampleEthFactoryBuyFrom(trader, amount);
    }

    function _sampleEthFactoryBuyFrom(address buyer, uint256 amount) internal returns (BuySample memory s) {
        (address token,,, uint256 lpId, PoolId poolId) = _factoryLaunchEth();
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        s.openingTick = rec.openingTick;
        s.openingSqrt = rec.openingSqrtPriceX96;
        s.tickLower = rec.tickLower;
        s.tickUpper = rec.tickUpper;
        s.requested = amount;

        uint256 ethBefore = buyer.balance;
        uint256 tokBefore = IERC20(token).balanceOf(buyer);
        uint256 urBefore = UNIVERSAL_ROUTER_ADDR.balance;

        PoolKey memory key = _poolKey(token, address(0));
        bool zeroForOne = true;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeSwap(key, zeroForOne, uint128(amount), 1);

        vm.prank(buyer);
        try IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute{value: amount}(commands, inputs, block.timestamp + 60) {
            s.tokensOut = IERC20(token).balanceOf(buyer) - tokBefore;
            uint256 ethAfter = buyer.balance;
            // Buyer paid `amount` via msg.value; any UR residual is not auto-refunded to buyer.
            uint256 urDelta = UNIVERSAL_ROUTER_ADDR.balance - urBefore;
            s.consumed = amount - urDelta; // ETH left on UR was not settled into the pool
            // If UR refunded to buyer somehow, ethAfter would be ethBefore - consumed.
            // Measure consumed as change in buyer+UR relative to requested.
            if (ethAfter + amount < ethBefore) {
                // should not happen
            }
            // Prefer pool-side accounting: requested - UR leftover (unsettled)
            s.unspent = urDelta;
            if (ethAfter > ethBefore - amount) {
                // buyer received a refund path
                s.unspent = ethAfter - (ethBefore - amount);
                s.consumed = amount - s.unspent;
            }
            (s.finalSqrt, s.finalTick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
            s.spotFdv = ScoopLiquidityCurveHelpers.reconstructFdv(s.finalSqrt, true, 18, ethUsd);
            s.reverted = false;
        } catch {
            s.reverted = true;
            s.consumed = 0;
            s.unspent = amount;
            s.finalTick = s.openingTick;
            s.finalSqrt = s.openingSqrt;
        }
        lpId;
    }

    function _sampleAaplFactoryBuy(uint256 amount, bool tokenGreater) internal returns (BuySample memory s) {
        (address token,,, uint256 lpId, PoolId poolId) = _factoryLaunchAapl(tokenGreater);
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        s.openingTick = rec.openingTick;
        s.openingSqrt = rec.openingSqrtPriceX96;
        s.tickLower = rec.tickLower;
        s.tickUpper = rec.tickUpper;
        s.requested = amount;

        // Use Factory launchAndBuy to exercise production ERC20 exact-spend path.
        // Need a fresh launch for launchAndBuy — above already launched. Do post-launch swap via UR
        // AND separately note Factory launchAndBuy reverts on leftover.
        deal(AAPL_TOKEN, trader, amount);
        vm.startPrank(trader);
        IERC20(AAPL_TOKEN).approve(PERMIT2_ADDR, type(uint256).max);
        IAllowanceTransfer(PERMIT2_ADDR).approve(AAPL_TOKEN, UNIVERSAL_ROUTER_ADDR, type(uint160).max, type(uint48).max);
        vm.stopPrank();

        uint256 aaplBefore = IERC20(AAPL_TOKEN).balanceOf(trader);
        uint256 tokBefore = IERC20(token).balanceOf(trader);

        PoolKey memory key = _poolKey(token, AAPL_TOKEN);
        bool zeroForOne = Currency.unwrap(key.currency0) == AAPL_TOKEN;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeSwap(key, zeroForOne, uint128(amount), 1);

        vm.prank(trader);
        try IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute(commands, inputs, block.timestamp + 60) {
            s.tokensOut = IERC20(token).balanceOf(trader) - tokBefore;
            uint256 aaplAfter = IERC20(AAPL_TOKEN).balanceOf(trader);
            s.consumed = aaplBefore - aaplAfter;
            s.unspent = amount - s.consumed;
            (s.finalSqrt, s.finalTick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
            bool launchedIsC1 = uint160(token) > uint160(AAPL_TOKEN);
            s.spotFdv = ScoopLiquidityCurveHelpers.reconstructFdv(s.finalSqrt, launchedIsC1, 18, aaplUsd);
            s.reverted = false;
        } catch {
            s.reverted = true;
            s.consumed = 0;
            s.unspent = amount;
            s.finalTick = s.openingTick;
            s.finalSqrt = s.openingSqrt;
        }
        lpId;
    }

    function test_partC_factoryLaunchAndBuyExactSpendVsUr() public {
        console2.log("=== PART C: Factory launchAndBuy vs UR partial-fill ===");
        // UR can partially consume; Factory launchAndBuy requires exact spend of pulled amount.
        uint256[4] memory sizes = [uint256(0.1e18), 0.5e18, 5e18, 20e18];
        for (uint256 i; i < sizes.length; ++i) {
            unchecked {
                ++saltNonce;
            }
            string memory name = string(abi.encodePacked("ABuy", vm.toString(saltNonce)));
            string memory symbol = string(abi.encodePacked("AB", vm.toString(saltNonce)));
            bytes32 salt = _findSaltFor(name, symbol, true);
            ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
                name: name,
                symbol: symbol,
                creatorId: walletCreatorId,
                quoteAsset: AAPL_TOKEN,
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: salt
            });
            deal(AAPL_TOKEN, deployer, sizes[i]);
            vm.prank(deployer);
            IERC20(AAPL_TOKEN).approve(address(factory), sizes[i]);
            uint256 before = IERC20(AAPL_TOKEN).balanceOf(deployer);
            vm.prank(deployer);
            try factory.launchAndBuy(params, sizes[i], 1) {
                console2.log("factoryLaunchAndBuy OK", sizes[i]);
                console2.log(" spent", before - IERC20(AAPL_TOKEN).balanceOf(deployer));
            } catch {
                console2.log("factoryLaunchAndBuy REVERT", sizes[i]);
                assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), before);
            }
        }
    }

    function _manualEthBuy(int24 width, uint256 ethIn) internal returns (BuySample memory s, address token) {
        bytes32 salt = _nextSalt();
        token = tokenDeployer.deployToken("Man", "MAN", address(this), salt);
        ScoopLaunchMath.LaunchPricing memory pricing =
            ScoopLaunchMath.calculateLaunchPricing(token, address(0), 18, ethUsd);
        ScoopLiquidityCurveHelpers.CandidateRange memory r =
            ScoopLiquidityCurveHelpers.candidateOneSidedRange(pricing.openingTick, true, width);

        PoolKey memory key = _poolKey(token, address(0));
        IPoolManager(POOL_MANAGER_ADDR).initialize(key, pricing.sqrtPriceX96);

        uint256 supply = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(PERMIT2_ADDR, supply);
        IAllowanceTransfer(PERMIT2_ADDR).approve(token, POSITION_MANAGER_ADDR, uint160(supply), type(uint48).max);

        uint160 sqrtL = TickMath.getSqrtPriceAtTick(r.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(r.tickUpper);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtU, supply);

        uint256 tokenId = IPositionManager(POSITION_MANAGER_ADDR).nextTokenId();
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, r.tickLower, r.tickUpper, uint256(liq), uint128(0), uint128(supply), address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        IPositionManager(POSITION_MANAGER_ADDR).modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        s.openingTick = pricing.openingTick;
        s.openingSqrt = pricing.sqrtPriceX96;
        s.tickLower = r.tickLower;
        s.tickUpper = r.tickUpper;
        s.requested = ethIn;

        uint256 tokBefore = IERC20(token).balanceOf(trader);
        uint256 urBefore = UNIVERSAL_ROUTER_ADDR.balance;
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeSwap(key, true, uint128(ethIn), 1);
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute{value: ethIn}(commands, inputs, block.timestamp + 60);
        s.tokensOut = IERC20(token).balanceOf(trader) - tokBefore;
        s.unspent = UNIVERSAL_ROUTER_ADDR.balance - urBefore;
        s.consumed = ethIn - s.unspent;
        (s.finalSqrt, s.finalTick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(key.toId());
        s.spotFdv = ScoopLiquidityCurveHelpers.reconstructFdv(s.finalSqrt, true, 18, ethUsd);
        tokenId;
    }

    function _poolKey(address token, address quote) internal pure returns (PoolKey memory key) {
        Currency a = Currency.wrap(quote);
        Currency b = Currency.wrap(token);
        if (a < b) {
            key = PoolKey({currency0: a, currency1: b, fee: 10_000, tickSpacing: 10, hooks: IHooks(address(0))});
        } else {
            key = PoolKey({currency0: b, currency1: a, fee: 10_000, tickSpacing: 10, hooks: IHooks(address(0))});
        }
    }

    function _encodeSwap(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        Currency settle = zeroForOne ? key.currency0 : key.currency1;
        Currency take = zeroForOne ? key.currency1 : key.currency0;
        params[1] = abi.encode(settle, uint256(amountIn));
        params[2] = abi.encode(take, uint256(minOut));
        return abi.encode(actions, params);
    }

    receive() external payable {}
}
