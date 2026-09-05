// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/**
 * @title ScoopPriceOracle
 * @notice Production quote-asset → USD price reader for SCOOP Protocol V1.
 * @dev Answers the single question: what is one whole unit of a configured quote asset
 *      worth in USD? Returns prices normalized to 1e18 precision (`1e18 = $1.00`).
 *
 *      Responsibilities:
 *      - quoteAsset → Chainlink AggregatorV3 feed configuration (write-once feed identity)
 *      - enable/disable policy and per-feed maxAge tuning
 *      - answer / timestamp / freshness / round validation
 *      - decimal normalization to 1e18 USD
 *
 *      Explicitly out of scope:
 *      - $5k FDV / launched-token pricing / ticks / sqrtPriceX96
 *      - swaps, pools, buybacks, REST APIs, Data Streams
 *      - ScoopQuoteRegistry coupling (approval policy lives there)
 *      - Stock Token `uiMultiplier()` — Robinhood equity feeds are already multiplier-adjusted;
 *        this oracle MUST NOT re-apply the multiplier
 *
 *      Native ETH is represented as `quoteAsset == address(0)` (Uniswap v4 Currency convention).
 *      The feed address itself must always be non-zero.
 *
 *      Feed identity is write-once. If an upstream proxy is deprecated, disable the quote and
 *      migrate via an explicit later protocol release — do not silently replace feeds in V1.
 *
 *      `oracleAuthority` is immutable. Only that address may configure feeds, toggle enabled
 *      status, or update maxAge. There is no ownership transfer, authority setter, upgrade path,
 *      arbitrary execute, or rescue surface.
 */
