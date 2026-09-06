// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @dev Chainlink feeds expose `description()`; omitted from Scoop's minimal IAggregatorV3.
interface IFeedDescription {
    function description() external view returns (string memory);
}

/**
 * @title ConfigureUsdGQuoteLogic
 * @notice Shared, heavily guarded USDG configuration for script + fork tests.
 * @dev Ordering invariant: `configureFeed` FIRST, `registerQuote` SECOND.
 *      Registered quotes start enabled, so the oracle must exist before registration.
 */
library ConfigureUsdGQuoteLogic {
    uint256 internal constant EXPECTED_CHAIN_ID = 4663;

    address internal constant QUOTE_REGISTRY = 0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD;
    address internal constant PRICE_ORACLE = 0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12;
    address internal constant AUTHORITY = 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    uint48 internal constant USDG_MAX_AGE = 86_400;

    /// @dev Live ETH feed identity for unchanged assertions (native quote = address(0)).
    address internal constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    uint48 internal constant ETH_MAX_AGE = 86_400;

    error WrongChainId(uint256 expected, uint256 actual);
    error WrongQuoteRegistry(address expected, address actual);
    error WrongPriceOracle(address expected, address actual);
    error WrongUsdG(address expected, address actual);
    error WrongUsdGFeed(address expected, address actual);
    error WrongRegistryAuthority(address expected, address actual);
    error WrongOracleAuthority(address expected, address actual);
    error WrongCaller(address expected, address actual);
    error UsdGAlreadyRegistered();
    error UsdGOracleAlreadyConfigured();
    error UnexpectedUsdGSymbol(string actual);
    error UnexpectedUsdGDecimals(uint8 actual);
    error UnexpectedFeedDescription(string actual);
    error UnexpectedFeedDecimals(uint8 actual);
    error InvalidFeedAnswer(int256 answer);
    error InvalidFeedUpdatedAt(uint256 updatedAt);
    error StaleFeed(uint256 updatedAt, uint256 maxAge, uint256 nowTs);
    error EthQuoteRegression(string field);
    error PostconditionFailed(string field);

    struct EthSnapshot {
        bool registered;
        bool enabled;
        address feed;
        uint48 maxAge;
        uint8 feedDecimals;
        bool feedEnabled;
    }

    function assertCanonicalEnvironment(
        uint256 chainId,
        address quoteRegistry,
        address priceOracle,
        address usdg,
        address usdgFeed
    ) internal view {
        if (chainId != EXPECTED_CHAIN_ID) revert WrongChainId(EXPECTED_CHAIN_ID, chainId);
        if (quoteRegistry != QUOTE_REGISTRY) revert WrongQuoteRegistry(QUOTE_REGISTRY, quoteRegistry);
        if (priceOracle != PRICE_ORACLE) revert WrongPriceOracle(PRICE_ORACLE, priceOracle);
        if (usdg != USDG) revert WrongUsdG(USDG, usdg);
        if (usdgFeed != USDG_USD_FEED) revert WrongUsdGFeed(USDG_USD_FEED, usdgFeed);

        address regAuth = ScoopQuoteRegistry(quoteRegistry).registryAuthority();
        address oraAuth = ScoopPriceOracle(priceOracle).oracleAuthority();
        if (regAuth != AUTHORITY) revert WrongRegistryAuthority(AUTHORITY, regAuth);
        if (oraAuth != AUTHORITY) revert WrongOracleAuthority(AUTHORITY, oraAuth);
    }

    function assertCallerIsAuthority(address caller) internal pure {
        if (caller != AUTHORITY) revert WrongCaller(AUTHORITY, caller);
    }

    function assertUsdGMetadata(address usdg) internal view {
        string memory symbol = IERC20Metadata(usdg).symbol();
        if (keccak256(bytes(symbol)) != keccak256("USDG")) revert UnexpectedUsdGSymbol(symbol);
        uint8 decimals_ = IERC20Metadata(usdg).decimals();
        if (decimals_ != 6) revert UnexpectedUsdGDecimals(decimals_);
    }

    function assertFeedLiveAndFresh(address feed, uint48 maxAge) internal view {
        string memory desc = IFeedDescription(feed).description();
        if (keccak256(bytes(desc)) != keccak256("USDG / USD")) revert UnexpectedFeedDescription(desc);

        uint8 feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals != 8) revert UnexpectedFeedDecimals(feedDecimals);

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidFeedAnswer(answer);
        if (updatedAt == 0) revert InvalidFeedUpdatedAt(updatedAt);
        if (block.timestamp < updatedAt) revert InvalidFeedUpdatedAt(updatedAt);
        if (block.timestamp - updatedAt > maxAge) revert StaleFeed(updatedAt, maxAge, block.timestamp);
    }

    function assertNotYetConfigured(address quoteRegistry, address priceOracle, address usdg) internal view {
        if (ScoopQuoteRegistry(quoteRegistry).isRegistered(usdg)) revert UsdGAlreadyRegistered();
        if (ScoopPriceOracle(priceOracle).isConfigured(usdg)) revert UsdGOracleAlreadyConfigured();
    }

    function snapshotEth(address quoteRegistry, address priceOracle) internal view returns (EthSnapshot memory snap) {
        ScoopQuoteRegistry registry = ScoopQuoteRegistry(quoteRegistry);
        ScoopPriceOracle oracle = ScoopPriceOracle(priceOracle);
        snap.registered = registry.isRegistered(address(0));
        snap.enabled = registry.isEnabled(address(0));
        ScoopPriceOracle.PriceFeedConfig memory cfg = oracle.getFeedConfig(address(0));
        snap.feed = cfg.feed;
        snap.maxAge = cfg.maxAge;
        snap.feedDecimals = cfg.feedDecimals;
        snap.feedEnabled = cfg.enabled;
    }

    function assertEthUnchanged(address quoteRegistry, address priceOracle, EthSnapshot memory beforeSnap)
        internal
        view
    {
        EthSnapshot memory afterSnap = snapshotEth(quoteRegistry, priceOracle);
        if (!afterSnap.registered || afterSnap.registered != beforeSnap.registered) {
            revert EthQuoteRegression("registered");
        }
        if (!afterSnap.enabled || afterSnap.enabled != beforeSnap.enabled) revert EthQuoteRegression("enabled");
        if (afterSnap.feed != beforeSnap.feed || afterSnap.feed != ETH_USD_FEED) revert EthQuoteRegression("feed");
        if (afterSnap.maxAge != beforeSnap.maxAge || afterSnap.maxAge != ETH_MAX_AGE) {
            revert EthQuoteRegression("maxAge");
        }
        if (afterSnap.feedDecimals != beforeSnap.feedDecimals) revert EthQuoteRegression("feedDecimals");
        if (!afterSnap.feedEnabled || afterSnap.feedEnabled != beforeSnap.feedEnabled) {
            revert EthQuoteRegression("feedEnabled");
        }
    }

    /// @dev Oracle first, then registry — registered quotes start enabled.
    function executeConfiguration(address quoteRegistry, address priceOracle, address usdg, address usdgFeed) internal {
        ScoopPriceOracle(priceOracle).configureFeed(usdg, usdgFeed, USDG_MAX_AGE);
        ScoopQuoteRegistry(quoteRegistry).registerQuote(usdg, ScoopQuoteRegistry.QuoteType.Scoop);
    }

    function assertPostconditions(address quoteRegistry, address priceOracle, address usdg, address usdgFeed)
        internal
        view
    {
        ScoopQuoteRegistry registry = ScoopQuoteRegistry(quoteRegistry);
        ScoopPriceOracle oracle = ScoopPriceOracle(priceOracle);

        if (!registry.isRegistered(usdg)) revert PostconditionFailed("registered");
        if (!registry.isEnabled(usdg)) revert PostconditionFailed("enabled");
        if (registry.quoteType(usdg) != ScoopQuoteRegistry.QuoteType.Scoop) revert PostconditionFailed("quoteType");
        if (!oracle.isConfigured(usdg)) revert PostconditionFailed("oracleConfigured");
        if (!oracle.isEnabled(usdg)) revert PostconditionFailed("oracleEnabled");

        ScoopPriceOracle.PriceFeedConfig memory cfg = oracle.getFeedConfig(usdg);
        if (cfg.feed != usdgFeed) revert PostconditionFailed("feed");
        if (cfg.maxAge != USDG_MAX_AGE) revert PostconditionFailed("maxAge");
        if (!cfg.enabled) revert PostconditionFailed("feedEnabled");
        if (oracle.getPriceUsd(usdg) == 0) revert PostconditionFailed("priceUsd");
    }
}
