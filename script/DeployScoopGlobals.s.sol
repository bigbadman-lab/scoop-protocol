// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopProtocolDeploy} from "./ScoopProtocolDeploy.sol";

/**
 * @title DeployScoopGlobals
 * @notice PHASE A - Scoop Deploy 1 only. Deploys global SCOOP infrastructure. Does NOT configure quotes/oracles.
 *
 * @dev Required env:
 *      DEPLOYER_ADDRESS
 *      VERIFICATION_AUTHORITY
 *      REGISTRY_AUTHORITY
 *      ORACLE_AUTHORITY
 *      LAUNCH_FEE_RECIPIENT
 *      BUYBACK_VAULT
 *      OPERATIONS
 *      SCOOP_ETH_MAX_AGE   (recorded in manifest for Phase B; not applied here)
 *
 * Simulation (5C.1 - no broadcast):
 *   forge script script/DeployScoopGlobals.s.sol:DeployScoopGlobals \
 *     --rpc-url "$ROBINHOOD_RPC_URL" --sender "$DEPLOYER_ADDRESS" -vvvv
 *
 * Future 5D broadcast (explicit only):
 *   SCOOP_BROADCAST=true forge script ... --sender "$DEPLOYER_ADDRESS" --broadcast
 *
 * NEVER broadcast in 5C.1. NEVER print private keys.
 */
contract DeployScoopGlobals is Script {
    function run() external {
        ScoopProtocolDeploy.requireRobinhoodChain();
        ScoopProtocolDeploy.assertCanonicalExternalBytecode();

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        ScoopProtocolDeploy.requireSender(deployer, "DEPLOYER_ADDRESS");

        ScoopProtocolDeploy.Config memory cfg = _loadConfig();
        ScoopProtocolDeploy.validateConfig(cfg);

        // Production MVP: registryAuthority == oracleAuthority (== Scoop Auth 1).
        require(
            cfg.registryAuthority == cfg.oracleAuthority,
            "DeployScoopGlobals: REGISTRY_AUTHORITY must equal ORACLE_AUTHORITY (Scoop Auth 1)"
        );
        require(
            cfg.registryAuthority != deployer,
            "DeployScoopGlobals: DEPLOYER_ADDRESS must differ from Scoop Auth 1 (multi-signer model)"
        );
        require(
            cfg.verificationAuthority != deployer && cfg.verificationAuthority != cfg.registryAuthority,
            "DeployScoopGlobals: VERIFICATION_AUTHORITY must be a distinct Scoop Verify 1 wallet"
        );

        bool doBroadcast = vm.envOr("SCOOP_BROADCAST", false);
        if (doBroadcast) {
            uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
            vm.startBroadcast(pk);
        } else {
            console2.log("MODE", "SIMULATION");
            console2.log("BROADCAST", false);
        }

        ScoopProtocolDeploy.Deployed memory d = ScoopProtocolDeploy.deployGlobals(cfg);
        ScoopProtocolDeploy.assertGlobalsDeployed(d, cfg);
        ScoopProtocolDeploy.logManifest(d, cfg, block.number);

        if (doBroadcast) {
            vm.stopBroadcast();
            console2.log("MODE", "BROADCAST");
        }

        console2.log("totalDeploymentGas", ScoopProtocolDeploy.totalDeploymentGas(d.gas));
        console2.log("largestTxGas", ScoopProtocolDeploy.largestTxGas(d.gas));
        console2.log("deployerNonceAfter", vm.getNonce(deployer));
        console2.log("PHASE_A_COMPLETE", true);
        console2.log("NEXT", "Record HANDOFF_* addresses, then run ConfigureScoopProtocol as Scoop Auth 1");
        console2.log("STOP");
    }

    function _loadConfig() internal view returns (ScoopProtocolDeploy.Config memory cfg) {
        cfg.verificationAuthority = vm.envAddress("VERIFICATION_AUTHORITY");
        cfg.registryAuthority = vm.envAddress("REGISTRY_AUTHORITY");
        cfg.oracleAuthority = vm.envAddress("ORACLE_AUTHORITY");
        cfg.launchFeeRecipient = vm.envAddress("LAUNCH_FEE_RECIPIENT");
        cfg.buybackVault = vm.envAddress("BUYBACK_VAULT");
        cfg.operations = vm.envAddress("OPERATIONS");
        cfg.ethMaxAge = uint48(vm.envUint("SCOOP_ETH_MAX_AGE"));
        cfg.includeAaplRehearsal = false;
        cfg.aaplMaxAge = 0;
    }
}