contract ScoopPriceOracle {
    error ZeroOracleAuthority();
    error Unauthorized();
    error ZeroFeed();
    error ZeroMaxAge();
    error FeedHasNoCode(address feed);
    error PriceFeedAlreadyConfigured(address quoteAsset);
    error PriceFeedNotConfigured(address quoteAsset);
    error PriceFeedDisabled(address quoteAsset);
    error FeedStatusUnchanged(address quoteAsset, bool enabled);
    error UnsupportedFeedDecimals(uint8 decimals);
    error InvalidPrice(address quoteAsset, int256 answer);
    error InvalidTimestamp(address quoteAsset, uint256 updatedAt);
    error StalePrice(address quoteAsset, uint256 updatedAt, uint256 maxAge);
    error IncompleteRound(address quoteAsset, uint80 roundId, uint80 answeredInRound);
    error PriceOverflow(address quoteAsset, int256 answer, uint8 feedDecimals);

    /// @notice Sole address permitted to mutate oracle policy. Immutable.
    address public immutable oracleAuthority;

    /// @notice Per-quote Chainlink feed configuration.
    /// @dev Packed into one storage slot. `feed` identity is write-once after configureFeed.
    struct PriceFeedConfig {
        address feed;
        uint48 maxAge;
        uint8 feedDecimals;
        bool enabled;
    }

    mapping(address quoteAsset => PriceFeedConfig) private _priceFeeds;
    mapping(address quoteAsset => bool) private _configured;

    event PriceFeedConfigured(address indexed quoteAsset, address indexed feed, uint48 maxAge, uint8 feedDecimals);
    event PriceFeedStatusChanged(address indexed quoteAsset, bool enabled);
    event MaxAgeUpdated(address indexed quoteAsset, uint48 oldMaxAge, uint48 newMaxAge);

    constructor(address oracleAuthority_) {
        if (oracleAuthority_ == address(0)) revert ZeroOracleAuthority();
        oracleAuthority = oracleAuthority_;
    }

    modifier onlyAuthority() {
        if (msg.sender != oracleAuthority) revert Unauthorized();
        _;
    }

    /**
     * @notice Permanently configure a Chainlink AggregatorV3 feed for `quoteAsset`.
     * @dev Write-once for feed identity. Starts enabled. Does not require a currently fresh answer
     *      (equity feeds may legitimately be off-hours at configuration time).
     * @param quoteAsset Quote asset identifier; `address(0)` means native ETH.
     * @param feed Non-zero AggregatorV3 proxy with bytecode.
     * @param maxAge Maximum allowed answer age in seconds (`block.timestamp - updatedAt`).
     */
    function configureFeed(address quoteAsset, address feed, uint48 maxAge) external onlyAuthority {
        if (_configured[quoteAsset]) revert PriceFeedAlreadyConfigured(quoteAsset);
        if (feed == address(0)) revert ZeroFeed();
        if (maxAge == 0) revert ZeroMaxAge();
        if (feed.code.length == 0) revert FeedHasNoCode(feed);

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals > 18) revert UnsupportedFeedDecimals(feedDecimals);

        _configured[quoteAsset] = true;
        _priceFeeds[quoteAsset] =
            PriceFeedConfig({feed: feed, maxAge: maxAge, feedDecimals: feedDecimals, enabled: true});

        emit PriceFeedConfigured(quoteAsset, feed, maxAge, feedDecimals);
    }

    /**
     * @notice Enable or disable a configured quote feed.
     * @dev Does not erase feed identity or maxAge. Reverts if status is unchanged.
     */
    function setFeedEnabled(address quoteAsset, bool enabled) external onlyAuthority {
        if (!_configured[quoteAsset]) revert PriceFeedNotConfigured(quoteAsset);
        if (_priceFeeds[quoteAsset].enabled == enabled) revert FeedStatusUnchanged(quoteAsset, enabled);

        _priceFeeds[quoteAsset].enabled = enabled;
        emit PriceFeedStatusChanged(quoteAsset, enabled);
    }

    /**
     * @notice Update staleness tolerance for a configured quote feed.
     * @dev Does not change feed identity. `maxAge` must be > 0.
     */
    function setMaxAge(address quoteAsset, uint48 maxAge) external onlyAuthority {
        if (!_configured[quoteAsset]) revert PriceFeedNotConfigured(quoteAsset);
        if (maxAge == 0) revert ZeroMaxAge();

        uint48 oldMaxAge = _priceFeeds[quoteAsset].maxAge;
        _priceFeeds[quoteAsset].maxAge = maxAge;
        emit MaxAgeUpdated(quoteAsset, oldMaxAge, maxAge);
    }

    /**
     * @notice USD price of one whole unit of `quoteAsset`, normalized to 1e18 precision.
     * @dev `1e18 = $1.00`. Reads Chainlink `latestRoundData()`, validates answer/timestamp/
     *      freshness/round completeness, then scales by `10 ** (18 - feedDecimals)`.
     *      Does NOT apply Stock Token `uiMultiplier()` — equity feeds are already adjusted.
     */
    function getPriceUsd(address quoteAsset) external view returns (uint256 priceUsd) {
        if (!_configured[quoteAsset]) revert PriceFeedNotConfigured(quoteAsset);

        PriceFeedConfig memory config = _priceFeeds[quoteAsset];
        if (!config.enabled) revert PriceFeedDisabled(quoteAsset);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(config.feed).latestRoundData();

        if (answer <= 0) revert InvalidPrice(quoteAsset, answer);
        if (updatedAt == 0) revert InvalidTimestamp(quoteAsset, updatedAt);
        if (updatedAt > block.timestamp) revert InvalidTimestamp(quoteAsset, updatedAt);
        if (block.timestamp - updatedAt > config.maxAge) {
            revert StalePrice(quoteAsset, updatedAt, config.maxAge);
        }
        if (answeredInRound < roundId) revert IncompleteRound(quoteAsset, roundId, answeredInRound);

        return _normalize(quoteAsset, answer, config.feedDecimals);
    }

    /// @notice Whether `quoteAsset` has a permanently configured feed.
    function isConfigured(address quoteAsset) external view returns (bool) {
        return _configured[quoteAsset];
    }

    /// @notice Whether `quoteAsset` is configured and currently enabled.
    function isEnabled(address quoteAsset) external view returns (bool) {
        return _configured[quoteAsset] && _priceFeeds[quoteAsset].enabled;
    }

    /// @notice Full feed config for a configured quote asset.
    function getFeedConfig(address quoteAsset) external view returns (PriceFeedConfig memory) {
        if (!_configured[quoteAsset]) revert PriceFeedNotConfigured(quoteAsset);
        return _priceFeeds[quoteAsset];
    }

    function _normalize(address quoteAsset, int256 answer, uint8 feedDecimals)
        internal
        pure
        returns (uint256 priceUsd)
    {
        uint256 raw = uint256(answer);
        if (feedDecimals == 18) return raw;

        uint256 scale = 10 ** uint256(18 - feedDecimals);
        if (raw > type(uint256).max / scale) revert PriceOverflow(quoteAsset, answer, feedDecimals);
        return raw * scale;
    }
}
