// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopProtocolDeploy} from "../../script/ScoopProtocolDeploy.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {RejectETHRecipient} from "../mocks/security/MaliciousRecipients.sol";

/**
 * @notice Milestone 5C — mainnet deployment configuration rehearsal on a live Robinhood fork.
 * @dev Roles below are TEST / FORK ONLY placeholders. No broadcast.
 */
contract ScoopMainnetDeploymentForkTest is Test {
    uint48 internal constant REHEARSAL_ETH_MAX_AGE = 1 days;
    uint48 internal constant REHEARSAL_AAPL_MAX_AGE = 7 days;

    ScoopProtocolDeploy.Deployed internal d;
    ScoopProtocolDeploy.Config internal cfg;

    address internal verificationAuthority;
    address internal registryAuthority;
    address internal oracleAuthority;
    address internal launchFeeRecipient;
    address internal buybackVault;
    address internal operations;

    uint256 internal forkBlock;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        forkBlock = block.number;

        ScoopProtocolDeploy.requireRobinhoodChain();
        ScoopProtocolDeploy.assertCanonicalExternalBytecode();

        verificationAuthority = makeAddr("verificationAuthority_TEST_FORK_ONLY");
        registryAuthority = makeAddr("opsAuthority_TEST_FORK_ONLY");
        oracleAuthority = registryAuthority; // combined configure authority for rehearsal
        launchFeeRecipient = makeAddr("launchFeeRecipient_TEST_FORK_ONLY");
        buybackVault = makeAddr("buybackVault_TEST_FORK_ONLY");
        operations = makeAddr("operations_TEST_FORK_ONLY");

        cfg = ScoopProtocolDeploy.Config({
            verificationAuthority: verificationAuthority,
            registryAuthority: registryAuthority,
            oracleAuthority: oracleAuthority,
            launchFeeRecipient: launchFeeRecipient,
            buybackVault: buybackVault,
            operations: operations,
            ethMaxAge: REHEARSAL_ETH_MAX_AGE,
            includeAaplRehearsal: true,
            aaplMaxAge: REHEARSAL_AAPL_MAX_AGE
        });

        d = ScoopProtocolDeploy.deployGlobals(cfg);

        vm.startPrank(registryAuthority);
        (uint256 qg, uint256 fg) =
            ScoopProtocolDeploy.configureEthQuoteAndOracle(d.quoteRegistry, d.priceOracle, cfg.ethMaxAge);
        d.gas.ethQuoteRegister = qg;
        d.gas.ethFeedConfigure = fg;
        (uint256 aq, uint256 af) =
            ScoopProtocolDeploy.configureAaplRehearsal(d.quoteRegistry, d.priceOracle, cfg.aaplMaxAge);
        d.gas.aaplQuoteRegister = aq;
        d.gas.aaplFeedConfigure = af;
        vm.stopPrank();

        ScoopProtocolDeploy.assertPostDeployment(d, cfg);
        ScoopProtocolDeploy.logManifest(d, cfg, forkBlock);
    }

    function test_chainId_isRobinhoodMainnet() public view {
        assertEq(block.chainid, ScoopProtocolDeploy.EXPECTED_CHAIN_ID);
    }

    function test_canonicalExternalContracts_haveBytecode() public view {
        assertGt(ScoopProtocolDeploy.POOL_MANAGER.code.length, 0);
        assertGt(ScoopProtocolDeploy.POSITION_MANAGER.code.length, 0);
        assertGt(ScoopProtocolDeploy.UNIVERSAL_ROUTER.code.length, 0);
        assertGt(ScoopProtocolDeploy.PERMIT2.code.length, 0);
        assertGt(ScoopProtocolDeploy.ETH_USD_FEED.code.length, 0);
        assertGt(ScoopProtocolDeploy.AAPL_TOKEN.code.length, 0);
        assertGt(ScoopProtocolDeploy.AAPL_USD_FEED.code.length, 0);
    }

    function test_factoryPrediction_andSourceRegistrar() public view {
        assertEq(address(d.factory), d.predictedFactory);
        assertEq(d.creatorRewards.sourceRegistrar(), address(d.factory));
        assertEq(address(d.factory.creatorRewards()), address(d.creatorRewards));
    }

    function test_factoryImmutables_matchConfig() public view {
        assertEq(address(d.factory.poolManager()), ScoopProtocolDeploy.POOL_MANAGER);
        assertEq(address(d.factory.positionManager()), ScoopProtocolDeploy.POSITION_MANAGER);
        assertEq(address(d.factory.permit2()), ScoopProtocolDeploy.PERMIT2);
        assertEq(address(d.factory.universalRouter()), ScoopProtocolDeploy.UNIVERSAL_ROUTER);
        assertEq(address(d.factory.tokenDeployer()), address(d.tokenDeployer));
        assertEq(address(d.factory.launchDeployer()), address(d.launchDeployer));
        assertEq(address(d.factory.quoteRegistry()), address(d.quoteRegistry));
        assertEq(address(d.factory.priceOracle()), address(d.priceOracle));
        assertEq(d.factory.buybackVault(), buybackVault);
        assertEq(d.factory.operations(), operations);
        assertEq(d.factory.launchFeeRecipient(), launchFeeRecipient);
        assertEq(d.factory.LAUNCH_FEE(), 0.0005 ether);
        assertEq(uint256(d.factory.LP_FEE()), 10_000);
        assertEq(int256(d.factory.TICK_SPACING()), int256(10));
    }

    function test_authorities_matchConfig() public view {
        assertEq(d.creatorRegistry.verificationAuthority(), verificationAuthority);
        assertEq(d.quoteRegistry.registryAuthority(), registryAuthority);
        assertEq(d.priceOracle.oracleAuthority(), oracleAuthority);
    }

    function test_ethQuoteAndOracle_configuredFresh() public view {
        assertTrue(d.quoteRegistry.isRegistered(address(0)));
        assertTrue(d.quoteRegistry.isEnabled(address(0)));
        assertEq(uint8(d.quoteRegistry.quoteType(address(0))), uint8(ScoopQuoteRegistry.QuoteType.Native));
        assertTrue(d.priceOracle.isConfigured(address(0)));
        assertTrue(d.priceOracle.isEnabled(address(0)));
        ScoopPriceOracle.PriceFeedConfig memory feed = d.priceOracle.getFeedConfig(address(0));
        assertEq(feed.feed, ScoopProtocolDeploy.ETH_USD_FEED);
        assertEq(feed.maxAge, REHEARSAL_ETH_MAX_AGE);
        assertGt(d.priceOracle.getPriceUsd(address(0)), 0);
    }

    function test_aaplRehearsal_configured_notProductionPolicy() public view {
        // AAPL is included for regression rehearsal only — not a production enablement decision.
        assertTrue(d.quoteRegistry.isRegistered(ScoopProtocolDeploy.AAPL_TOKEN));
        assertTrue(d.quoteRegistry.isEnabled(ScoopProtocolDeploy.AAPL_TOKEN));
        assertEq(
            uint8(d.quoteRegistry.quoteType(ScoopProtocolDeploy.AAPL_TOKEN)), uint8(ScoopQuoteRegistry.QuoteType.Stock)
        );
        ScoopPriceOracle.PriceFeedConfig memory feed = d.priceOracle.getFeedConfig(ScoopProtocolDeploy.AAPL_TOKEN);
        assertEq(feed.feed, ScoopProtocolDeploy.AAPL_USD_FEED);
        assertEq(feed.maxAge, REHEARSAL_AAPL_MAX_AGE);
    }

    function test_ethReceivability_sharedRecipients() public {
        vm.deal(address(this), 1 ether);
        _assertReceivable(launchFeeRecipient);
        _assertReceivable(buybackVault);
        _assertReceivable(operations);
    }

    function test_rejectingRecipient_cannotReceiveEth() public {
        RejectETHRecipient rejector = new RejectETHRecipient();
        (bool ok,) = address(rejector).call{value: 1 wei}("");
        assertFalse(ok, "rejector must not accept ETH");
    }

    function test_staleEthOracle_blocksPriceRead() public {
        // Tighten maxAge then warp past it — new launches that need price must fail.
        vm.prank(oracleAuthority);
        d.priceOracle.setMaxAge(address(0), 1);
        vm.warp(block.timestamp + 10);
        vm.expectRevert();
        d.priceOracle.getPriceUsd(address(0));
    }

    function test_gasReport_logged() public view {
        uint256 deployGas = ScoopProtocolDeploy.totalDeploymentGas(d.gas);
        uint256 configGas = ScoopProtocolDeploy.totalConfigGas(d.gas);
        uint256 largest = ScoopProtocolDeploy.largestTxGas(d.gas);
        console2.log("forkBlock", forkBlock);
        console2.log("block.gaslimit", block.gaslimit);
        console2.log("block.basefee", block.basefee);
        console2.log("totalDeploymentGas", deployGas);
        console2.log("totalConfigGas", configGas);
        console2.log("largestTxGas", largest);
        assertGt(deployGas, 0);
        assertGt(configGas, 0);
        assertGe(block.gaslimit, largest);
    }

    function _assertReceivable(address recipient) internal {
        uint256 beforeBal = recipient.balance;
        (bool ok,) = recipient.call{value: 0.01 ether}("");
        assertTrue(ok, "recipient must accept ETH");
        assertEq(recipient.balance, beforeBal + 0.01 ether);
    }
}
