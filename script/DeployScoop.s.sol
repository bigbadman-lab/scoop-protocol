// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopProtocolDeploy} from "./ScoopProtocolDeploy.sol";

/**
 * @title DeployScoop
 * @notice LEGACY single-signer REHEARSAL helper (deploy + configure as one sender).
 * @dev NOT for production multi-signer 5D.
 *
 *      Production flow:
 *        1) script/DeployScoopGlobals.s.sol      (Scoop Deploy 1)
 *        2) script/ConfigureScoopProtocol.s.sol (Scoop Auth 1)
 *
 *      This combined script remains for local/fork convenience when one sender is both
 *      deployer and authority (must set DEPLOYER_ADDRESS == REGISTRY_AUTHORITY == ORACLE_AUTHORITY).
 *
 *      NEVER pass --broadcast during 5C / 5C.1.
 */
contract DeployScoop is Script {
    function run() external {
        console2.log("WARNING", "DeployScoop is a single-signer REHEARSAL helper, not production multi-signer tooling");
        console2.log("USE_INSTEAD", "DeployScoopGlobals then ConfigureScoopProtocol");

        ScoopProtocolDeploy.requireRobinhoodChain();
        ScoopProtocolDeploy.assertCanonicalExternalBytecode();

        ScoopProtocolDeploy.Config memory cfg = _loadConfig();
        ScoopProtocolDeploy.validateConfig(cfg);

        require(
            msg.sender == cfg.registryAuthority && msg.sender == cfg.oracleAuthority,
            "DeployScoop: combined rehearsal requires msg.sender == REGISTRY_AUTHORITY == ORACLE_AUTHORITY"
        );

        ScoopProtocolDeploy.Deployed memory d = ScoopProtocolDeploy.deployGlobals(cfg);
        ScoopProtocolDeploy.assertGlobalsDeployed(d, cfg);

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
        console2.log("BROADCAST_DISABLED", true);
    }

    function _loadConfig() internal view returns (ScoopProtocolDeploy.Config memory cfg) {
        cfg.verificationAuthority = vm.envAddress("VERIFICATION_AUTHORITY");
        cfg.registryAuthority = vm.envAddress("REGISTRY_AUTHORITY");
        cfg.oracleAuthority = vm.envAddress("ORACLE_AUTHORITY");
        cfg.launchFeeRecipient = vm.envAddress("LAUNCH_FEE_RECIPIENT");
        cfg.buybackVault = vm.envAddress("BUYBACK_VAULT");
        cfg.operations = vm.envAddress("OPERATIONS");
        cfg.ethMaxAge = uint48(vm.envUint("SCOOP_ETH_MAX_AGE"));
        cfg.includeAaplRehearsal = vm.envOr("SCOOP_INCLUDE_AAPL_REHEARSAL", false);
        if (cfg.includeAaplRehearsal) {
            cfg.aaplMaxAge = uint48(vm.envUint("SCOOP_AAPL_MAX_AGE"));
        }
    }
}
