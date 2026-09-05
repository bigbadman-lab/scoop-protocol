// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopProtocolDeploy} from "./ScoopProtocolDeploy.sol";

/**
 * @title DeployScoop
 * @notice SCOOP V1 mainnet deployment script (fork/simulation ready).
 * @dev REQUIRED env (no silent defaults):
 *      REGISTRY_AUTHORITY, ORACLE_AUTHORITY, VERIFICATION_AUTHORITY,
 *      LAUNCH_FEE_RECIPIENT, BUYBACK_VAULT, OPERATIONS,
 *      SCOOP_ETH_MAX_AGE, SCOOP_INCLUDE_AAPL_REHEARSAL
 *      If SCOOP_INCLUDE_AAPL_REHEARSAL=true: SCOOP_AAPL_MAX_AGE
 *
 *      For combined configure in one script run, REGISTRY_AUTHORITY and ORACLE_AUTHORITY
 *      must equal the script sender (use one rehearsal ops key, or split txs in 5D).
 *
 *      Usage (simulation only — Milestone 5C):
 *        forge script script/DeployScoop.s.sol:DeployScoop --rpc-url $ROBINHOOD_RPC_URL -vvvv
 *
 *      NEVER pass --broadcast during Milestone 5C.
 */
contract DeployScoop is Script {
    function run() external {
        ScoopProtocolDeploy.requireRobinhoodChain();
        ScoopProtocolDeploy.assertCanonicalExternalBytecode();

        ScoopProtocolDeploy.Config memory cfg = _loadConfig();
        ScoopProtocolDeploy.validateConfig(cfg);

        require(
            msg.sender == cfg.registryAuthority && msg.sender == cfg.oracleAuthority,
            "DeployScoop: msg.sender must equal REGISTRY_AUTHORITY and ORACLE_AUTHORITY for combined configure"
        );

        // Simulation path: no vm.startBroadcast(). For 5D only, wrap deploys in broadcast.
        ScoopProtocolDeploy.Deployed memory d = ScoopProtocolDeploy.deployGlobals(cfg);

        (uint256 qg, uint256 fg) =
            ScoopProtocolDeploy.configureEthQuoteAndOracle(d.quoteRegistry, d.priceOracle, cfg.ethMaxAge);
        d.gas.ethQuoteRegister = qg;
        d.gas.ethFeedConfigure = fg;

        if (cfg.includeAaplRehearsal) {
            (uint256 aq, uint256 af) =
                ScoopProtocolDeploy.configureAaplRehearsal(d.quoteRegistry, d.priceOracle, cfg.aaplMaxAge);
            d.gas.aaplQuoteRegister = aq;
            d.gas.aaplFeedConfigure = af;
        }

        ScoopProtocolDeploy.assertPostDeployment(d, cfg);
        ScoopProtocolDeploy.logManifest(d, cfg, block.number);

        console2.log("totalDeploymentGas", ScoopProtocolDeploy.totalDeploymentGas(d.gas));
        console2.log("totalConfigGas", ScoopProtocolDeploy.totalConfigGas(d.gas));
        console2.log("largestTxGas", ScoopProtocolDeploy.largestTxGas(d.gas));
        console2.log("block.gaslimit", block.gaslimit);
        console2.log("block.basefee", block.basefee);
        console2.log("predictedFactoryMatches", address(d.factory) == d.predictedFactory);
        console2.log("sourceRegistrarIsFactory", d.creatorRewards.sourceRegistrar() == address(d.factory));
        console2.log("BROADCAST_DISABLED_5C", true);
    }

    function _loadConfig() internal view returns (ScoopProtocolDeploy.Config memory cfg) {
        cfg.verificationAuthority = vm.envAddress("VERIFICATION_AUTHORITY");
        cfg.registryAuthority = vm.envAddress("REGISTRY_AUTHORITY");
        cfg.oracleAuthority = vm.envAddress("ORACLE_AUTHORITY");
        cfg.launchFeeRecipient = vm.envAddress("LAUNCH_FEE_RECIPIENT");
        cfg.buybackVault = vm.envAddress("BUYBACK_VAULT");
        cfg.operations = vm.envAddress("OPERATIONS");
        cfg.ethMaxAge = uint48(vm.envUint("SCOOP_ETH_MAX_AGE"));
        cfg.includeAaplRehearsal = vm.envBool("SCOOP_INCLUDE_AAPL_REHEARSAL");
        if (cfg.includeAaplRehearsal) {
            cfg.aaplMaxAge = uint48(vm.envUint("SCOOP_AAPL_MAX_AGE"));
        }
    }
}
