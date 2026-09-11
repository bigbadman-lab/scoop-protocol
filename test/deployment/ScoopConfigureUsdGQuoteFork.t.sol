// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ConfigureUsdGQuoteLogic as Logic} from "../../script/ConfigureUsdGQuoteLogic.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ScoopFeeTypes} from "../../src/libraries/ScoopFeeTypes.sol";
import {ScoopFeeConfigFactoryGuard} from "../helpers/ScoopFeeConfigFactoryGuard.sol";

/// @dev External wrapper so `vm.expectRevert` observes library reverts at correct call depth.
contract ConfigureUsdGQuoteHarness {
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

    function assertFeedLiveAndFresh(address feed, uint48 maxAge) external view {
        Logic.assertFeedLiveAndFresh(feed, maxAge);
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
 * @title ScoopConfigureUsdGQuoteForkTest
 * @notice Fork validation of guarded USDG configuration against the CANONICAL SCOOP stack.
 * @dev Never broadcasts. Authority is impersonated on the fork only.
 *      QR/PO are supplied as test constants matching Phase A canonical deployments — the
 *      production script loads the same targets via SCOOP_QUOTE_REGISTRY / SCOOP_PRICE_ORACLE.
 *      Historical SCOOP V1 addresses are intentionally absent from this suite.
 */
contract ScoopConfigureUsdGQuoteForkTest is Test {
    // Canonical Phase A production stack (NOT historical Factory 0x15E874…).
    ScoopFactory internal constant FACTORY = ScoopFactory(0x4B227d5E6199f42ceA4e638875fF8C740757DD3C);
    ScoopCreatorRegistry internal constant CREATOR_REGISTRY =
        ScoopCreatorRegistry(0xC99ec41AAe874B02D6e7392B43b713B6dD2E03C2);
    address internal constant CANONICAL_QUOTE_REGISTRY = 0xE3782bef83cfB17B5a84B2649405a944dc58e40C;
    address internal constant CANONICAL_PRICE_ORACLE = 0x346a84fbAB49a50a2255F2808fd6BCe812DaFe5c;

    ConfigureUsdGQuoteHarness internal harness;
    address internal creator;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        require(block.chainid == 4663, "wrong chain");
        require(address(FACTORY.quoteRegistry()) == CANONICAL_QUOTE_REGISTRY, "factory QR mismatch");
        require(address(FACTORY.priceOracle()) == CANONICAL_PRICE_ORACLE, "factory PO mismatch");
        harness = new ConfigureUsdGQuoteHarness();
        creator = makeAddr("usdgConfigCreator_FORK_ONLY");
        vm.deal(creator, 5 ether);
    }

    function test_fork_happyPath_configuresUsdGOracleFirstThenRegister() public {
        Logic.EthSnapshot memory ethBefore = Logic.snapshotEth(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE);

        Logic.assertCanonicalEnvironment(
            block.chainid, CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED
        );
        Logic.assertUsdGMetadata(Logic.USDG);
        Logic.assertFeedLiveAndFresh(Logic.USDG_USD_FEED, Logic.USDG_MAX_AGE);
        Logic.assertNotYetConfigured(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG);

        bytes32 feedConfiguredTopic0 = keccak256("PriceFeedConfigured(address,address,uint48,uint8)");
        bytes32 quoteRegisteredTopic0 = keccak256("QuoteRegistered(address,uint8)");

        vm.recordLogs();
        vm.startPrank(Logic.AUTHORITY);
        Logic.executeConfiguration(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 feedIdx = -1;
        int256 quoteIdx = -1;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == CANONICAL_PRICE_ORACLE && logs[i].topics.length > 0
                    && logs[i].topics[0] == feedConfiguredTopic0
            ) {
                feedIdx = int256(i);
                assertEq(address(uint160(uint256(logs[i].topics[1]))), Logic.USDG);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), Logic.USDG_USD_FEED);
            }
            if (
                logs[i].emitter == CANONICAL_QUOTE_REGISTRY && logs[i].topics.length > 0
                    && logs[i].topics[0] == quoteRegisteredTopic0
            ) {
                quoteIdx = int256(i);
                assertEq(address(uint160(uint256(logs[i].topics[1]))), Logic.USDG);
            }
        }
        assertTrue(feedIdx >= 0, "missing PriceFeedConfigured");
        assertTrue(quoteIdx >= 0, "missing QuoteRegistered");
        assertTrue(feedIdx < quoteIdx, "oracle must configure before registerQuote");

        Logic.assertPostconditions(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED);
        Logic.assertEthUnchanged(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, ethBefore);
        console2.log("usdgPriceUsd", ScoopPriceOracle(CANONICAL_PRICE_ORACLE).getPriceUsd(Logic.USDG));
    }

    function test_guard_wrongChainId() public {
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongChainId.selector, uint256(4663), uint256(1)));
        harness.assertCanonicalEnvironment(
            1, CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED
        );
    }

    function test_guard_zeroRegistry() public {
        vm.expectRevert(Logic.ZeroQuoteRegistry.selector);
        harness.assertCanonicalEnvironment(4663, address(0), CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_zeroOracle() public {
        vm.expectRevert(Logic.ZeroPriceOracle.selector);
        harness.assertCanonicalEnvironment(4663, CANONICAL_QUOTE_REGISTRY, address(0), Logic.USDG, Logic.USDG_USD_FEED);
    }

    function test_guard_wrongUsdG() public {
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongUsdG.selector, Logic.USDG, address(0xBEEF)));
        harness.assertCanonicalEnvironment(
            4663, CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, address(0xBEEF), Logic.USDG_USD_FEED
        );
    }

    function test_guard_wrongFeed() public {
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongUsdGFeed.selector, Logic.USDG_USD_FEED, address(0xBEEF)));
        harness.assertCanonicalEnvironment(
            4663, CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, address(0xBEEF)
        );
    }

    function test_guard_unauthorizedCaller() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert(abi.encodeWithSelector(Logic.WrongCaller.selector, Logic.AUTHORITY, attacker));
        harness.assertCallerIsAuthority(attacker);
    }

    function test_fork_refuseAlreadyConfiguredOracle() public {
        vm.prank(Logic.AUTHORITY);
        ScoopPriceOracle(CANONICAL_PRICE_ORACLE).configureFeed(Logic.USDG, Logic.USDG_USD_FEED, Logic.USDG_MAX_AGE);

        vm.expectRevert(Logic.UsdGOracleAlreadyConfigured.selector);
        harness.assertNotYetConfigured(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG);
    }

    function test_fork_refuseAlreadyRegisteredQuote() public {
        vm.prank(Logic.AUTHORITY);
        ScoopQuoteRegistry(CANONICAL_QUOTE_REGISTRY).registerQuote(Logic.USDG, ScoopQuoteRegistry.QuoteType.Scoop);

        vm.expectRevert(Logic.UsdGAlreadyRegistered.selector);
        harness.assertNotYetConfigured(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG);
    }

    function test_guard_staleFeed() public {
        vm.mockCall(
            Logic.USDG_USD_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(1e8), uint256(0), uint256(1), uint80(1))
        );
        vm.warp(Logic.USDG_MAX_AGE + 100);

        vm.expectRevert(
            abi.encodeWithSelector(
                Logic.StaleFeed.selector, uint256(1), uint256(Logic.USDG_MAX_AGE), uint256(Logic.USDG_MAX_AGE + 100)
            )
        );
        harness.assertFeedLiveAndFresh(Logic.USDG_USD_FEED, Logic.USDG_MAX_AGE);
    }

    function test_fork_ethConfigUnchangedAfterUsdGConfig() public {
        Logic.EthSnapshot memory ethBefore = Logic.snapshotEth(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE);
        assertTrue(ethBefore.registered);
        assertTrue(ethBefore.enabled);
        assertEq(ethBefore.feed, Logic.ETH_USD_FEED);
        assertEq(ethBefore.maxAge, Logic.ETH_MAX_AGE);

        vm.startPrank(Logic.AUTHORITY);
        Logic.executeConfiguration(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED);
        vm.stopPrank();

        Logic.assertEthUnchanged(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, ethBefore);
    }

    function test_fork_fullLaunchRehearsalAgainstUsdG() public {
        ScoopFeeConfigFactoryGuard.skipUnlessFeeConfig(FACTORY);
        vm.startPrank(Logic.AUTHORITY);
        Logic.executeConfiguration(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED);
        vm.stopPrank();
        Logic.assertPostconditions(CANONICAL_QUOTE_REGISTRY, CANONICAL_PRICE_ORACLE, Logic.USDG, Logic.USDG_USD_FEED);

        uint256 quoteIn = 25e6;
        deal(Logic.USDG, creator, quoteIn);
        assertEq(IERC20(Logic.USDG).balanceOf(creator), quoteIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "UsdGConfigRehearsal",
            symbol: "UCFG",
            creatorId: CREATOR_REGISTRY.walletCreatorId(creator),
            quoteAsset: Logic.USDG,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(6201)),
            additionalFee: 0,
            creatorAllocationDestination: ScoopFeeTypes.CreatorAllocationDestination.Creator,
            additionalFeeDestination: ScoopFeeTypes.AdditionalFeeDestination.Creator
        });

        uint256 fee = FACTORY.LAUNCH_FEE();
        assertEq(fee, 0.0005 ether);

        uint256 feeRecipientBefore = FACTORY.launchFeeRecipient().balance;
        uint256 factoryEthBefore = address(FACTORY).balance;
        uint256 factoryUsdGBefore = IERC20(Logic.USDG).balanceOf(address(FACTORY));

        vm.startPrank(creator);
        IERC20(Logic.USDG).approve(address(FACTORY), quoteIn);
        (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId,, uint256 bought) =
            FACTORY.launchAndBuy{value: fee}(params, quoteIn, 1);
        vm.stopPrank();

        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(creator), bought);
        assertEq(IERC20(Logic.USDG).balanceOf(address(FACTORY)), factoryUsdGBefore);
        assertEq(IERC20(token).balanceOf(address(FACTORY)), 0);
        assertEq(address(FACTORY).balance, factoryEthBefore);
        assertEq(FACTORY.launchFeeRecipient().balance - feeRecipientBefore, fee);

        ScoopFactory.Launch memory rec = FACTORY.getLaunch(token);
        assertEq(rec.quoteAsset, Logic.USDG);
        assertEq(rec.token, token);
        assertEq(rec.feeDistributor, feeDistributor);
        assertEq(rec.liquidityLocker, liquidityLocker);
        assertEq(rec.lpTokenId, lpTokenId);
        assertEq(IERC721(address(FACTORY.positionManager())).ownerOf(lpTokenId), liquidityLocker);

        console2.log("rehearsal token", token);
        console2.log("rehearsal bought", bought);
        console2.log("rehearsal lpTokenId", lpTokenId);
    }
}
