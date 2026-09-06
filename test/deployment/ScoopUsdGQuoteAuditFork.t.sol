// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopLaunchMath} from "../../src/libraries/ScoopLaunchMath.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";

interface IFeedMeta {
    function description() external view returns (string memory);
}

/**
 * @title ScoopUsdGQuoteAuditForkTest
 * @notice Phase 6C.1 — read-only / fork-only USDG mainnet quote audit.
 * @dev Never broadcasts. Fork mutations only via vm.prank of the live authority EOA.
 */
contract ScoopUsdGQuoteAuditForkTest is Test {
    using StateLibrary for IPoolManager;

    // Production SCOOP V1 — scoop-v1-mainnet-canary
    ScoopFactory constant FACTORY = ScoopFactory(0x15E874Bc667435ddbF2a67c0362701DC23C90833);
    ScoopQuoteRegistry constant QUOTE_REGISTRY = ScoopQuoteRegistry(0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD);
    ScoopPriceOracle constant PRICE_ORACLE = ScoopPriceOracle(0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12);
    ScoopCreatorRegistry constant CREATOR_REGISTRY = ScoopCreatorRegistry(0x608e117EdA28b65cDa473756a990B8246EAe62D2);
    address constant AUTHORITY = 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7;
    address constant LAUNCH_FEE_RECIPIENT = 0xCb2D4ceD82B5E9e013F4db58F999662052aE1FA3;

    // Official Robinhood USDG + Chainlink feeds-robinhood-mainnet.json "USDG / USD"
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant USDG_IMPL = 0x68184C449E1a8f34fA18d289737129FD27B66f8F;

    uint48 constant USDG_MAX_AGE = 86_400;

    address internal launcher;
    address internal walletCreator;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        require(block.chainid == 4663, "wrong chain");

        launcher = makeAddr("usdgLauncher_FORK_ONLY");
        walletCreator = makeAddr("usdgCreator_FORK_ONLY");
        vm.deal(launcher, 10 ether);
    }

    // ─── Live reads (no mutation) ────────────────────────────────────────────

    function test_live_usdgMetadata() public view {
        assertGt(USDG.code.length, 0, "USDG missing code");
        assertEq(IERC20Metadata(USDG).name(), "Global Dollar");
        assertEq(IERC20Metadata(USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(USDG).decimals(), 6);
        assertGt(IERC20(USDG).totalSupply(), 0);

        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address impl = address(uint160(uint256(vm.load(USDG, implSlot))));
        assertEq(impl, USDG_IMPL);
        assertGt(impl.code.length, 0);

        console2.log("USDG decimals", IERC20Metadata(USDG).decimals());
        console2.log("USDG totalSupply", IERC20(USDG).totalSupply());
        console2.log("USDG implementation", impl);
    }

    function test_live_scoopUsdGUnconfigured() public view {
        assertFalse(QUOTE_REGISTRY.isRegistered(USDG));
        assertFalse(QUOTE_REGISTRY.isEnabled(USDG));
        assertFalse(PRICE_ORACLE.isConfigured(USDG));
        assertFalse(PRICE_ORACLE.isEnabled(USDG));

        assertTrue(QUOTE_REGISTRY.isRegistered(address(0)));
        assertTrue(QUOTE_REGISTRY.isEnabled(address(0)));
        assertTrue(PRICE_ORACLE.isConfigured(address(0)));
        assertTrue(PRICE_ORACLE.isEnabled(address(0)));
        assertEq(QUOTE_REGISTRY.registeredQuoteCount(), 1);
    }

    function test_live_authoritiesAndFee() public view {
        assertEq(QUOTE_REGISTRY.registryAuthority(), AUTHORITY);
        assertEq(PRICE_ORACLE.oracleAuthority(), AUTHORITY);
        assertEq(AUTHORITY.code.length, 0, "authority should be EOA");

        assertEq(address(FACTORY.quoteRegistry()), address(QUOTE_REGISTRY));
        assertEq(address(FACTORY.priceOracle()), address(PRICE_ORACLE));
        assertEq(FACTORY.LAUNCH_FEE(), 0.0005 ether);
        assertEq(FACTORY.launchFeeRecipient(), LAUNCH_FEE_RECIPIENT);
        assertEq(LAUNCH_FEE_RECIPIENT.code.length, 0, "fee recipient EOA");
    }

    function test_live_usdgUsdFeedCompatible() public view {
        assertGt(USDG_USD_FEED.code.length, 0);
        IAggregatorV3 feed = IAggregatorV3(USDG_USD_FEED);
        assertEq(feed.decimals(), 8);
        assertEq(IFeedMeta(USDG_USD_FEED).description(), "USDG / USD");

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        assertLe(updatedAt, block.timestamp);
        assertGe(answeredInRound, roundId);
        assertLe(block.timestamp - updatedAt, USDG_MAX_AGE);
        assertApproxEqRel(uint256(answer), 1e8, 0.02e18);

        console2.log("USDG/USD answer", uint256(answer));
        console2.log("USDG/USD age", block.timestamp - updatedAt);
    }

    function test_math_sixDecimalQuoteNearOneUsd() public pure {
        address token = address(0xBEEF);
        address quote = address(0x1);
        uint256 quoteUsd = 0.99993909e18;

        ScoopLaunchMath.LaunchPricing memory p = ScoopLaunchMath.calculateLaunchPricing(token, quote, 6, quoteUsd);

        assertTrue(p.sqrtPriceX96 > 0);
        assertTrue(p.launchedIsCurrency1);
        assertTrue(p.tickUpper <= p.openingTick);
    }

    // ─── Fork-only configuration + launch ────────────────────────────────────

    function test_fork_configureAndLaunchWithUsdG() public {
        _configureUsdGOnFork();

        uint256 priceUsd = PRICE_ORACLE.getPriceUsd(USDG);
        assertApproxEqRel(priceUsd, 1e18, 0.02e18);
        console2.log("oracle getPriceUsd(USDG)", priceUsd);

        ScoopFactory.LaunchParams memory params = _params("UsdGPlain", "UGP", bytes32(uint256(601)));

        uint256 feeBefore = LAUNCH_FEE_RECIPIENT.balance;
        vm.prank(launcher);
        (address token, address feeDist, address locker, uint256 lpId, PoolId poolId) =
            FACTORY.launch{value: FACTORY.LAUNCH_FEE()}(params);

        assertTrue(FACTORY.isScoopToken(token));
        ScoopFactory.Launch memory rec = FACTORY.getLaunch(token);
        assertEq(rec.quoteAsset, USDG);
        assertEq(rec.token, token);
        assertEq(rec.feeDistributor, feeDist);
        assertEq(rec.liquidityLocker, locker);
        assertEq(rec.lpTokenId, lpId);
        assertEq(PoolId.unwrap(rec.poolId), PoolId.unwrap(poolId));

        assertEq(LAUNCH_FEE_RECIPIENT.balance - feeBefore, FACTORY.LAUNCH_FEE());
        assertEq(address(FACTORY).balance, 0);
        assertEq(IERC20(USDG).balanceOf(address(FACTORY)), 0);
        assertEq(IERC20(token).balanceOf(address(FACTORY)), 0);
        assertEq(IERC721(address(FACTORY.positionManager())).ownerOf(lpId), locker);

        (uint160 liveSqrt,,,) = IPoolManager(address(FACTORY.poolManager())).getSlot0(poolId);
        assertEq(liveSqrt, rec.openingSqrtPriceX96);

        ScoopLaunchMath.LaunchPricing memory expected = ScoopLaunchMath.calculateLaunchPricing(token, USDG, 6, priceUsd);
        assertEq(expected.sqrtPriceX96, rec.openingSqrtPriceX96);
        console2.log("USDG plain launch ok");
    }

    function test_fork_launchAndBuyWithUsdG() public {
        _configureUsdGOnFork();

        uint256 quoteIn = 10e6; // 10 USDG
        deal(USDG, launcher, quoteIn);

        ScoopFactory.LaunchParams memory params = _params("UsdGBuy", "UGB", bytes32(uint256(602)));
        uint256 feeBefore = LAUNCH_FEE_RECIPIENT.balance;

        vm.startPrank(launcher);
        IERC20(USDG).approve(address(FACTORY), quoteIn);
        (address token,,,,, uint256 bought) = FACTORY.launchAndBuy{value: FACTORY.LAUNCH_FEE()}(params, quoteIn, 1);
        vm.stopPrank();

        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(launcher), bought);
        assertEq(IERC20(USDG).balanceOf(launcher), 0);
        assertEq(IERC20(USDG).balanceOf(address(FACTORY)), 0);
        assertEq(IERC20(token).balanceOf(address(FACTORY)), 0);
        assertEq(address(FACTORY).balance, 0);
        assertEq(LAUNCH_FEE_RECIPIENT.balance - feeBefore, FACTORY.LAUNCH_FEE());

        ScoopFactory.Launch memory rec = FACTORY.getLaunch(token);
        assertEq(rec.quoteAsset, USDG);
        assertEq(IERC721(address(FACTORY.positionManager())).ownerOf(rec.lpTokenId), rec.liquidityLocker);

        console2.log("USDG launchAndBuy tokensBought", bought);
    }

    function test_fork_erc20LaunchRequiresExactNativeFeeOnly() public {
        _configureUsdGOnFork();
        uint256 quoteIn = 1e6;
        deal(USDG, launcher, quoteIn);

        ScoopFactory.LaunchParams memory params = _params("UsdGFee", "UGF", bytes32(uint256(603)));

        vm.startPrank(launcher);
        IERC20(USDG).approve(address(FACTORY), quoteIn);

        uint256 fee = FACTORY.LAUNCH_FEE();
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, fee + 1));
        FACTORY.launchAndBuy{value: fee + 1}(params, quoteIn, 1);

        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, 0));
        FACTORY.launchAndBuy{value: 0}(params, quoteIn, 1);
        vm.stopPrank();
    }

    function test_fork_unauthorizedConfigureReverts() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        QUOTE_REGISTRY.registerQuote(USDG, ScoopQuoteRegistry.QuoteType.Scoop);

        vm.prank(attacker);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        PRICE_ORACLE.configureFeed(USDG, USDG_USD_FEED, USDG_MAX_AGE);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _configureUsdGOnFork() internal {
        assertFalse(QUOTE_REGISTRY.isRegistered(USDG));
        assertFalse(PRICE_ORACLE.isConfigured(USDG));

        vm.startPrank(AUTHORITY);
        PRICE_ORACLE.configureFeed(USDG, USDG_USD_FEED, USDG_MAX_AGE);
        QUOTE_REGISTRY.registerQuote(USDG, ScoopQuoteRegistry.QuoteType.Scoop);
        vm.stopPrank();

        assertTrue(QUOTE_REGISTRY.isRegistered(USDG));
        assertTrue(QUOTE_REGISTRY.isEnabled(USDG));
        assertEq(uint8(QUOTE_REGISTRY.quoteType(USDG)), uint8(ScoopQuoteRegistry.QuoteType.Scoop));
        assertTrue(PRICE_ORACLE.isConfigured(USDG));
        assertTrue(PRICE_ORACLE.isEnabled(USDG));

        ScoopPriceOracle.PriceFeedConfig memory cfg = PRICE_ORACLE.getFeedConfig(USDG);
        assertEq(cfg.feed, USDG_USD_FEED);
        assertEq(cfg.maxAge, USDG_MAX_AGE);
        assertEq(cfg.feedDecimals, 8);
        assertTrue(cfg.enabled);
    }

    function _params(string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (ScoopFactory.LaunchParams memory)
    {
        return ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: CREATOR_REGISTRY.walletCreatorId(walletCreator),
            quoteAsset: USDG,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
    }
}
