// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../src/ScoopFactoryDeployer.sol";

/**
 * @title ScoopProtocolDeploy
 * @notice Shared SCOOP V1 deployment helpers for multi-signer Phase A/B tooling and fork rehearsals.
 * @dev No silent defaults. Phase A deploys globals only. Phase B configures ETH quote/oracle only.
 */
library ScoopProtocolDeploy {
    // FINAL PRODUCTION VALUE - Uniswap v4 stack on Robinhood Chain (chainId 4663).
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address public constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // FINAL PRODUCTION VALUE - Robinhood ETH/USD AggregatorV3 feed (fork-proven).
    address public constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    // REHEARSAL ONLY - never production-enabled by Phase B tooling.
    address public constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address public constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    uint256 public constant EXPECTED_CHAIN_ID = 4663;
    uint48 public constant PROPOSED_ETH_MAX_AGE = 86_400;

    error WrongChainId(uint256 expected, uint256 actual);
    error ZeroConfigAddress(string name);
    error MissingBytecode(string name, address target);
    error UnexpectedBytecode(string name, address target);
    error PostDeployAssertionFailed(string reason);
    error SenderMismatch(string role, address expected, address actual);

    struct Config {
        address verificationAuthority;
        address registryAuthority;
        address oracleAuthority;
        address launchFeeRecipient;
        address buybackVault;
        address operations;
        uint48 ethMaxAge;
        bool includeAaplRehearsal;
        uint48 aaplMaxAge;
    }

    struct GasReport {
        uint256 creatorRegistry;
        uint256 tokenDeployer;
        uint256 launchDeployer;
        uint256 quoteRegistry;
        uint256 priceOracle;
        uint256 factoryDeployer;
        uint256 ethQuoteRegister;
        uint256 ethFeedConfigure;
        uint256 aaplQuoteRegister;
        uint256 aaplFeedConfigure;
    }

    struct Deployed {
        ScoopCreatorRegistry creatorRegistry;
        ScoopTokenDeployer tokenDeployer;
        ScoopLaunchDeployer launchDeployer;
        ScoopQuoteRegistry quoteRegistry;
        ScoopPriceOracle priceOracle;
        ScoopFactoryDeployer factoryDeployer;
        ScoopCreatorRewards creatorRewards;
        ScoopFactory factory;
        address predictedFactory;
        GasReport gas;
    }

    function requireRobinhoodChain() internal view {
        if (block.chainid != EXPECTED_CHAIN_ID) {
            revert WrongChainId(EXPECTED_CHAIN_ID, block.chainid);
        }
    }

    function requireSender(address expected, string memory role) internal view {
        if (expected == address(0)) revert ZeroConfigAddress(role);
        if (msg.sender != expected) revert SenderMismatch(role, expected, msg.sender);
    }

    function validateConfig(Config memory cfg) internal pure {
        if (cfg.verificationAuthority == address(0)) revert ZeroConfigAddress("VERIFICATION_AUTHORITY");
        if (cfg.registryAuthority == address(0)) revert ZeroConfigAddress("REGISTRY_AUTHORITY");
        if (cfg.oracleAuthority == address(0)) revert ZeroConfigAddress("ORACLE_AUTHORITY");
        if (cfg.launchFeeRecipient == address(0)) revert ZeroConfigAddress("LAUNCH_FEE_RECIPIENT");
        if (cfg.buybackVault == address(0)) revert ZeroConfigAddress("BUYBACK_VAULT");
        if (cfg.operations == address(0)) revert ZeroConfigAddress("OPERATIONS");
        if (cfg.ethMaxAge == 0) revert ZeroConfigAddress("SCOOP_ETH_MAX_AGE");
        if (cfg.includeAaplRehearsal && cfg.aaplMaxAge == 0) revert ZeroConfigAddress("SCOOP_AAPL_MAX_AGE");
    }

    function assertCanonicalExternalBytecode() internal view {
        if (POOL_MANAGER.code.length == 0) revert MissingBytecode("PoolManager", POOL_MANAGER);
        if (POSITION_MANAGER.code.length == 0) revert MissingBytecode("PositionManager", POSITION_MANAGER);
        if (UNIVERSAL_ROUTER.code.length == 0) revert MissingBytecode("UniversalRouter", UNIVERSAL_ROUTER);
        if (PERMIT2.code.length == 0) revert MissingBytecode("Permit2", PERMIT2);
        if (ETH_USD_FEED.code.length == 0) revert MissingBytecode("ETH_USD_FEED", ETH_USD_FEED);
    }

    /// @notice Code-size preflight for fee recipients. EOAs (`code.length == 0`) are acceptable ETH receivers.
    function assertRecipientPreflight(address launchFeeRecipient, address buybackVault, address operations)
        internal
        view
    {
        if (launchFeeRecipient == address(0)) revert ZeroConfigAddress("LAUNCH_FEE_RECIPIENT");
        if (buybackVault == address(0)) revert ZeroConfigAddress("BUYBACK_VAULT");
        if (operations == address(0)) revert ZeroConfigAddress("OPERATIONS");

        // EOA ⇒ code empty. Non-empty code is allowed only if operator has separately proven receivability.
        console2.log("recipient.code.length launchFeeRecipient", launchFeeRecipient.code.length);
        console2.log("recipient.code.length buybackVault", buybackVault.code.length);
        console2.log("recipient.code.length operations", operations.code.length);
        if (launchFeeRecipient.code.length == 0 && buybackVault.code.length == 0 && operations.code.length == 0) {
            console2.log("ETH RECEIVABILITY PRECHECK: PASS AS EOAs");
        } else {
            console2.log("ETH RECEIVABILITY PRECHECK: CONTRACT CODE PRESENT - prove receive() before 5D");
        }
    }

    /// @notice Deploy globals through FactoryDeployer. Does NOT configure quotes/oracles.
    function deployGlobals(Config memory cfg) internal returns (Deployed memory d) {
        validateConfig(cfg);
        requireRobinhoodChain();
        assertCanonicalExternalBytecode();
        assertRecipientPreflight(cfg.launchFeeRecipient, cfg.buybackVault, cfg.operations);

        uint256 g0 = gasleft();
        d.creatorRegistry = new ScoopCreatorRegistry(cfg.verificationAuthority);
        d.gas.creatorRegistry = g0 - gasleft();

        g0 = gasleft();
        d.tokenDeployer = new ScoopTokenDeployer();
        d.gas.tokenDeployer = g0 - gasleft();

        g0 = gasleft();
        d.launchDeployer = new ScoopLaunchDeployer(POSITION_MANAGER);
        d.gas.launchDeployer = g0 - gasleft();

        g0 = gasleft();
        d.quoteRegistry = new ScoopQuoteRegistry(cfg.registryAuthority);
        d.gas.quoteRegistry = g0 - gasleft();

        g0 = gasleft();
        d.priceOracle = new ScoopPriceOracle(cfg.oracleAuthority);
        d.gas.priceOracle = g0 - gasleft();

        // FactoryDeployer CREATE nonce 1 = CreatorRewards, nonce 2 = Factory.
        g0 = gasleft();
        d.factoryDeployer = new ScoopFactoryDeployer(
            address(d.creatorRegistry),
            POOL_MANAGER,
            POSITION_MANAGER,
            PERMIT2,
            UNIVERSAL_ROUTER,
            address(d.tokenDeployer),
            address(d.launchDeployer),
            address(d.quoteRegistry),
            address(d.priceOracle),
            cfg.buybackVault,
            cfg.operations,
            cfg.launchFeeRecipient
        );
        d.gas.factoryDeployer = g0 - gasleft();

        d.creatorRewards = d.factoryDeployer.creatorRewards();
        d.factory = d.factoryDeployer.factory();
        d.predictedFactory = computeCreateAddress(address(d.factoryDeployer), 2);
    }

    /// @notice Phase B: register native ETH + configure ETH/USD feed. Caller must be registry+oracle authority.
    function configureEthQuoteAndOracle(
        ScoopQuoteRegistry quoteRegistry,
        ScoopPriceOracle priceOracle,
        uint48 ethMaxAge
    ) internal returns (uint256 quoteGas, uint256 feedGas) {
        if (ethMaxAge == 0) revert ZeroConfigAddress("SCOOP_ETH_MAX_AGE");

        uint256 g0 = gasleft();
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        quoteGas = g0 - gasleft();

        g0 = gasleft();
        priceOracle.configureFeed(address(0), ETH_USD_FEED, ethMaxAge);
        feedGas = g0 - gasleft();
    }

    /// @notice REHEARSAL ONLY - never called by production Phase B tooling.
    function configureAaplRehearsal(ScoopQuoteRegistry quoteRegistry, ScoopPriceOracle priceOracle, uint48 aaplMaxAge)
        internal
        returns (uint256 quoteGas, uint256 feedGas)
    {
        if (AAPL_TOKEN.code.length == 0) revert MissingBytecode("AAPL_TOKEN", AAPL_TOKEN);
        if (AAPL_USD_FEED.code.length == 0) revert MissingBytecode("AAPL_USD_FEED", AAPL_USD_FEED);
        if (aaplMaxAge == 0) revert ZeroConfigAddress("SCOOP_AAPL_MAX_AGE");

        uint256 g0 = gasleft();
        quoteRegistry.registerQuote(AAPL_TOKEN, ScoopQuoteRegistry.QuoteType.Stock);
        quoteGas = g0 - gasleft();

        g0 = gasleft();
        priceOracle.configureFeed(AAPL_TOKEN, AAPL_USD_FEED, aaplMaxAge);
        feedGas = g0 - gasleft();
    }

    /// @notice Phase A assertions - globals deployed; ETH may still be unconfigured.
    function assertGlobalsDeployed(Deployed memory d, Config memory cfg) internal view {
        if (d.creatorRegistry.verificationAuthority() != cfg.verificationAuthority) {
            revert PostDeployAssertionFailed("verificationAuthority");
        }
        if (d.quoteRegistry.registryAuthority() != cfg.registryAuthority) {
            revert PostDeployAssertionFailed("registryAuthority");
        }
        if (d.priceOracle.oracleAuthority() != cfg.oracleAuthority) {
            revert PostDeployAssertionFailed("oracleAuthority");
        }

        if (address(d.factory) != d.predictedFactory) revert PostDeployAssertionFailed("predictedFactory");
        if (d.creatorRewards.sourceRegistrar() != address(d.factory)) {
            revert PostDeployAssertionFailed("sourceRegistrar");
        }
        if (address(d.factory.creatorRewards()) != address(d.creatorRewards)) {
            revert PostDeployAssertionFailed("factory.creatorRewards");
        }
        if (address(d.factoryDeployer.factory()) != address(d.factory)) {
            revert PostDeployAssertionFailed("factoryDeployer.factory");
        }
        if (address(d.factoryDeployer.creatorRewards()) != address(d.creatorRewards)) {
            revert PostDeployAssertionFailed("factoryDeployer.creatorRewards");
        }

        if (address(d.factory.poolManager()) != POOL_MANAGER) revert PostDeployAssertionFailed("poolManager");
        if (address(d.factory.positionManager()) != POSITION_MANAGER) {
            revert PostDeployAssertionFailed("positionManager");
        }
        if (address(d.factory.permit2()) != PERMIT2) revert PostDeployAssertionFailed("permit2");
        if (address(d.factory.universalRouter()) != UNIVERSAL_ROUTER) {
            revert PostDeployAssertionFailed("universalRouter");
        }
        if (address(d.factory.tokenDeployer()) != address(d.tokenDeployer)) {
            revert PostDeployAssertionFailed("tokenDeployer");
        }
        if (address(d.factory.launchDeployer()) != address(d.launchDeployer)) {
            revert PostDeployAssertionFailed("launchDeployer");
        }
        if (address(d.factory.quoteRegistry()) != address(d.quoteRegistry)) {
            revert PostDeployAssertionFailed("quoteRegistry");
        }
        if (address(d.factory.priceOracle()) != address(d.priceOracle)) {
            revert PostDeployAssertionFailed("priceOracle");
        }
        if (d.factory.buybackVault() != cfg.buybackVault) revert PostDeployAssertionFailed("buybackVault");
        if (d.factory.operations() != cfg.operations) revert PostDeployAssertionFailed("operations");
        if (d.factory.launchFeeRecipient() != cfg.launchFeeRecipient) {
            revert PostDeployAssertionFailed("launchFeeRecipient");
        }

        if (d.factory.LAUNCH_FEE() != 0.0005 ether) revert PostDeployAssertionFailed("LAUNCH_FEE");
        if (d.factory.LP_FEE() != 10_000) revert PostDeployAssertionFailed("LP_FEE");
        if (d.factory.TICK_SPACING() != 10) revert PostDeployAssertionFailed("TICK_SPACING");

        // Phase A must leave ETH unconfigured so Phase B is mandatory.
        if (d.quoteRegistry.isRegistered(address(0))) revert PostDeployAssertionFailed("ETH unexpectedly registered");
        if (d.priceOracle.isConfigured(address(0))) {
            revert PostDeployAssertionFailed("ETH feed unexpectedly configured");
        }
    }

    /// @notice Phase B assertions - ETH quote + feed live; AAPL not registered by this path.
    function assertEthConfigured(ScoopQuoteRegistry quoteRegistry, ScoopPriceOracle priceOracle, uint48 ethMaxAge)
        internal
        view
    {
        if (address(quoteRegistry).code.length == 0) {
            revert MissingBytecode("ScoopQuoteRegistry", address(quoteRegistry));
        }
        if (address(priceOracle).code.length == 0) revert MissingBytecode("ScoopPriceOracle", address(priceOracle));

        if (!quoteRegistry.isRegistered(address(0))) revert PostDeployAssertionFailed("ETH not registered");
        if (!quoteRegistry.isEnabled(address(0))) revert PostDeployAssertionFailed("ETH not enabled");
        if (quoteRegistry.quoteType(address(0)) != ScoopQuoteRegistry.QuoteType.Native) {
            revert PostDeployAssertionFailed("ETH type");
        }

        if (!priceOracle.isConfigured(address(0))) revert PostDeployAssertionFailed("ETH feed not configured");
        if (!priceOracle.isEnabled(address(0))) revert PostDeployAssertionFailed("ETH feed not enabled");
        ScoopPriceOracle.PriceFeedConfig memory ethFeed = priceOracle.getFeedConfig(address(0));
        if (ethFeed.feed != ETH_USD_FEED) revert PostDeployAssertionFailed("ETH feed address");
        if (ethFeed.maxAge != ethMaxAge) revert PostDeployAssertionFailed("ETH maxAge");
        if (priceOracle.getPriceUsd(address(0)) == 0) revert PostDeployAssertionFailed("ETH price zero");
    }

    /// @notice Phase B production guard - AAPL must not be enabled by the ETH-only config path.
    function assertAaplNotProductionRegistered(ScoopQuoteRegistry quoteRegistry) internal view {
        if (quoteRegistry.isRegistered(AAPL_TOKEN)) {
            revert PostDeployAssertionFailed("AAPL must not be production-registered by Phase B");
        }
    }

    /// @notice Combined rehearsal assertion (globals + ETH). Used by single-signer rehearsal helper only.
    function assertPostDeployment(Deployed memory d, Config memory cfg) internal view {
        // After configure, ETH is registered - so call globals checks without the "ETH must be absent" gate.
        if (d.creatorRegistry.verificationAuthority() != cfg.verificationAuthority) {
            revert PostDeployAssertionFailed("verificationAuthority");
        }
        if (d.quoteRegistry.registryAuthority() != cfg.registryAuthority) {
            revert PostDeployAssertionFailed("registryAuthority");
        }
        if (d.priceOracle.oracleAuthority() != cfg.oracleAuthority) {
            revert PostDeployAssertionFailed("oracleAuthority");
        }
        if (address(d.factory) != d.predictedFactory) revert PostDeployAssertionFailed("predictedFactory");
        if (d.creatorRewards.sourceRegistrar() != address(d.factory)) {
            revert PostDeployAssertionFailed("sourceRegistrar");
        }
        if (address(d.factory.creatorRewards()) != address(d.creatorRewards)) {
            revert PostDeployAssertionFailed("factory.creatorRewards");
        }
        if (address(d.factory.poolManager()) != POOL_MANAGER) revert PostDeployAssertionFailed("poolManager");
        if (address(d.factory.positionManager()) != POSITION_MANAGER) {
            revert PostDeployAssertionFailed("positionManager");
        }
        if (address(d.factory.permit2()) != PERMIT2) revert PostDeployAssertionFailed("permit2");
        if (address(d.factory.universalRouter()) != UNIVERSAL_ROUTER) {
            revert PostDeployAssertionFailed("universalRouter");
        }
        if (address(d.factory.tokenDeployer()) != address(d.tokenDeployer)) {
            revert PostDeployAssertionFailed("tokenDeployer");
        }
        if (address(d.factory.launchDeployer()) != address(d.launchDeployer)) {
            revert PostDeployAssertionFailed("launchDeployer");
        }
        if (address(d.factory.quoteRegistry()) != address(d.quoteRegistry)) {
            revert PostDeployAssertionFailed("quoteRegistry");
        }
        if (address(d.factory.priceOracle()) != address(d.priceOracle)) {
            revert PostDeployAssertionFailed("priceOracle");
        }
        if (d.factory.buybackVault() != cfg.buybackVault) revert PostDeployAssertionFailed("buybackVault");
        if (d.factory.operations() != cfg.operations) revert PostDeployAssertionFailed("operations");
        if (d.factory.launchFeeRecipient() != cfg.launchFeeRecipient) {
            revert PostDeployAssertionFailed("launchFeeRecipient");
        }
        if (d.factory.LAUNCH_FEE() != 0.0005 ether) revert PostDeployAssertionFailed("LAUNCH_FEE");
        if (d.factory.LP_FEE() != 10_000) revert PostDeployAssertionFailed("LP_FEE");
        if (d.factory.TICK_SPACING() != 10) revert PostDeployAssertionFailed("TICK_SPACING");

        assertEthConfigured(d.quoteRegistry, d.priceOracle, cfg.ethMaxAge);
    }

    function logManifest(Deployed memory d, Config memory cfg, uint256 forkBlock) internal view {
        console2.log("==== SCOOP V1 DEPLOYMENT MANIFEST ====");
        console2.log("MODE", "SIMULATION_OR_REHEARSAL");
        console2.log("chainId", EXPECTED_CHAIN_ID);
        console2.log("forkBlock", forkBlock);
        console2.log("ScoopCreatorRegistry", address(d.creatorRegistry));
        console2.log("ScoopTokenDeployer", address(d.tokenDeployer));
        console2.log("ScoopLaunchDeployer", address(d.launchDeployer));
        console2.log("ScoopQuoteRegistry", address(d.quoteRegistry));
        console2.log("ScoopPriceOracle", address(d.priceOracle));
        console2.log("ScoopFactoryDeployer", address(d.factoryDeployer));
        console2.log("ScoopCreatorRewards", address(d.creatorRewards));
        console2.log("ScoopFactory", address(d.factory));
        console2.log("predictedFactory", d.predictedFactory);
        console2.log("PoolManager", POOL_MANAGER);
        console2.log("PositionManager", POSITION_MANAGER);
        console2.log("UniversalRouter", UNIVERSAL_ROUTER);
        console2.log("Permit2", PERMIT2);
        console2.log("verificationAuthority", cfg.verificationAuthority);
        console2.log("registryAuthority", cfg.registryAuthority);
        console2.log("oracleAuthority", cfg.oracleAuthority);
        console2.log("launchFeeRecipient", cfg.launchFeeRecipient);
        console2.log("buybackVault", cfg.buybackVault);
        console2.log("operations", cfg.operations);
        console2.log("ethMaxAge", uint256(cfg.ethMaxAge));
        console2.log("includeAaplRehearsal", cfg.includeAaplRehearsal);
        console2.log("HANDOFF_SCOOP_QUOTE_REGISTRY", address(d.quoteRegistry));
        console2.log("HANDOFF_SCOOP_PRICE_ORACLE", address(d.priceOracle));
        console2.log("STOP - Phase A complete. Phase B must be signed by Scoop Auth 1.");
    }

    function totalDeploymentGas(GasReport memory g) internal pure returns (uint256) {
        return
            g.creatorRegistry + g.tokenDeployer + g.launchDeployer + g.quoteRegistry + g.priceOracle + g.factoryDeployer;
    }

    function totalConfigGas(GasReport memory g) internal pure returns (uint256) {
        return g.ethQuoteRegister + g.ethFeedConfigure + g.aaplQuoteRegister + g.aaplFeedConfigure;
    }

    function largestTxGas(GasReport memory g) internal pure returns (uint256 largest) {
        largest = g.creatorRegistry;
        if (g.tokenDeployer > largest) largest = g.tokenDeployer;
        if (g.launchDeployer > largest) largest = g.launchDeployer;
        if (g.quoteRegistry > largest) largest = g.quoteRegistry;
        if (g.priceOracle > largest) largest = g.priceOracle;
        if (g.factoryDeployer > largest) largest = g.factoryDeployer;
        if (g.ethQuoteRegister > largest) largest = g.ethQuoteRegister;
        if (g.ethFeedConfigure > largest) largest = g.ethFeedConfigure;
        if (g.aaplQuoteRegister > largest) largest = g.aaplQuoteRegister;
        if (g.aaplFeedConfigure > largest) largest = g.aaplFeedConfigure;
    }

    function computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce))))))
        );
    }
}
