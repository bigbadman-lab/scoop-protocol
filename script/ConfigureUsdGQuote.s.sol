// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ConfigureUsdGQuoteLogic as Logic, IFeedDescription} from "./ConfigureUsdGQuoteLogic.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/**
 * @title ConfigureUsdGQuote
 * @notice ONE-PURPOSE Phase 6C.2A/2B tooling: configure canonical USDG on Robinhood SCOOP V1.
 *
 * @dev Ordering invariant (do not reverse):
 *      1) ScoopPriceOracle.configureFeed(USDG, USDG_USD_FEED, 86400)
 *      2) ScoopQuoteRegistry.registerQuote(USDG, QuoteType.Scoop)
 *      Registered quotes start enabled, so the oracle must exist first.
 *
 * Dry-run (NO writes, NO broadcast) — use this in 6C.2A:
 *   forge script script/ConfigureUsdGQuote.s.sol:ConfigureUsdGQuote \
 *     --rpc-url "$ROBINHOOD_RPC_URL" -vvvv
 *
 * DO NOT EXECUTE IN 6C.2A — future 6C.2B mainnet only (explicit opt-in):
 *   SCOOP_USDG_BROADCAST=true forge script script/ConfigureUsdGQuote.s.sol:ConfigureUsdGQuote \
 *     --rpc-url "$ROBINHOOD_RPC_URL" \
 *     --account <authority-keystore-account> \
 *     --sender 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7 \
 *     --broadcast -vvvv
 *
 * Prefer Foundry keystore / hardware signer over raw private keys in shell history.
 * NEVER print private keys. NEVER set SCOOP_USDG_BROADCAST in 6C.2A.
 */
contract ConfigureUsdGQuote is Script {
    function run() external {
        address registry = Logic.QUOTE_REGISTRY;
        address oracle = Logic.PRICE_ORACLE;
        address usdg = Logic.USDG;
        address feed = Logic.USDG_USD_FEED;

        Logic.assertCanonicalEnvironment(block.chainid, registry, oracle, usdg, feed);
        Logic.assertUsdGMetadata(usdg);
        Logic.assertFeedLiveAndFresh(feed, Logic.USDG_MAX_AGE);
        Logic.assertNotYetConfigured(registry, oracle, usdg);

        Logic.EthSnapshot memory ethBefore = Logic.snapshotEth(registry, oracle);
        _logDryRunSummary(ethBefore);

        bool doBroadcast = vm.envOr("SCOOP_USDG_BROADCAST", false);
        if (!doBroadcast) {
            console2.log("MODE", "DRY_RUN_ONLY");
            console2.log("BROADCAST", false);
            console2.log("REFUSING_WRITES", "set SCOOP_USDG_BROADCAST=true for 6C.2B only");
            console2.log("NO_MAINNET_TRANSACTION_SENT", true);
            return;
        }

        // Production broadcast path — 6C.2B only.
        Logic.assertCallerIsAuthority(msg.sender);
        console2.log("MODE", "BROADCAST_OPT_IN");
        console2.log("caller", msg.sender);

        vm.startBroadcast();
        Logic.executeConfiguration(registry, oracle, usdg, feed);
        vm.stopBroadcast();

        Logic.assertPostconditions(registry, oracle, usdg, feed);
        Logic.assertEthUnchanged(registry, oracle, ethBefore);

        console2.log("USDG_CONFIGURED", true);
        console2.log("usdgPriceUsd", ScoopPriceOracle(oracle).getPriceUsd(usdg));
        console2.log("NO_PARTIAL_STATE", true);
    }

    function _logDryRunSummary(Logic.EthSnapshot memory ethBefore) internal view {
        IAggregatorV3 agg = IAggregatorV3(Logic.USDG_USD_FEED);
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();

        console2.log("==== USDG CONFIG DRY-RUN SUMMARY ====");
        console2.log("chainId", block.chainid);
        console2.log("caller", msg.sender);
        console2.log("quoteRegistry", Logic.QUOTE_REGISTRY);
        console2.log("priceOracle", Logic.PRICE_ORACLE);
        console2.log("authority", Logic.AUTHORITY);
        console2.log("USDG", Logic.USDG);
        console2.log("USDG_symbol", IERC20Metadata(Logic.USDG).symbol());
        console2.log("USDG_decimals", uint256(IERC20Metadata(Logic.USDG).decimals()));
        console2.log("feed", Logic.USDG_USD_FEED);
        console2.log("feed_description", IFeedDescription(Logic.USDG_USD_FEED).description());
        console2.log("feed_decimals", uint256(agg.decimals()));
        console2.log("feed_answer", uint256(answer));
        console2.log("feed_updatedAt", updatedAt);
        console2.log("feed_age_seconds", block.timestamp - updatedAt);
        console2.log("maxAge", uint256(Logic.USDG_MAX_AGE));
        console2.log("pre_usdgRegistered", ScoopQuoteRegistry(Logic.QUOTE_REGISTRY).isRegistered(Logic.USDG));
        console2.log("pre_usdgOracleConfigured", ScoopPriceOracle(Logic.PRICE_ORACLE).isConfigured(Logic.USDG));
        console2.log("eth_registered", ethBefore.registered);
        console2.log("eth_enabled", ethBefore.enabled);
        console2.log("eth_feed", ethBefore.feed);
        console2.log("eth_maxAge", uint256(ethBefore.maxAge));
        console2.log("planned_op_1", "PRICE_ORACLE.configureFeed(USDG, USDG_USD_FEED, 86400)");
        console2.log("planned_op_2", "QUOTE_REGISTRY.registerQuote(USDG, QuoteType.Scoop)");
        console2.log("expected_tx_count", uint256(2));
        console2.log("ordering", "oracle-first then registerQuote");
    }
}
