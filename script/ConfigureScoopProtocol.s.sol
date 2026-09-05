// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopProtocolDeploy} from "./ScoopProtocolDeploy.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";

/**
 * @title ConfigureScoopProtocol
 * @notice PHASE B - Scoop Auth 1 only. Registers native ETH + configures ETH/USD oracle. Deploys nothing.
 *
 * @dev Required env:
 *      REGISTRY_AUTHORITY
 *      ORACLE_AUTHORITY          (must equal REGISTRY_AUTHORITY for MVP)
 *      SCOOP_QUOTE_REGISTRY      (from Phase A handoff)
 *      SCOOP_PRICE_ORACLE        (from Phase A handoff)
 *      SCOOP_ETH_MAX_AGE         (proposed production: 86400)
 *
 * Simulation (5C.1 - no broadcast):
 *   forge script script/ConfigureScoopProtocol.s.sol:ConfigureScoopProtocol \
 *     --rpc-url "$ROBINHOOD_RPC_URL" --sender "$REGISTRY_AUTHORITY" -vvvv
 *
 * Future 5D broadcast (explicit only):
 *   SCOOP_BROADCAST=true forge script ... --sender "$REGISTRY_AUTHORITY" --broadcast
 *
 * AAPL is intentionally NOT configured here.
 * NEVER broadcast in 5C.1. NEVER print private keys.
 *
 * NOTE: Separate forge script simulations do not share ephemeral CREATE state across processes.
 * End-to-end two-signer persistence is proven in test/deployment/ScoopMultiSignerDeploymentFork.t.sol.
 */
contract ConfigureScoopProtocol is Script {
    function run() external {
        ScoopProtocolDeploy.requireRobinhoodChain();

        address authority = vm.envAddress("REGISTRY_AUTHORITY");
        address oracleAuthority = vm.envAddress("ORACLE_AUTHORITY");
        require(authority == oracleAuthority, "ConfigureScoopProtocol: REGISTRY_AUTHORITY must equal ORACLE_AUTHORITY");
        ScoopProtocolDeploy.requireSender(authority, "REGISTRY_AUTHORITY");

        address quoteRegistryAddr = vm.envAddress("SCOOP_QUOTE_REGISTRY");
        address priceOracleAddr = vm.envAddress("SCOOP_PRICE_ORACLE");
        uint48 ethMaxAge = uint48(vm.envUint("SCOOP_ETH_MAX_AGE"));
        require(ethMaxAge > 0, "ConfigureScoopProtocol: SCOOP_ETH_MAX_AGE required");

        ScoopQuoteRegistry quoteRegistry = ScoopQuoteRegistry(quoteRegistryAddr);
        ScoopPriceOracle priceOracle = ScoopPriceOracle(priceOracleAddr);

        require(address(quoteRegistry).code.length > 0, "ConfigureScoopProtocol: QuoteRegistry has no code");
        require(address(priceOracle).code.length > 0, "ConfigureScoopProtocol: PriceOracle has no code");
        require(quoteRegistry.registryAuthority() == authority, "ConfigureScoopProtocol: registryAuthority mismatch");
        require(priceOracle.oracleAuthority() == oracleAuthority, "ConfigureScoopProtocol: oracleAuthority mismatch");

        // Refuse to no-op / double-configure silently.
        require(!quoteRegistry.isRegistered(address(0)), "ConfigureScoopProtocol: ETH already registered");
        require(!priceOracle.isConfigured(address(0)), "ConfigureScoopProtocol: ETH feed already configured");

        bool doBroadcast = vm.envOr("SCOOP_BROADCAST", false);
        if (doBroadcast) {
            uint256 pk = vm.envUint("AUTHORITY_PRIVATE_KEY");
            vm.startBroadcast(pk);
        } else {
            console2.log("MODE", "SIMULATION");
            console2.log("BROADCAST", false);
        }

        (uint256 qg, uint256 fg) = ScoopProtocolDeploy.configureEthQuoteAndOracle(quoteRegistry, priceOracle, ethMaxAge);

        if (doBroadcast) {
            vm.stopBroadcast();
            console2.log("MODE", "BROADCAST");
        }

        ScoopProtocolDeploy.assertEthConfigured(quoteRegistry, priceOracle, ethMaxAge);
        ScoopProtocolDeploy.assertAaplNotProductionRegistered(quoteRegistry);

        console2.log("==== PHASE B CONFIG MANIFEST ====");
        console2.log("ScoopQuoteRegistry", address(quoteRegistry));
        console2.log("ScoopPriceOracle", address(priceOracle));
        console2.log("ETH_USD_FEED", ScoopProtocolDeploy.ETH_USD_FEED);
        console2.log("ethMaxAge", uint256(ethMaxAge));
        console2.log("ethPriceUsd", priceOracle.getPriceUsd(address(0)));
        console2.log("AAPL_production_enabled", false);
        console2.log("quoteGas", qg);
        console2.log("feedGas", fg);
        console2.log("PHASE_B_COMPLETE", true);
        console2.log("STOP - HELLO canary is a separate later step");
    }
}
