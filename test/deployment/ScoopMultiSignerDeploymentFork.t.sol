// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ScoopProtocolDeploy} from "../../script/ScoopProtocolDeploy.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";

/**
 * @notice Milestone 5C.1 — multi-signer Phase A/B deployment tooling on a live Robinhood fork.
 * @dev Uses real PUBLIC production role addresses from `.env`. No private keys. No broadcast.
 *
 *      Actor A = DEPLOYER_ADDRESS (Scoop Deploy 1) — deploys globals only
 *      Actor B = REGISTRY_AUTHORITY / ORACLE_AUTHORITY (Scoop Auth 1) — configures ETH only
 *      Actor C = VERIFICATION_AUTHORITY (Scoop Verify 1) — neither deploy nor configure
 */
contract ScoopMultiSignerDeploymentForkTest is Test {
    ScoopProtocolDeploy.Deployed internal d;
    ScoopProtocolDeploy.Config internal cfg;

    address internal deployer;
    address internal authority;
    address internal verificationAuthority;
    address internal launchFeeRecipient;
    address internal buybackVault;
    address internal operations;
    uint48 internal ethMaxAge;
    uint256 internal forkBlock;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        forkBlock = block.number;

        ScoopProtocolDeploy.requireRobinhoodChain();
        ScoopProtocolDeploy.assertCanonicalExternalBytecode();

        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        authority = vm.envAddress("REGISTRY_AUTHORITY");
        address oracleAuthority = vm.envAddress("ORACLE_AUTHORITY");
        verificationAuthority = vm.envAddress("VERIFICATION_AUTHORITY");
        launchFeeRecipient = vm.envAddress("LAUNCH_FEE_RECIPIENT");
        buybackVault = vm.envAddress("BUYBACK_VAULT");
        operations = vm.envAddress("OPERATIONS");
        ethMaxAge = uint48(vm.envUint("SCOOP_ETH_MAX_AGE"));

        require(authority == oracleAuthority, "REGISTRY_AUTHORITY must equal ORACLE_AUTHORITY");
        require(deployer != authority, "DEPLOYER must differ from Auth");
        require(verificationAuthority != deployer && verificationAuthority != authority, "Verify must be distinct");
        require(ethMaxAge == ScoopProtocolDeploy.PROPOSED_ETH_MAX_AGE, "expected proposed ETH maxAge 86400");

        cfg = ScoopProtocolDeploy.Config({
            verificationAuthority: verificationAuthority,
            registryAuthority: authority,
            oracleAuthority: authority,
            launchFeeRecipient: launchFeeRecipient,
            buybackVault: buybackVault,
            operations: operations,
            ethMaxAge: ethMaxAge,
            includeAaplRehearsal: false,
            aaplMaxAge: 0
        });

        // Phase A: deploy globals. CREATE is from this test contract (fork persistence);
        // production addresses depend on Scoop Deploy 1 nonce (documented separately).
        d = ScoopProtocolDeploy.deployGlobals(cfg);
        ScoopProtocolDeploy.assertGlobalsDeployed(d, cfg);

        console2.log("forkBlock", forkBlock);
        console2.log("DEPLOYER_ADDRESS", deployer);
        console2.log("REGISTRY_AUTHORITY", authority);
        console2.log("VERIFICATION_AUTHORITY", verificationAuthority);
        console2.log("ScoopFactory", address(d.factory));
        console2.log("ScoopQuoteRegistry", address(d.quoteRegistry));
        console2.log("ScoopPriceOracle", address(d.priceOracle));
    }

    function test_phaseA_globalsDeployed_ethNotConfigured() public view {
        assertEq(address(d.factory), d.predictedFactory);
        assertEq(d.creatorRewards.sourceRegistrar(), address(d.factory));
        assertEq(address(d.factory.creatorRewards()), address(d.creatorRewards));
        assertEq(d.factory.launchFeeRecipient(), launchFeeRecipient);
        assertEq(d.factory.buybackVault(), buybackVault);
        assertEq(d.factory.operations(), operations);
        assertEq(d.creatorRegistry.verificationAuthority(), verificationAuthority);
        assertEq(d.quoteRegistry.registryAuthority(), authority);
        assertEq(d.priceOracle.oracleAuthority(), authority);

        assertFalse(d.quoteRegistry.isRegistered(address(0)));
        assertFalse(d.priceOracle.isConfigured(address(0)));
    }

    function test_recipients_areEOAs() public view {
        assertEq(launchFeeRecipient.code.length, 0, "Treasury must be EOA");
        assertEq(buybackVault.code.length, 0, "Buyback must be EOA");
        assertEq(operations.code.length, 0, "Operations must be EOA");
        console2.log("ETH RECEIVABILITY PRECHECK: PASS AS EOAs");
    }

    function test_deployer_cannotRegisterEthQuote() public {
        vm.prank(deployer);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        d.quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
    }

    function test_deployer_cannotConfigureEthFeed() public {
        vm.prank(deployer);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        d.priceOracle.configureFeed(address(0), ScoopProtocolDeploy.ETH_USD_FEED, ethMaxAge);
    }

    function test_verify_cannotRegisterEthQuote() public {
        vm.prank(verificationAuthority);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        d.quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
    }

    function test_verify_cannotConfigureEthFeed() public {
        vm.prank(verificationAuthority);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        d.priceOracle.configureFeed(address(0), ScoopProtocolDeploy.ETH_USD_FEED, ethMaxAge);
    }

    function test_requireSender_rejectsWrongDeployer() public {
        vm.prank(authority);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopProtocolDeploy.SenderMismatch.selector, "DEPLOYER_ADDRESS", deployer, authority)
        );
        this.externalRequireSender(deployer, "DEPLOYER_ADDRESS");
    }

    function test_requireSender_rejectsWrongAuthority() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopProtocolDeploy.SenderMismatch.selector, "REGISTRY_AUTHORITY", authority, deployer
            )
        );
        this.externalRequireSender(authority, "REGISTRY_AUTHORITY");
    }

    /// @dev External wrapper so expectRevert sees a lower call depth (library internals are inlined).
    function externalRequireSender(address expected, string calldata role) external view {
        ScoopProtocolDeploy.requireSender(expected, role);
    }

    function test_phaseB_authority_configuresEthOnly_aaplNotEnabled() public {
        vm.startPrank(authority);
        (uint256 qg, uint256 fg) =
            ScoopProtocolDeploy.configureEthQuoteAndOracle(d.quoteRegistry, d.priceOracle, ethMaxAge);
        vm.stopPrank();

        assertGt(qg, 0);
        assertGt(fg, 0);

        ScoopProtocolDeploy.assertEthConfigured(d.quoteRegistry, d.priceOracle, ethMaxAge);
        ScoopProtocolDeploy.assertAaplNotProductionRegistered(d.quoteRegistry);
        assertFalse(d.priceOracle.isConfigured(ScoopProtocolDeploy.AAPL_TOKEN));

        ScoopPriceOracle.PriceFeedConfig memory feed = d.priceOracle.getFeedConfig(address(0));
        assertEq(feed.feed, ScoopProtocolDeploy.ETH_USD_FEED);
        assertEq(feed.maxAge, 86_400);
        assertGt(d.priceOracle.getPriceUsd(address(0)), 0);
    }

    function test_endToEnd_twoSigner_thenAuthorityOnlyMutates() public {
        // Phase A already done in setUp.
        assertFalse(d.quoteRegistry.isRegistered(address(0)));

        // Wrong actors still blocked before Phase B succeeds.
        vm.prank(deployer);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        d.quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);

        // Phase B as Auth 1.
        vm.startPrank(authority);
        ScoopProtocolDeploy.configureEthQuoteAndOracle(d.quoteRegistry, d.priceOracle, ethMaxAge);
        vm.stopPrank();

        ScoopProtocolDeploy.assertEthConfigured(d.quoteRegistry, d.priceOracle, ethMaxAge);

        // Deployer still cannot mutate after configure.
        vm.prank(deployer);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        d.quoteRegistry.setQuoteEnabled(address(0), false);

        vm.prank(deployer);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        d.priceOracle.setFeedEnabled(address(0), false);
    }
}
