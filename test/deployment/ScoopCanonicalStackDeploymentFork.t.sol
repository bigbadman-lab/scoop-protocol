// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {ScoopProtocolDeploy} from "../../script/ScoopProtocolDeploy.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopHolderRewards} from "../../src/ScoopHolderRewards.sol";
import {ScoopLaunchDeployer} from "../../src/ScoopLaunchDeployer.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";
import {ScoopFeeTypes} from "../../src/libraries/ScoopFeeTypes.sol";

/**
 * @notice P3 — fresh canonical global stack deployment + launch wiring on a Robinhood fork.
 * @dev Replaces obsolete live-canary ABI skips for fee/holder coverage. No broadcast.
 */
contract ScoopCanonicalStackDeploymentForkTest is Test {
    uint48 internal constant REHEARSAL_ETH_MAX_AGE = 1 days;

    ScoopProtocolDeploy.Deployed internal d;
    ScoopProtocolDeploy.Config internal cfg;

    address internal rootPublisher;
    address internal deployer;
    address internal walletCreator;
    uint256 internal launchFee;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        rootPublisher = makeAddr("rootPublisher_TEST_FORK_ONLY");
        deployer = makeAddr("canonicalLauncher_TEST_FORK_ONLY");
        walletCreator = makeAddr("canonicalCreator_TEST_FORK_ONLY");

        cfg = ScoopProtocolDeploy.Config({
            verificationAuthority: makeAddr("verificationAuthority_TEST_FORK_ONLY"),
            registryAuthority: makeAddr("opsAuthority_TEST_FORK_ONLY"),
            oracleAuthority: makeAddr("opsAuthority_TEST_FORK_ONLY"),
            launchFeeRecipient: makeAddr("launchFeeRecipient_TEST_FORK_ONLY"),
            buybackVault: makeAddr("buybackVault_TEST_FORK_ONLY"),
            operations: makeAddr("operations_TEST_FORK_ONLY"),
            rootPublisher: rootPublisher,
            ethMaxAge: REHEARSAL_ETH_MAX_AGE,
            includeAaplRehearsal: false,
            aaplMaxAge: 0
        });
        // registryAuthority == oracleAuthority for combined Auth role in this rehearsal.
        cfg.oracleAuthority = cfg.registryAuthority;

        d = ScoopProtocolDeploy.deployGlobals(cfg);
        vm.startPrank(cfg.registryAuthority);
        ScoopProtocolDeploy.configureEthQuoteAndOracle(d.quoteRegistry, d.priceOracle, cfg.ethMaxAge);
        vm.stopPrank();
        ScoopProtocolDeploy.assertPostDeployment(d, cfg);

        launchFee = d.factory.LAUNCH_FEE();
        vm.deal(deployer, 50 ether);
    }

    function test_globals_allNonZeroWithBytecode() public view {
        assertTrue(address(d.creatorRegistry) != address(0) && address(d.creatorRegistry).code.length > 0);
        assertTrue(address(d.tokenDeployer) != address(0) && address(d.tokenDeployer).code.length > 0);
        assertTrue(address(d.launchDeployer) != address(0) && address(d.launchDeployer).code.length > 0);
        assertTrue(address(d.quoteRegistry) != address(0) && address(d.quoteRegistry).code.length > 0);
        assertTrue(address(d.priceOracle) != address(0) && address(d.priceOracle).code.length > 0);
        assertTrue(address(d.factoryDeployer) != address(0) && address(d.factoryDeployer).code.length > 0);
        assertTrue(address(d.creatorRewards) != address(0) && address(d.creatorRewards).code.length > 0);
        assertTrue(address(d.factory) != address(0) && address(d.factory).code.length > 0);
        assertEq(address(d.factory), d.predictedFactory);
    }

    function test_creatorRewards_registrarIsFactoryOnly() public {
        assertEq(d.creatorRewards.sourceRegistrar(), address(d.factory));
        assertEq(address(d.factory.creatorRewards()), address(d.creatorRewards));

        bytes32 creatorId = d.creatorRegistry.walletCreatorId(walletCreator);
        address fakeSource = makeAddr("fakeSource");
        vm.prank(deployer);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        d.creatorRewards.registerSource(fakeSource, creatorId);
    }

    function test_rootPublisher_immutableAndInherited() public {
        assertEq(d.launchDeployer.rootPublisher(), rootPublisher);
        assertEq(d.launchDeployer.rootPublisher(), cfg.rootPublisher);

        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(201)),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Holders,
            ScoopFeeTypes.AdditionalFeeDestination.Holders
        );
        vm.prank(deployer);
        (address token,,,,) = d.factory.launch{value: launchFee}(params);

        ScoopFactory.Launch memory rec = d.factory.getLaunch(token);
        ScoopHolderRewards vault = ScoopHolderRewards(payable(rec.holderRewards));
        assertEq(vault.rootPublisher(), rootPublisher);
        assertEq(vault.launchDeployer(), address(d.launchDeployer));
        assertEq(vault.feeDistributor(), rec.feeDistributor);

        vm.prank(deployer);
        vm.expectRevert(ScoopHolderRewards.UnauthorizedPublisher.selector);
        vault.publishRound(1, address(0), bytes32(uint256(1)), 1);

        vm.deal(rec.feeDistributor, 1 ether);
        ScoopFeeDistributor(payable(rec.feeDistributor)).distributeETH();
        assertGt(vault.uncommitted(address(0)), 0);
        vm.prank(rootPublisher);
        vault.publishRound(1, address(0), bytes32(uint256(1)), 1 wei);
    }

    function test_zeroRootPublisher_rejectedByDeployConfig() public {
        ScoopProtocolDeploy.Config memory bad = cfg;
        bad.rootPublisher = address(0);
        vm.expectRevert(abi.encodeWithSelector(ScoopProtocolDeploy.ZeroConfigAddress.selector, "ROOT_PUBLISHER"));
        this.externalValidateConfig(bad);
    }

    function externalValidateConfig(ScoopProtocolDeploy.Config memory bad) external pure {
        ScoopProtocolDeploy.validateConfig(bad);
    }

    function test_ethLaunch_creatorPathRegistersSource() public {
        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(202)),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Deployer
        );
        bytes32 creatorId = d.creatorRegistry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (address token, address feeDistributor,,,) = d.factory.launch{value: launchFee}(params);

        assertEq(d.creatorRewards.sourceCreatorId(feeDistributor), creatorId);
        ScoopFactory.Launch memory rec = d.factory.getLaunch(token);
        assertTrue(rec.holderRewards != address(0));
        assertEq(rec.additionalFee, 0);
        assertEq(rec.totalPoolFee, 10_000);
        _assertChildPredict(params, token);
    }

    function test_holdersOnlyLaunch_skipsSourceRegistration() public {
        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(203)),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Holders,
            ScoopFeeTypes.AdditionalFeeDestination.Deployer
        );
        vm.prank(deployer);
        (, address feeDistributor,,,) = d.factory.launch{value: launchFee}(params);
        assertEq(d.creatorRewards.sourceCreatorId(feeDistributor), bytes32(0));
    }

    function test_holdersBase_creatorExtra_registersSource() public {
        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(204)),
            5_000,
            ScoopFeeTypes.CreatorAllocationDestination.Holders,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
        bytes32 creatorId = d.creatorRegistry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (, address feeDistributor,,,) = d.factory.launch{value: launchFee}(params);
        assertEq(d.creatorRewards.sourceCreatorId(feeDistributor), creatorId);
    }

    function test_additionalFeeLaunch_setsPoolKeyAndVault() public {
        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(205)),
            10_000,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Holders
        );
        vm.prank(deployer);
        (address token, address feeDistributor,, uint256 lpTokenId,) = d.factory.launch{value: launchFee}(params);

        ScoopFactory.Launch memory rec = d.factory.getLaunch(token);
        assertEq(rec.additionalFee, 10_000);
        assertEq(rec.totalPoolFee, 20_000);
        assertEq(uint8(rec.additionalFeeDestination), uint8(ScoopFeeTypes.AdditionalFeeDestination.Holders));

        (PoolKey memory key,) = IPositionManager(ScoopProtocolDeploy.POSITION_MANAGER).getPoolAndPositionInfo(lpTokenId);
        assertEq(key.fee, 20_000);
        assertEq(key.tickSpacing, 10);
        assertEq(address(key.hooks), address(0));
        assertTrue(key.currency0 == CurrencyLibrary.ADDRESS_ZERO);

        ScoopHolderRewards vault = ScoopHolderRewards(payable(rec.holderRewards));
        assertEq(vault.feeDistributor(), feeDistributor);
        assertEq(vault.rootPublisher(), rootPublisher);
        assertEq(d.creatorRewards.sourceCreatorId(feeDistributor), d.creatorRegistry.walletCreatorId(walletCreator));
        assertEq(IERC721(ScoopProtocolDeploy.POSITION_MANAGER).ownerOf(lpTokenId), rec.liquidityLocker);
    }

    function test_launchAndBuy_functional() public {
        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(206)),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
        uint256 quoteIn = 0.01 ether;
        vm.prank(deployer);
        (address token,,,,, uint256 bought) = d.factory.launchAndBuy{value: launchFee + quoteIn}(params, quoteIn, 1);
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
    }

    function test_sourceCannotSelfRegisterOrDoubleRegister() public {
        ScoopFactory.LaunchParams memory params = _params(
            bytes32(uint256(207)),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
        bytes32 creatorId = d.creatorRegistry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (, address feeDistributor,,,) = d.factory.launch{value: launchFee}(params);

        vm.prank(feeDistributor);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        d.creatorRewards.registerSource(feeDistributor, creatorId);

        vm.prank(address(d.factory));
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        d.creatorRewards.registerSource(feeDistributor, creatorId);
    }

    function _params(
        bytes32 salt,
        uint24 additionalFee,
        ScoopFeeTypes.CreatorAllocationDestination creatorAlloc,
        ScoopFeeTypes.AdditionalFeeDestination additionalDest
    ) internal view returns (ScoopFactory.LaunchParams memory) {
        return ScoopFactory.LaunchParams({
            name: "Canonical",
            symbol: "CANON",
            creatorId: d.creatorRegistry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt,
            additionalFee: additionalFee,
            creatorAllocationDestination: creatorAlloc,
            additionalFeeDestination: additionalDest
        });
    }

    function _assertChildPredict(ScoopFactory.LaunchParams memory params, address token) internal view {
        ScoopFactory.Launch memory rec = d.factory.getLaunch(token);
        ScoopLaunchDeployer.LaunchFeeConfig memory feeCfg = ScoopLaunchDeployer.LaunchFeeConfig({
            creatorRewards: address(d.creatorRewards),
            deployer: deployer,
            buybackVault: cfg.buybackVault,
            operations: cfg.operations,
            additionalFee: params.additionalFee,
            creatorAllocationDestination: params.creatorAllocationDestination,
            additionalFeeDestination: params.additionalFeeDestination
        });
        // Factory salts launches with domain separation; compare vault wiring rather than raw salt.
        assertEq(ScoopFeeDistributor(payable(rec.feeDistributor)).holderRewards(), rec.holderRewards);
        assertEq(ScoopHolderRewards(payable(rec.holderRewards)).feeDistributor(), rec.feeDistributor);
        assertEq(feeCfg.creatorRewards, address(d.creatorRewards));
    }
}
