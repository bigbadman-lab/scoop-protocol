// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract ScoopPriceOracleTest is Test {
    ScoopPriceOracle oracle;
    MockAggregatorV3 feed;

    address authority;
    address stranger;
    address constant QUOTE_AAPL = address(0xA11CE);
    address constant QUOTE_OTHER = address(0xB0B);

    event PriceFeedConfigured(address indexed quoteAsset, address indexed feed, uint48 maxAge, uint8 feedDecimals);
    event PriceFeedStatusChanged(address indexed quoteAsset, bool enabled);
    event MaxAgeUpdated(address indexed quoteAsset, uint48 oldMaxAge, uint48 newMaxAge);

    function setUp() public {
        authority = makeAddr("oracleAuthority");
        stranger = makeAddr("stranger");
        oracle = new ScoopPriceOracle(authority);
        feed = new MockAggregatorV3(8);
        // Default: fresh positive $1.00 at t=1000 with maxAge room.
        vm.warp(1000);
        feed.setRound(1, 1e8, 900, 1000, 1);
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    function test_constructor_pinsAuthority() public view {
        assertEq(oracle.oracleAuthority(), authority);
    }

    function test_constructor_zeroAuthorityReverts() public {
        vm.expectRevert(ScoopPriceOracle.ZeroOracleAuthority.selector);
        new ScoopPriceOracle(address(0));
    }

    // ─── Configuration ───────────────────────────────────────────────────────

    function test_configure_nativeEth() public {
        vm.expectEmit(true, true, false, true);
        emit PriceFeedConfigured(address(0), address(feed), 3600, 8);

        vm.prank(authority);
        oracle.configureFeed(address(0), address(feed), 3600);

        assertTrue(oracle.isConfigured(address(0)));
        assertTrue(oracle.isEnabled(address(0)));
        ScoopPriceOracle.PriceFeedConfig memory cfg = oracle.getFeedConfig(address(0));
        assertEq(cfg.feed, address(feed));
        assertEq(cfg.maxAge, 3600);
        assertEq(cfg.feedDecimals, 8);
        assertTrue(cfg.enabled);
    }

    function test_configure_nonzeroQuote() public {
        vm.prank(authority);
        oracle.configureFeed(QUOTE_AAPL, address(feed), 7200);

        ScoopPriceOracle.PriceFeedConfig memory cfg = oracle.getFeedConfig(QUOTE_AAPL);
        assertEq(cfg.feed, address(feed));
        assertEq(cfg.maxAge, 7200);
        assertEq(cfg.feedDecimals, 8);
        assertTrue(cfg.enabled);
    }

    function test_configure_zeroFeedReverts() public {
        vm.prank(authority);
        vm.expectRevert(ScoopPriceOracle.ZeroFeed.selector);
        oracle.configureFeed(address(0), address(0), 3600);
    }

    function test_configure_zeroMaxAgeReverts() public {
        vm.prank(authority);
        vm.expectRevert(ScoopPriceOracle.ZeroMaxAge.selector);
        oracle.configureFeed(address(0), address(feed), 0);
    }

    function test_configure_noCodeFeedReverts() public {
        address eoa = makeAddr("eoaFeed");
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.FeedHasNoCode.selector, eoa));
        oracle.configureFeed(address(0), eoa, 3600);
    }

    function test_configure_decimalsAbove18Reverts() public {
        MockAggregatorV3 bad = new MockAggregatorV3(19);
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.UnsupportedFeedDecimals.selector, uint8(19)));
        oracle.configureFeed(QUOTE_OTHER, address(bad), 3600);
    }

    function test_configure_duplicateReverts() public {
        vm.startPrank(authority);
        oracle.configureFeed(address(0), address(feed), 3600);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedAlreadyConfigured.selector, address(0)));
        oracle.configureFeed(address(0), address(feed), 3600);
        vm.stopPrank();
    }

    function test_configure_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        oracle.configureFeed(address(0), address(feed), 3600);
    }

    // ─── Normalization ───────────────────────────────────────────────────────

    function test_normalize_8dp_oneDollar() public {
        _configure(address(0), feed, 3600);
        assertEq(oracle.getPriceUsd(address(0)), 1e18);
    }

    function test_normalize_8dp_ethSample() public {
        // $2455.2219 at 8dp = 245522190000
        feed.setRound(1, 245522190000, 900, 1000, 1);
        _configure(address(0), feed, 3600);
        assertEq(oracle.getPriceUsd(address(0)), 245522190000 * 1e10);
        assertEq(oracle.getPriceUsd(address(0)), 2455221900000000000000);
    }

    function test_normalize_18dp_unchanged() public {
        MockAggregatorV3 feed18 = new MockAggregatorV3(18);
        feed18.setRound(1, 2455 ether, 900, 1000, 1);
        _configure(QUOTE_OTHER, feed18, 3600);
        assertEq(oracle.getPriceUsd(QUOTE_OTHER), 2455 ether);
    }

    function test_normalize_6dp() public {
        MockAggregatorV3 feed6 = new MockAggregatorV3(6);
        feed6.setRound(1, 1_000_000, 900, 1000, 1); // $1 at 6dp
        _configure(QUOTE_OTHER, feed6, 3600);
        assertEq(oracle.getPriceUsd(QUOTE_OTHER), 1e18);
    }

    function test_normalize_0dp() public {
        MockAggregatorV3 feed0 = new MockAggregatorV3(0);
        feed0.setRound(1, 42, 900, 1000, 1); // $42
        _configure(QUOTE_OTHER, feed0, 3600);
        assertEq(oracle.getPriceUsd(QUOTE_OTHER), 42e18);
    }

    // ─── Price validity ──────────────────────────────────────────────────────

    function test_getPrice_positiveFreshSucceeds() public {
        _configure(address(0), feed, 3600);
        assertGt(oracle.getPriceUsd(address(0)), 0);
    }

    function test_getPrice_zeroAnswerReverts() public {
        feed.setRound(1, 0, 900, 1000, 1);
        _configure(address(0), feed, 3600);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.InvalidPrice.selector, address(0), int256(0)));
        oracle.getPriceUsd(address(0));
    }

    function test_getPrice_negativeAnswerReverts() public {
        feed.setRound(1, -1, 900, 1000, 1);
        _configure(address(0), feed, 3600);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.InvalidPrice.selector, address(0), int256(-1)));
        oracle.getPriceUsd(address(0));
    }

    function test_getPrice_zeroUpdatedAtReverts() public {
        feed.setRound(1, 1e8, 0, 0, 1);
        _configure(address(0), feed, 3600);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.InvalidTimestamp.selector, address(0), uint256(0)));
        oracle.getPriceUsd(address(0));
    }

    function test_getPrice_futureUpdatedAtReverts() public {
        feed.setRound(1, 1e8, 900, 1001, 1);
        _configure(address(0), feed, 3600);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.InvalidTimestamp.selector, address(0), uint256(1001)));
        oracle.getPriceUsd(address(0));
    }

    function test_getPrice_exactlyMaxAgeSucceeds() public {
        // age = 3600, maxAge = 3600 → OK
        feed.setRound(1, 1e8, 400, 400, 1);
        vm.warp(4000);
        _configure(address(0), feed, 3600);
        assertEq(oracle.getPriceUsd(address(0)), 1e18);
    }

    function test_getPrice_maxAgePlusOneReverts() public {
        feed.setRound(1, 1e8, 399, 399, 1);
        vm.warp(4000); // age = 3601
        _configure(address(0), feed, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopPriceOracle.StalePrice.selector, address(0), uint256(399), uint256(3600))
        );
        oracle.getPriceUsd(address(0));
    }

    function test_getPrice_incompleteRoundReverts() public {
        feed.setRound(5, 1e8, 900, 1000, 4); // answeredInRound < roundId
        _configure(address(0), feed, 3600);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopPriceOracle.IncompleteRound.selector, address(0), uint80(5), uint80(4))
        );
        oracle.getPriceUsd(address(0));
    }

    function test_getPrice_answeredInRoundEqualSucceeds() public {
        feed.setRound(7, 1e8, 900, 1000, 7);
        _configure(address(0), feed, 3600);
        assertEq(oracle.getPriceUsd(address(0)), 1e18);
    }

    function test_getPrice_answeredInRoundGreaterSucceeds() public {
        feed.setRound(7, 1e8, 900, 1000, 9);
        _configure(address(0), feed, 3600);
        assertEq(oracle.getPriceUsd(address(0)), 1e18);
    }

    // ─── Enable / disable ────────────────────────────────────────────────────

    function test_disable_blocksPriceThenReenable() public {
        _configure(address(0), feed, 3600);

        vm.expectEmit(true, false, false, true);
        emit PriceFeedStatusChanged(address(0), false);
        vm.prank(authority);
        oracle.setFeedEnabled(address(0), false);

        assertTrue(oracle.isConfigured(address(0)));
        assertFalse(oracle.isEnabled(address(0)));
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedDisabled.selector, address(0)));
        oracle.getPriceUsd(address(0));

        vm.expectEmit(true, false, false, true);
        emit PriceFeedStatusChanged(address(0), true);
        vm.prank(authority);
        oracle.setFeedEnabled(address(0), true);

        assertEq(oracle.getPriceUsd(address(0)), 1e18);
        assertEq(oracle.getFeedConfig(address(0)).feed, address(feed));
    }

    function test_setFeedEnabled_sameStatusReverts() public {
        _configure(address(0), feed, 3600);
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.FeedStatusUnchanged.selector, address(0), true));
        oracle.setFeedEnabled(address(0), true);
    }

    function test_setFeedEnabled_unconfiguredReverts() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedNotConfigured.selector, QUOTE_OTHER));
        oracle.setFeedEnabled(QUOTE_OTHER, false);
    }

    function test_setFeedEnabled_unauthorizedReverts() public {
        _configure(address(0), feed, 3600);
        vm.prank(stranger);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        oracle.setFeedEnabled(address(0), false);
    }

    // ─── maxAge ──────────────────────────────────────────────────────────────

    function test_setMaxAge_updatesAndAffectsFreshness() public {
        feed.setRound(1, 1e8, 100, 100, 1);
        vm.warp(1100); // age = 1000
        _configure(address(0), feed, 2000);
        assertEq(oracle.getPriceUsd(address(0)), 1e18);

        vm.expectEmit(true, false, false, true);
        emit MaxAgeUpdated(address(0), 2000, 500);
        vm.prank(authority);
        oracle.setMaxAge(address(0), 500);

        assertEq(oracle.getFeedConfig(address(0)).maxAge, 500);
        assertEq(oracle.getFeedConfig(address(0)).feed, address(feed));

        vm.expectRevert(
            abi.encodeWithSelector(ScoopPriceOracle.StalePrice.selector, address(0), uint256(100), uint256(500))
        );
        oracle.getPriceUsd(address(0));
    }

    function test_setMaxAge_zeroReverts() public {
        _configure(address(0), feed, 3600);
        vm.prank(authority);
        vm.expectRevert(ScoopPriceOracle.ZeroMaxAge.selector);
        oracle.setMaxAge(address(0), 0);
    }

    function test_setMaxAge_unconfiguredReverts() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedNotConfigured.selector, QUOTE_OTHER));
        oracle.setMaxAge(QUOTE_OTHER, 100);
    }

    function test_setMaxAge_unauthorizedReverts() public {
        _configure(address(0), feed, 3600);
        vm.prank(stranger);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        oracle.setMaxAge(address(0), 100);
    }

    // ─── Feed immutability ───────────────────────────────────────────────────

    function test_feedIdentity_writeOnce() public {
        MockAggregatorV3 other = new MockAggregatorV3(8);
        other.setRound(1, 2e8, 900, 1000, 1);

        _configure(QUOTE_AAPL, feed, 3600);
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedAlreadyConfigured.selector, QUOTE_AAPL));
        oracle.configureFeed(QUOTE_AAPL, address(other), 3600);

        vm.prank(authority);
        oracle.setFeedEnabled(QUOTE_AAPL, false);
        vm.prank(authority);
        oracle.setFeedEnabled(QUOTE_AAPL, true);
        vm.prank(authority);
        oracle.setMaxAge(QUOTE_AAPL, 999);

        assertEq(oracle.getFeedConfig(QUOTE_AAPL).feed, address(feed));
        assertEq(oracle.getPriceUsd(QUOTE_AAPL), 1e18);
    }

    // ─── Unknown quote ───────────────────────────────────────────────────────

    function test_unknownQuote_reads() public {
        assertFalse(oracle.isConfigured(QUOTE_OTHER));
        assertFalse(oracle.isEnabled(QUOTE_OTHER));

        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedNotConfigured.selector, QUOTE_OTHER));
        oracle.getPriceUsd(QUOTE_OTHER);

        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedNotConfigured.selector, QUOTE_OTHER));
        oracle.getFeedConfig(QUOTE_OTHER);
    }

    // ─── Security surface ────────────────────────────────────────────────────

    function test_noAdminMutationSurface() public {
        _assertNoFn(abi.encodeWithSignature("owner()"));
        _assertNoFn(abi.encodeWithSignature("transferOwnership(address)", stranger));
        _assertNoFn(abi.encodeWithSignature("setAuthority(address)", stranger));
        _assertNoFn(abi.encodeWithSignature("execute(address,bytes)", stranger, bytes("")));
        _assertNoFn(abi.encodeWithSignature("rescueETH(address,uint256)", stranger, uint256(1)));
        _assertNoFn(abi.encodeWithSignature("setPrice(address,uint256)", address(0), uint256(1)));
        _assertNoFn(abi.encodeWithSignature("replaceFeed(address,address)", address(0), address(feed)));
        _assertNoFn(abi.encodeWithSignature("setMultiplier(address,uint256)", QUOTE_AAPL, uint256(1)));
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_normalize(uint8 decimals_, uint128 rawAnswer) public {
        decimals_ = uint8(bound(decimals_, 0, 18));
        rawAnswer = uint128(bound(rawAnswer, 1, type(uint128).max));
        uint256 scale = 10 ** uint256(18 - decimals_);
        // Ensure no overflow on normalize
        vm.assume(uint256(rawAnswer) <= type(uint256).max / scale);

        MockAggregatorV3 f = new MockAggregatorV3(decimals_);
        f.setRound(1, int256(uint256(rawAnswer)), 900, 1000, 1);
        _configure(QUOTE_OTHER, f, 3600);

        assertEq(oracle.getPriceUsd(QUOTE_OTHER), uint256(rawAnswer) * scale);
    }

    function testFuzz_freshnessBoundary(uint48 maxAge, uint48 age) public {
        maxAge = uint48(bound(maxAge, 1, type(uint48).max / 2));
        age = uint48(bound(age, 0, maxAge + 10));

        uint256 updatedAt = 1_000_000;
        vm.warp(updatedAt + age);
        feed.setRound(1, 1e8, updatedAt, updatedAt, 1);
        _configure(address(0), feed, maxAge);

        if (age <= maxAge) {
            assertEq(oracle.getPriceUsd(address(0)), 1e18);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(ScoopPriceOracle.StalePrice.selector, address(0), updatedAt, uint256(maxAge))
            );
            oracle.getPriceUsd(address(0));
        }
    }

    function testFuzz_feedIdentityImmutable(address quoteAsset, uint48 maxAgeA, uint48 maxAgeB) public {
        vm.assume(quoteAsset != address(0)); // avoid colliding with other tests using eth; any nonzero fine
        // Use unique salt via quoteAsset as feed deploy salt? Just deploy new feeds.
        maxAgeA = uint48(bound(maxAgeA, 1, type(uint48).max));
        maxAgeB = uint48(bound(maxAgeB, 1, type(uint48).max));

        MockAggregatorV3 f1 = new MockAggregatorV3(8);
        MockAggregatorV3 f2 = new MockAggregatorV3(8);
        f1.setRound(1, 1e8, 900, 1000, 1);
        f2.setRound(1, 2e8, 900, 1000, 1);

        vm.prank(authority);
        oracle.configureFeed(quoteAsset, address(f1), maxAgeA);

        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedAlreadyConfigured.selector, quoteAsset));
        oracle.configureFeed(quoteAsset, address(f2), maxAgeB);

        vm.prank(authority);
        oracle.setMaxAge(quoteAsset, maxAgeB);

        assertEq(oracle.getFeedConfig(quoteAsset).feed, address(f1));
        assertEq(oracle.getFeedConfig(quoteAsset).maxAge, maxAgeB);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _configure(address quoteAsset, MockAggregatorV3 f, uint48 maxAge) internal {
        vm.prank(authority);
        oracle.configureFeed(quoteAsset, address(f), maxAge);
    }

    function _assertNoFn(bytes memory callData) internal {
        vm.prank(authority);
        (bool success,) = address(oracle).call(callData);
        assertFalse(success, "forbidden surface should not succeed");
    }
}
