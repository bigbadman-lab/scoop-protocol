// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";

/**
 * @notice Robinhood fork: ScoopPriceOracle against live ETH/USD and AAPL/USD AggregatorV3 feeds.
 * @dev Test maxAge values are intentionally generous for fork-observed equity off-hours staleness.
 *      They are NOT production policy.
 *
 * Address provenance (4D.1):
 * - ETH/USD: Chainlink directory proxy 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9
 * - AAPL token: official Robinhood /rhj/assets + onchain verify
 * - AAPL/USD: Chainlink directory proxy 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0
 */
contract ScoopPriceOracleForkTest is Test {
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    /// @dev Test-only staleness window: large enough for observed fork ages (often many hours for equity 24/5).
    uint48 constant TEST_MAX_AGE = 7 days;

    ScoopPriceOracle oracle;
    address authority;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        authority = makeAddr("oracleAuthority");
        oracle = new ScoopPriceOracle(authority);

        vm.startPrank(authority);
        oracle.configureFeed(address(0), ETH_USD_FEED, TEST_MAX_AGE);
        oracle.configureFeed(AAPL_TOKEN, AAPL_USD_FEED, TEST_MAX_AGE);
        vm.stopPrank();
    }

    function test_ethFeedConfigSucceeds() public view {
        ScoopPriceOracle.PriceFeedConfig memory cfg = oracle.getFeedConfig(address(0));
        assertEq(cfg.feed, ETH_USD_FEED);
        assertEq(cfg.feedDecimals, 8);
        assertEq(cfg.maxAge, TEST_MAX_AGE);
        assertTrue(cfg.enabled);
        assertTrue(oracle.isConfigured(address(0)));
        assertTrue(oracle.isEnabled(address(0)));
    }

    function test_aaplFeedConfigSucceeds() public view {
        ScoopPriceOracle.PriceFeedConfig memory cfg = oracle.getFeedConfig(AAPL_TOKEN);
        assertEq(cfg.feed, AAPL_USD_FEED);
        assertEq(cfg.feedDecimals, 8);
        assertEq(cfg.maxAge, TEST_MAX_AGE);
        assertTrue(cfg.enabled);
    }

    function test_bothStoreDecimals8() public view {
        assertEq(oracle.getFeedConfig(address(0)).feedDecimals, 8);
        assertEq(oracle.getFeedConfig(AAPL_TOKEN).feedDecimals, 8);
    }

    function test_ethNormalizedPriceMatchesDirectFeed() public view {
        (, int256 raw,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        uint256 normalized = oracle.getPriceUsd(address(0));

        assertGt(raw, 0);
        assertGt(normalized, 0);
        assertEq(normalized, uint256(raw) * 1e10);

        console2.log("raw ETH answer", uint256(raw));
        console2.log("normalized ETH/USD (1e18)", normalized);
        console2.log("test maxAge", uint256(TEST_MAX_AGE));
    }

    function test_aaplNormalizedPriceMatchesDirectFeed() public view {
        (, int256 raw,,,) = IAggregatorV3(AAPL_USD_FEED).latestRoundData();
        uint256 normalized = oracle.getPriceUsd(AAPL_TOKEN);

        assertGt(raw, 0);
        assertGt(normalized, 0);
        assertEq(normalized, uint256(raw) * 1e10);

        console2.log("raw AAPL answer", uint256(raw));
        console2.log("normalized AAPL/USD (1e18)", normalized);
        console2.log("test maxAge", uint256(TEST_MAX_AGE));
    }

    function test_nativeEthAddressZeroWorks() public view {
        uint256 price = oracle.getPriceUsd(address(0));
        assertGt(price, 0);
        assertEq(oracle.getFeedConfig(address(0)).feed, ETH_USD_FEED);
    }

    function test_timestampsPassUnderTestMaxAge() public view {
        // If getPriceUsd returns, future/zero/stale checks already passed.
        assertGt(oracle.getPriceUsd(address(0)), 0);
        assertGt(oracle.getPriceUsd(AAPL_TOKEN), 0);

        (,,, uint256 ethUpdatedAt,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        (,,, uint256 aaplUpdatedAt,) = IAggregatorV3(AAPL_USD_FEED).latestRoundData();
        assertLe(block.timestamp - ethUpdatedAt, TEST_MAX_AGE);
        assertLe(block.timestamp - aaplUpdatedAt, TEST_MAX_AGE);
        console2.log("ETH age", block.timestamp - ethUpdatedAt);
        console2.log("AAPL age", block.timestamp - aaplUpdatedAt);
    }

    function test_disableAaplBlocksThenReenable() public {
        assertGt(oracle.getPriceUsd(AAPL_TOKEN), 0);

        vm.prank(authority);
        oracle.setFeedEnabled(AAPL_TOKEN, false);

        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedDisabled.selector, AAPL_TOKEN));
        oracle.getPriceUsd(AAPL_TOKEN);

        vm.prank(authority);
        oracle.setFeedEnabled(AAPL_TOKEN, true);

        uint256 price = oracle.getPriceUsd(AAPL_TOKEN);
        assertGt(price, 0);
        assertEq(oracle.getFeedConfig(AAPL_TOKEN).feed, AAPL_USD_FEED);
    }

    function test_logForkSummary() public view {
        (, int256 ethRaw,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        (, int256 aaplRaw,,,) = IAggregatorV3(AAPL_USD_FEED).latestRoundData();
        console2.log("=== ScoopPriceOracle fork summary ===");
        console2.log("ETH feed", ETH_USD_FEED);
        console2.log("raw ETH", uint256(ethRaw));
        console2.log("norm ETH", oracle.getPriceUsd(address(0)));
        console2.log("AAPL quote", AAPL_TOKEN);
        console2.log("AAPL feed", AAPL_USD_FEED);
        console2.log("raw AAPL", uint256(aaplRaw));
        console2.log("norm AAPL", oracle.getPriceUsd(AAPL_TOKEN));
        console2.log("TEST_MAX_AGE (not production)", uint256(TEST_MAX_AGE));
    }
}
