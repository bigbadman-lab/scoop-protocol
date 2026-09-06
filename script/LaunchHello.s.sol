// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopHelloCanaryLaunch} from "./ScoopHelloCanaryLaunch.sol";
import {ScoopProtocolDeploy} from "./ScoopProtocolDeploy.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";

/**
 * @title LaunchHello
 * @notice ONE-OFF production HELLO canary launcher for Robinhood Chain mainnet (4663).
 *
 * @dev Required env:
 *      SCOOP_FACTORY              (must be 0x15E874Bc667435ddbF2a67c0362701DC23C90833)
 *      HELLO_CREATOR_ADDRESS      (must be 0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C)
 *      HELLO_CREATOR_PRIVATE_KEY  (only when SCOOP_BROADCAST=true — local secret)
 *      SCOOP_BROADCAST            (default false)
 *
 * Simulation (no PK; use --sender):
 *   forge script script/LaunchHello.s.sol:LaunchHello \
 *     --rpc-url "$ROBINHOOD_RPC_URL" --sender "$HELLO_CREATOR_ADDRESS" -vvvv
 *
 * Signer-accurate dry-run (PK loaded; still NO forge --broadcast):
 *   SCOOP_BROADCAST=true forge script script/LaunchHello.s.sol:LaunchHello \
 *     --rpc-url "$ROBINHOOD_RPC_URL" -vvvv
 *
 * Explicit real broadcast (requires SCOOP_BROADCAST=true AND forge --broadcast):
 *   SCOOP_BROADCAST=true forge script script/LaunchHello.s.sol:LaunchHello \
 *     --rpc-url "$ROBINHOOD_RPC_URL" --broadcast -vvvv
 *
 * NEVER print private keys. NEVER launch a second token until Milestone 5E.
 */
contract LaunchHello is Script {
    function run() external {
        ScoopHelloCanaryLaunch.requireRobinhood();

        address factoryAddr = vm.envAddress("SCOOP_FACTORY");
        address helloCreator = vm.envAddress("HELLO_CREATOR_ADDRESS");

        ScoopHelloCanaryLaunch.requireExpectedFactory(factoryAddr);
        ScoopHelloCanaryLaunch.requireExpectedHelloCreator(helloCreator);
        ScoopHelloCanaryLaunch.requireFactoryCode(factoryAddr);

        ScoopFactory factory = ScoopFactory(factoryAddr);

        bytes32 creatorId = ScoopHelloCanaryLaunch.assertProductionStackSane(
            factory, helloCreator, ScoopHelloCanaryLaunch.EXPECTED_CREATOR_ID
        );

        ScoopFactory.LaunchParams memory params = ScoopHelloCanaryLaunch.buildParams(creatorId);
        ScoopHelloCanaryLaunch.Predicted memory predicted =
            ScoopHelloCanaryLaunch.predict(factory, helloCreator, params);

        console2.log("predicted token", predicted.token);
        console2.log("predicted feeDistributor", predicted.feeDistributor);
        console2.log("predicted liquidityLocker", predicted.liquidityLocker);

        ScoopHelloCanaryLaunch.requirePredictedSlotsEmpty(predicted);
        ScoopHelloCanaryLaunch.requireLaunchDoesNotExist(factory, predicted.token);
        ScoopHelloCanaryLaunch.requireSufficientEth(helloCreator);

        bool doBroadcast = vm.envOr("SCOOP_BROADCAST", false);
        ScoopHelloCanaryLaunch.LaunchOutcome memory outcome;
        if (doBroadcast) {
            // Signer path: load PK only when SCOOP_BROADCAST is explicitly enabled.
            // startBroadcast makes simulation signer-accurate; forge --broadcast is still required to submit.
            uint256 pk = vm.envUint("HELLO_CREATOR_PRIVATE_KEY");
            address derived = vm.addr(pk);
            require(
                derived == helloCreator, "LaunchHello: HELLO_CREATOR_PRIVATE_KEY does not match HELLO_CREATOR_ADDRESS"
            );
            vm.startBroadcast(pk);
            outcome = ScoopHelloCanaryLaunch.executeLaunchAndBuy(factory, params);
            vm.stopBroadcast();
            console2.log("MODE", "BROADCAST_GATED");
            console2.log("SCOOP_BROADCAST", true);
        } else {
            // Simulation without PK: --sender must be HELLO creator; prank so CREATE2 salt uses that address.
            ScoopProtocolDeploy.requireSender(helloCreator, "HELLO_CREATOR_ADDRESS");
            console2.log("MODE", "SIMULATION");
            console2.log("BROADCAST", false);
            vm.startPrank(helloCreator);
            outcome = ScoopHelloCanaryLaunch.executeLaunchAndBuy(factory, params);
            vm.stopPrank();
        }

        ScoopHelloCanaryLaunch.assertPostLaunch(factory, helloCreator, creatorId, predicted, outcome);

        ScoopHelloCanaryLaunch.Manifest memory manifest = ScoopHelloCanaryLaunch.Manifest({
            mode: doBroadcast ? "BROADCAST_GATED" : "SIMULATION",
            factory: factoryAddr,
            helloCreator: helloCreator,
            creatorId: creatorId,
            salt: ScoopHelloCanaryLaunch.PRODUCTION_SALT,
            predicted: predicted,
            outcome: outcome,
            launchFee: ScoopHelloCanaryLaunch.EXPECTED_LAUNCH_FEE,
            initialBuy: ScoopHelloCanaryLaunch.QUOTE_AMOUNT_IN,
            totalValue: ScoopHelloCanaryLaunch.TOTAL_VALUE,
            minTokensOut: ScoopHelloCanaryLaunch.MIN_TOKENS_OUT
        });
        ScoopHelloCanaryLaunch.logManifest(manifest);
    }
}
