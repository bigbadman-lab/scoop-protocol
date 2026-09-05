// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopSecurityLocalBase} from "./ScoopSecurityLocalBase.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/**
 * @notice Adversarial oracle feed + quote registry policy tests.
 */
contract ScoopOracleAdversarialTest is ScoopSecurityLocalBase {
    address constant QUOTE_OTHER = address(0xB0B);

    function test_priceOne_succeedsNormalized() public view {
        assertEq(priceOracle.getPriceUsd(address(0)), 1e18);
    }

    function test_priceTiny_succeeds() public {
        ethFeed.setRound(1, 1, 900, 1000, 1); // $0.00000001 at 8dp
        assertEq(priceOracle.getPriceUsd(address(0)), 1e10);
    }

    function test_priceHuge_succeedsOrOverflowsClosed() public {
        // Very large but within int256; normalization may overflow → PriceOverflow.
        ethFeed.setRound(1, type(int256).max / 1e10, 900, 1000, 1);
        try priceOracle.getPriceUsd(address(0)) returns (uint256 p) {
            assertGt(p, 0);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ScoopPriceOracle.PriceOverflow.selector);
        }
    }

    function test_maxAgeBoundary_exactAgeSucceeds() public {
        ethFeed.setRound(1, 1e8, 400, 400, 1);
        vm.warp(4000); // age = 3600 == maxAge
        assertEq(priceOracle.getPriceUsd(address(0)), 1e18);
    }

    function test_maxAgePlusOne_staleReverts() public {
        ethFeed.setRound(1, 1e8, 399, 399, 1);
        vm.warp(4000); // age = 3601
        vm.expectRevert(
            abi.encodeWithSelector(ScoopPriceOracle.StalePrice.selector, address(0), uint256(399), uint256(3600))
        );
        priceOracle.getPriceUsd(address(0));
    }

    function test_futureTimestamp_reverts() public {
        ethFeed.setRound(1, 1e8, 900, 1001, 1);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.InvalidTimestamp.selector, address(0), uint256(1001)));
        priceOracle.getPriceUsd(address(0));
    }

    function test_decimalsZero_normalizes() public {
        MockAggregatorV3 feed0 = new MockAggregatorV3(0);
        feed0.setRound(1, 42, 900, 1000, 1);
        vm.prank(oracleAuthority);
        priceOracle.configureFeed(QUOTE_OTHER, address(feed0), 3600);
        assertEq(priceOracle.getPriceUsd(QUOTE_OTHER), 42e18);
    }

    function test_decimals18_unchanged() public {
        MockAggregatorV3 feed18 = new MockAggregatorV3(18);
        feed18.setRound(1, 2455 ether, 900, 1000, 1);
        address q = address(0xC0FFEE);
        vm.prank(oracleAuthority);
        priceOracle.configureFeed(q, address(feed18), 3600);
        assertEq(priceOracle.getPriceUsd(q), 2455 ether);
    }

    function test_decimals19_configureReverts() public {
        MockAggregatorV3 bad = new MockAggregatorV3(19);
        vm.prank(oracleAuthority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.UnsupportedFeedDecimals.selector, uint8(19)));
        priceOracle.configureFeed(QUOTE_OTHER, address(bad), 3600);
    }

    function test_incompleteRound_reverts() public {
        ethFeed.setRound(5, 1e8, 900, 1000, 4);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopPriceOracle.IncompleteRound.selector, address(0), uint80(5), uint80(4))
        );
        priceOracle.getPriceUsd(address(0));
    }

    function test_disableFeed_blocksPrice() public {
        vm.prank(oracleAuthority);
        priceOracle.setFeedEnabled(address(0), false);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedDisabled.selector, address(0)));
        priceOracle.getPriceUsd(address(0));
    }

    function test_setMaxAge_tightensFreshness() public {
        ethFeed.setRound(1, 1e8, 100, 100, 1);
        vm.warp(1100); // age = 1000
        vm.prank(oracleAuthority);
        priceOracle.setMaxAge(address(0), 500);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopPriceOracle.StalePrice.selector, address(0), uint256(100), uint256(500))
        );
        priceOracle.getPriceUsd(address(0));
    }

    function test_zeroPrice_reverts() public {
        ethFeed.setRound(1, 0, 900, 1000, 1);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.InvalidPrice.selector, address(0), int256(0)));
        priceOracle.getPriceUsd(address(0));
    }

    // ─── QuoteRegistry adversarial ───────────────────────────────────────────

    function test_quote_unregistered_readsRevert() public {
        assertFalse(quoteRegistry.isRegistered(QUOTE_OTHER));
        assertFalse(quoteRegistry.isEnabled(QUOTE_OTHER));
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteNotRegistered.selector, QUOTE_OTHER));
        quoteRegistry.quoteType(QUOTE_OTHER);
    }

    function test_quote_disabled_staysRegistered() public {
        address asset = address(0xA11CE);
        vm.prank(registryAuthority);
        quoteRegistry.registerQuote(asset, ScoopQuoteRegistry.QuoteType.Stock);
        vm.prank(registryAuthority);
        quoteRegistry.setQuoteEnabled(asset, false);
        assertTrue(quoteRegistry.isRegistered(asset));
        assertFalse(quoteRegistry.isEnabled(asset));
        assertEq(uint8(quoteRegistry.quoteType(asset)), uint8(ScoopQuoteRegistry.QuoteType.Stock));
    }

    function test_quote_duplicate_reverts() public {
        vm.prank(registryAuthority);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, address(0)));
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
    }

    function test_quote_typeWriteOnce_cannotReregisterDifferentType() public {
        address asset = address(0xBEEF);
        vm.startPrank(registryAuthority);
        quoteRegistry.registerQuote(asset, ScoopQuoteRegistry.QuoteType.Stock);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, asset));
        quoteRegistry.registerQuote(asset, ScoopQuoteRegistry.QuoteType.Pons);
        vm.stopPrank();
        assertEq(uint8(quoteRegistry.quoteType(asset)), uint8(ScoopQuoteRegistry.QuoteType.Stock));
    }

    function test_quote_unauthorized_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        quoteRegistry.registerQuote(address(0x1234), ScoopQuoteRegistry.QuoteType.Scoop);

        vm.prank(attacker);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        quoteRegistry.setQuoteEnabled(address(0), false);
    }

    function test_oracle_unauthorized_reverts() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        vm.prank(attacker);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        priceOracle.configureFeed(QUOTE_OTHER, address(feed), 3600);

        vm.prank(attacker);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        priceOracle.setFeedEnabled(address(0), false);

        vm.prank(attacker);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        priceOracle.setMaxAge(address(0), 100);
    }
}
