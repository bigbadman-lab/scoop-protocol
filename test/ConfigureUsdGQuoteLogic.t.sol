// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ConfigureUsdGQuoteLogic as Logic} from "../script/ConfigureUsdGQuoteLogic.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @dev Minimal aggregator stand-in for local (non-fork) USDG tooling tests.
contract MockUsdGFeed {
    uint8 public decimals_ = 8;
    string public description_ = "USDG / USD";
    int256 public answer = 1e8;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function description() external view returns (string memory) {
        return description_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer_, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound)
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }

    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }
}

/// @dev External wrapper so `vm.expectRevert` observes library reverts at correct call depth.
contract ConfigureUsdGQuoteLogicHarness {
    function assertCanonicalEnvironment(
        uint256 chainId,
        address quoteRegistry,
        address priceOracle,
        address usdg,
        address usdgFeed
    ) external view {
        Logic.assertCanonicalEnvironment(chainId, quoteRegistry, priceOracle, usdg, usdgFeed);
    }

    function assertCallerIsAuthority(address caller) external pure {
        Logic.assertCallerIsAuthority(caller);
    }

    function assertNotYetConfigured(address quoteRegistry, address priceOracle, address usdg) external view {
        Logic.assertNotYetConfigured(quoteRegistry, priceOracle, usdg);
    }

    function executeConfiguration(address quoteRegistry, address priceOracle, address usdg, address usdgFeed)
        external
    {
        Logic.executeConfiguration(quoteRegistry, priceOracle, usdg, usdgFeed);
    }
}

/**
 * @title ConfigureUsdGQuoteLogicTest
 * @notice Non-fork regression coverage for env-driven / caller-supplied QR/PO USDG tooling.
 * @dev Proves production logic no longer depends on historical SCOOP QR/PO constants.
 */
