// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopToken} from "../src/ScoopToken.sol";

/// @dev Standard Chainlink AggregatorV3Interface (proxy).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Robinhood Stock Token ERC-8056 + oracle pause surface used for discovery.
interface IRobinhoodStockToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function uid() external view returns (bytes32);
    function uiMultiplier() external view returns (uint256);
    function oraclePaused() external view returns (bool);
}

/**
 * @title RobinhoodOracleDiscoveryForkTest
 * @notice Milestone 4D.1: prove live ETH/USD and Stock Token/USD oracle reads on Robinhood Chain.
 * @dev Discovery-only. Does NOT implement ScoopPriceOracle or modify production contracts.
 *
 * Address provenance (documented — not guessed):
 *
 * 1. AAPL Stock Token `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9`
 *    - Official Robinhood REST: GET https://api.robinhood.com/rhj/assets (tokenSymbol=AAPL, chainId=4663)
 *    - Cross-checked onchain: symbol()=="AAPL", name contains "Robinhood Token", uid matches API `id`
 *    - Also appears in Robinhood docs corporate-actions example for AAPL
 *
 * 2. RHAAPL/USD feed proxy `0x6B22A786bAa607d76728168703a39Ea9C99f2cD0`
 *    - Chainlink canonical directory: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
 *      entry name "Robinhood AAPL / USD", docs.baseAsset=AAPL
 *    - Robinhood docs: feed addresses are maintained by Chainlink; directory is source of truth
 *
 * 3. ETH/USD feed proxy `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9`
 *    - Same Chainlink directory entry name "ETH / USD"
 *
 * Stock Token → feed mapping: NO onchain feed address on the token (probed: priceFeed/oracle/feed absent).
 * Mapping is offchain via Chainlink directory + Robinhood docs. Future ScoopPriceOracle should store
 * configured AggregatorV3 proxy addresses (not discover them from the ERC-20).
 *
 * Multiplier: Chainlink equity feeds already incorporate uiMultiplier(); SCOOP must NOT re-apply it.
 */