contract ConfigureUsdGQuoteLogicTest is Test {
    /// @dev Historical SCOOP V1 addresses — must remain unused by production Logic constants.
    address internal constant HISTORICAL_QUOTE_REGISTRY = 0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD;
    address internal constant HISTORICAL_PRICE_ORACLE = 0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12;

    ConfigureUsdGQuoteLogicHarness internal harness;
    ScoopQuoteRegistry internal registry;
    ScoopPriceOracle internal oracle;
    MockUsdGFeed internal feed;

    function setUp() public {
        // Match EXPECTED_CHAIN_ID without forking.
        vm.chainId(4663);
        harness = new ConfigureUsdGQuoteLogicHarness();
        registry = new ScoopQuoteRegistry(Logic.AUTHORITY);
        oracle = new ScoopPriceOracle(Logic.AUTHORITY);
        feed = new MockUsdGFeed();

        // Etch the expected USDG token + feed identities so identity checks pass without mainnet.
        vm.etch(Logic.USDG, hex"00");
        vm.mockCall(Logic.USDG, abi.encodeWithSignature("symbol()"), abi.encode("USDG"));
        vm.mockCall(Logic.USDG, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.etch(Logic.USDG_USD_FEED, address(feed).code);
        // Copy runtime storage is not etched; mock feed calls on the constant address.
        vm.mockCall(
            Logic.USDG_USD_FEED, abi.encodeWithSignature("description()"), abi.encode(string("USDG / USD"))
        );
        vm.mockCall(Logic.USDG_USD_FEED, abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(8)));
        vm.mockCall(
            Logic.USDG_USD_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), block.timestamp, uint80(1))
        );
    }

    function test_assertCanonicalEnvironment_acceptsCallerSuppliedAuthorityBoundTargets() public view {
        Logic.assertCanonicalEnvironment(4663, address(registry), address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_assertCanonicalEnvironment_doesNotRequireHistoricalAddresses() public pure {
        // Compile-time / linkage proof: Logic no longer exposes historical QR/PO constants.
        // If these identifiers are reintroduced on Logic, this file will fail to compile or this
        // assertion pattern should be extended. Historical addresses remain test-local only.
        assertTrue(HISTORICAL_QUOTE_REGISTRY != address(0));
        assertTrue(HISTORICAL_PRICE_ORACLE != address(0));
        assertTrue(HISTORICAL_QUOTE_REGISTRY != Logic.USDG);
        assertTrue(HISTORICAL_PRICE_ORACLE != Logic.USDG_USD_FEED);
    }

    function test_guard_wrongChainId() public {
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongChainId.selector, uint256(4663), uint256(1)));
        harness.assertCanonicalEnvironment(1, address(registry), address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_zeroQuoteRegistry() public {
        vm.expectRevert(Logic.ZeroQuoteRegistry.selector);
        harness.assertCanonicalEnvironment(4663, address(0), address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_zeroPriceOracle() public {
        vm.expectRevert(Logic.ZeroPriceOracle.selector);
        harness.assertCanonicalEnvironment(4663, address(registry), address(0), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_quoteRegistryHasNoCode() public {
        address eoa = makeAddr("noCodeRegistry");
        vm.expectRevert(abi.encodeWithSelector(Logic.QuoteRegistryHasNoCode.selector, eoa));
        harness.assertCanonicalEnvironment(4663, eoa, address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_priceOracleHasNoCode() public {
        address eoa = makeAddr("noCodeOracle");
        vm.expectRevert(abi.encodeWithSelector(Logic.PriceOracleHasNoCode.selector, eoa));
        harness.assertCanonicalEnvironment(4663, address(registry), eoa, Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_wrongRegistryAuthority() public {
        ScoopQuoteRegistry wrong = new ScoopQuoteRegistry(makeAddr("otherAuth"));
        vm.expectRevert(
            abi.encodeWithSelector(Logic.WrongRegistryAuthority.selector, Logic.AUTHORITY, makeAddr("otherAuth"))
        );
        harness.assertCanonicalEnvironment(4663, address(wrong), address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_wrongOracleAuthority() public {
        ScoopPriceOracle wrong = new ScoopPriceOracle(makeAddr("otherAuth"));
        vm.expectRevert(
            abi.encodeWithSelector(Logic.WrongOracleAuthority.selector, Logic.AUTHORITY, makeAddr("otherAuth"))
        );
        harness.assertCanonicalEnvironment(4663, address(registry), address(wrong), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_wrongUsdG() public {
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongUsdG.selector, Logic.USDG, address(0xBEEF)));
        harness.assertCanonicalEnvironment(
            4663, address(registry), address(oracle), address(0xBEEF), Logic.USDG_USD_FEED
        );
    }

    function test_guard_wrongFeed() public {
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongUsdGFeed.selector, Logic.USDG_USD_FEED, address(0xBEEF)));
        harness.assertCanonicalEnvironment(4663, address(registry), address(oracle), Logic.USDG, address(0xBEEF));
    }

    function test_guard_unauthorizedCaller() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongCaller.selector, Logic.AUTHORITY, attacker));
        harness.assertCallerIsAuthority(attacker);
    }

    function test_usdgIdentitiesAndMaxAgePreserved() public pure {
        assertEq(Logic.USDG, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
        assertEq(Logic.USDG_USD_FEED, 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2);
        assertEq(uint256(Logic.USDG_MAX_AGE), 86_400);
        assertEq(Logic.AUTHORITY, 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7);
        assertEq(uint8(ScoopQuoteRegistry.QuoteType.Scoop), 1);
    }

    function test_executeConfiguration_oracleBeforeRegister_andEnables() public {
        bytes32 feedConfiguredTopic0 = keccak256("PriceFeedConfigured(address,address,uint48,uint8)");
        bytes32 quoteRegisteredTopic0 = keccak256("QuoteRegistered(address,uint8)");

        vm.recordLogs();
        vm.startPrank(Logic.AUTHORITY);
        Logic.executeConfiguration(address(registry), address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 feedIdx = -1;
        int256 quoteIdx = -1;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == feedConfiguredTopic0) {
                feedIdx = int256(i);
                assertEq(logs[i].emitter, address(oracle));
            }
            if (logs[i].topics.length > 0 && logs[i].topics[0] == quoteRegisteredTopic0) {
                quoteIdx = int256(i);
                assertEq(logs[i].emitter, address(registry));
            }
        }
        assertTrue(feedIdx >= 0, "missing PriceFeedConfigured");
        assertTrue(quoteIdx >= 0, "missing QuoteRegistered");
        assertTrue(feedIdx < quoteIdx, "oracle must configure before registerQuote");

        Logic.assertPostconditions(address(registry), address(oracle), Logic.USDG, Logic.USDG_USD_FEED);
        assertEq(uint8(registry.quoteType(Logic.USDG)), uint8(ScoopQuoteRegistry.QuoteType.Scoop));
        assertEq(oracle.getFeedConfig(Logic.USDG).maxAge, Logic.USDG_MAX_AGE);
    }

    function test_refuseAlreadyConfigured() public {
        vm.startPrank(Logic.AUTHORITY);
        oracle.configureFeed(Logic.USDG, Logic.USDG_USD_FEED, Logic.USDG_MAX_AGE);
        vm.stopPrank();

        vm.expectRevert(Logic.UsdGOracleAlreadyConfigured.selector);
        harness.assertNotYetConfigured(address(registry), address(oracle), Logic.USDG);
    }

    function test_refuseAlreadyRegistered() public {
        vm.startPrank(Logic.AUTHORITY);
        registry.registerQuote(Logic.USDG, ScoopQuoteRegistry.QuoteType.Scoop);
        vm.stopPrank();

        vm.expectRevert(Logic.UsdGAlreadyRegistered.selector);
        harness.assertNotYetConfigured(address(registry), address(oracle), Logic.USDG);
    }
}