contract RobinhoodOracleDiscoveryForkTest is Test {
    uint256 constant EXPECTED_CHAIN_ID = 4663;

    /// @dev Official Robinhood AAPL Stock Token (chain 4663) — see file header provenance.
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    /// @dev Chainlink directory proxy: "Robinhood AAPL / USD"
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    /// @dev Chainlink directory proxy: "ETH / USD"
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    /// @dev Documented Data Streams Verifier Proxy (inspected only; not required for launch pricing).
    address constant DATA_STREAMS_VERIFIER = 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7;

    /// @dev Official API asset id for AAPL — must match onchain uid().
    bytes32 constant AAPL_UID = 0x00000000000000000000000000000000c2425be3658540dd8e2424cbf3c5c649;

    IRobinhoodStockToken internal aapl;
    AggregatorV3Interface internal aaplFeed;
    AggregatorV3Interface internal ethFeed;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        aapl = IRobinhoodStockToken(AAPL_TOKEN);
        aaplFeed = AggregatorV3Interface(AAPL_USD_FEED);
        ethFeed = AggregatorV3Interface(ETH_USD_FEED);
    }

    function test_robinhoodChainIdIs4663() public view {
        assertEq(block.chainid, EXPECTED_CHAIN_ID);
    }

    function test_selectedStockTokenHasBytecode() public view {
        assertGt(AAPL_TOKEN.code.length, 0, "AAPL token missing bytecode");
    }

    function test_selectedStockTokenUses18Decimals() public view {
        assertEq(aapl.decimals(), 18);
        assertEq(keccak256(bytes(aapl.symbol())), keccak256(bytes("AAPL")));
        assertEq(aapl.uid(), AAPL_UID);

        console2.log("stock symbol", aapl.symbol());
        console2.log("stock name", aapl.name());
        console2.log("stock token", AAPL_TOKEN);
        console2.log("stock decimals", aapl.decimals());
    }

    function test_scoopTokenUses18Decimals() public {
        ScoopToken token = new ScoopToken("Scoop", "SCP", address(this));
        assertEq(token.decimals(), 18);
        console2.log("ScoopToken decimals", token.decimals());
    }

    function test_stockTokenMultiplierReadable() public view {
        uint256 multiplier = aapl.uiMultiplier();
        // ERC-8056: 1e18 = 1.0 shares-per-token. Current AAPL has slight dividend drift above 1e18.
        assertGt(multiplier, 0);
        assertFalse(aapl.oraclePaused());

        console2.log("uiMultiplier (1e18=1.0)", multiplier);
        console2.log("oraclePaused", aapl.oraclePaused());
        console2.log(
            "NOTE: Chainlink Stock feed answer already includes this multiplier; do NOT re-apply in ScoopPriceOracle"
        );
    }

    function test_stockTokenDoesNotExposeOnchainFeedAddress() public view {
        // Discovery: no canonical on-token feed getter — mapping is offchain (Chainlink directory).
        (bool okFeed,) = AAPL_TOKEN.staticcall(abi.encodeWithSignature("priceFeed()"));
        (bool okOracle,) = AAPL_TOKEN.staticcall(abi.encodeWithSignature("oracle()"));
        (bool okGetFeed,) = AAPL_TOKEN.staticcall(abi.encodeWithSignature("getPriceFeed()"));
        (bool okFeedAddr,) = AAPL_TOKEN.staticcall(abi.encodeWithSignature("feed()"));
        (bool okAgg,) = AAPL_TOKEN.staticcall(abi.encodeWithSignature("aggregator()"));
        assertFalse(
            okFeed || okOracle || okGetFeed || okFeedAddr || okAgg, "unexpected on-token feed discovery surface"
        );
    }

    function test_stockPriceFeedHasBytecode() public view {
        assertGt(AAPL_USD_FEED.code.length, 0, "AAPL/USD feed missing bytecode");
        console2.log("AAPL/USD feed", AAPL_USD_FEED);
    }

    function test_stockPriceFeedMetadataReadable() public view {
        uint8 decimals_ = aaplFeed.decimals();
        string memory description_ = aaplFeed.description();
        uint256 version_ = aaplFeed.version();

        assertEq(decimals_, 8);
        assertEq(keccak256(bytes(description_)), keccak256(bytes("Robinhood AAPL / USD")));
        assertGt(version_, 0);

        console2.log("stock feed description", description_);
        console2.log("stock feed decimals", decimals_);
        console2.log("stock feed version", version_);
    }

    function test_stockPriceFeedReturnsPositivePrice() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            aaplFeed.latestRoundData();

        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        assertLe(updatedAt, block.timestamp);
        assertGe(answeredInRound, roundId);

        uint256 age = block.timestamp - updatedAt;
        // Human-readable USD at feed decimals (8): answer / 1e8
        console2.log("stock roundId", uint256(roundId));
        console2.log("stock raw answer", uint256(answer));
        console2.log("stock startedAt", startedAt);
        console2.log("stock updatedAt", updatedAt);
        console2.log("stock answeredInRound", uint256(answeredInRound));
        console2.log("stock age seconds", age);
        console2.log("stock USD (answer/1e8 scaled*1e8)", uint256(answer)); // log raw; divide offchain
        _logUsd("stock USD approx (8dp)", answer, 8);
    }

    function test_stockPriceFeedTimestampValid() public view {
        (,,, uint256 updatedAt,) = aaplFeed.latestRoundData();
        assertGt(updatedAt, 0);
        assertLe(updatedAt, block.timestamp);
    }

    function test_ethUsdFeedHasBytecode() public view {
        assertGt(ETH_USD_FEED.code.length, 0, "ETH/USD feed missing bytecode");
        console2.log("ETH/USD feed", ETH_USD_FEED);
    }

    function test_ethUsdFeedMetadataReadable() public view {
        uint8 decimals_ = ethFeed.decimals();
        string memory description_ = ethFeed.description();
        uint256 version_ = ethFeed.version();

        assertEq(decimals_, 8);
        assertEq(keccak256(bytes(description_)), keccak256(bytes("ETH / USD")));
        assertGt(version_, 0);

        console2.log("ETH feed description", description_);
        console2.log("ETH feed decimals", decimals_);
        console2.log("ETH feed version", version_);
    }

    function test_ethUsdFeedReturnsPositivePrice() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            ethFeed.latestRoundData();

        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        assertLe(updatedAt, block.timestamp);
        assertGe(answeredInRound, roundId);

        uint256 age = block.timestamp - updatedAt;
        console2.log("ETH roundId", uint256(roundId));
        console2.log("ETH raw answer", uint256(answer));
        console2.log("ETH startedAt", startedAt);
        console2.log("ETH updatedAt", updatedAt);
        console2.log("ETH answeredInRound", uint256(answeredInRound));
        console2.log("ETH age seconds", age);
        _logUsd("ETH USD approx (8dp)", answer, 8);
    }

    function test_ethUsdFeedTimestampValid() public view {
        (,,, uint256 updatedAt,) = ethFeed.latestRoundData();
        assertGt(updatedAt, 0);
        assertLe(updatedAt, block.timestamp);
    }

    function test_bothFeedsShareAggregatorV3Interface() public view {
        // Same interface path for Native ETH and Stock Token pricing.
        ethFeed.decimals();
        aaplFeed.decimals();
        ethFeed.latestRoundData();
        aaplFeed.latestRoundData();
        ethFeed.description();
        aaplFeed.description();
        ethFeed.version();
        aaplFeed.version();
    }

    function test_dataStreamsVerifierHasBytecode_butNotRequired() public view {
        assertGt(DATA_STREAMS_VERIFIER.code.length, 0);
        console2.log("Data Streams Verifier Proxy", DATA_STREAMS_VERIFIER);
        console2.log("bytecode size", DATA_STREAMS_VERIFIER.code.length);
        console2.log("CONCLUSION: normal AggregatorV3 Data Feeds exist for ETH/USD and AAPL/USD");
        console2.log("Data Streams NOT required for Scoop launch pricing");
    }

    function test_logDiscoverySummary() public view {
        (, int256 stockAnswer,, uint256 stockUpdatedAt,) = aaplFeed.latestRoundData();
        (, int256 ethAnswer,, uint256 ethUpdatedAt,) = ethFeed.latestRoundData();

        console2.log("=== 4D.1 DISCOVERY SUMMARY ===");
        console2.log("chainId", block.chainid);
        console2.log("AAPL token", AAPL_TOKEN);
        console2.log("AAPL symbol", aapl.symbol());
        console2.log("AAPL decimals", aapl.decimals());
        console2.log("AAPL uiMultiplier", aapl.uiMultiplier());
        console2.log("AAPL feed", AAPL_USD_FEED);
        console2.log("AAPL feed description", aaplFeed.description());
        console2.log("AAPL feed decimals", aaplFeed.decimals());
        console2.log("AAPL raw answer", uint256(stockAnswer));
        console2.log("AAPL updatedAt", stockUpdatedAt);
        console2.log("AAPL age", block.timestamp - stockUpdatedAt);
        console2.log("ETH feed", ETH_USD_FEED);
        console2.log("ETH feed description", ethFeed.description());
        console2.log("ETH feed decimals", ethFeed.decimals());
        console2.log("ETH raw answer", uint256(ethAnswer));
        console2.log("ETH updatedAt", ethUpdatedAt);
        console2.log("ETH age", block.timestamp - ethUpdatedAt);
        _logUsd("AAPL USD", stockAnswer, 8);
        _logUsd("ETH USD", ethAnswer, 8);
    }

    /// @dev Logs integer and fractional parts of answer / 10^decimals without asserting a fixed price.
    function _logUsd(string memory label, int256 answer, uint8 decimals_) internal pure {
        require(answer > 0, "non-positive");
        uint256 scale = 10 ** uint256(decimals_);
        uint256 raw = uint256(answer);
        uint256 whole = raw / scale;
        uint256 frac = raw % scale;
        console2.log(label);
        console2.log("  whole", whole);
        console2.log("  frac(8dp raw remainder)", frac);
    }
}
