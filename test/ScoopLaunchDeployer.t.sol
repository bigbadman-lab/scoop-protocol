// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopHolderRewards} from "../src/ScoopHolderRewards.sol";
import {ScoopFeeTypes} from "../src/libraries/ScoopFeeTypes.sol";
import {ScoopFeeMath} from "../src/libraries/ScoopFeeMath.sol";

contract ScoopLaunchDeployerTest is Test {
    address positionManager;
    address rootPublisher;
    address creatorRewards;
    address deployerRecipient;
    address buybackVault;
    address operations;

    ScoopLaunchDeployer launchDeployer;

    function setUp() public {
        positionManager = makeAddr("positionManager");
        rootPublisher = makeAddr("rootPublisher");
        creatorRewards = makeAddr("creatorRewards");
        deployerRecipient = makeAddr("deployer");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");

        launchDeployer = new ScoopLaunchDeployer(positionManager, rootPublisher);
    }

    function _cfg(uint24 additionalFee) internal view returns (ScoopLaunchDeployer.LaunchFeeConfig memory) {
        return ScoopLaunchDeployer.LaunchFeeConfig({
            creatorRewards: creatorRewards,
            deployer: deployerRecipient,
            buybackVault: buybackVault,
            operations: operations,
            additionalFee: additionalFee,
            creatorAllocationDestination: ScoopFeeTypes.CreatorAllocationDestination.Creator,
            additionalFeeDestination: ScoopFeeTypes.AdditionalFeeDestination.Creator
        });
    }

    function _deploy(bytes32 baseSalt) internal returns (address distributor, address locker, address holder) {
        return launchDeployer.deployLaunch(_cfg(0), baseSalt);
    }

    function test_constructorStoresImmutables() public view {
        assertEq(launchDeployer.positionManager(), positionManager);
        assertEq(launchDeployer.rootPublisher(), rootPublisher);
    }

    function test_constructorRejectsZeroPositionManager() public {
        vm.expectRevert(ScoopLaunchDeployer.ZeroPositionManager.selector);
        new ScoopLaunchDeployer(address(0), rootPublisher);
    }

    function test_constructorRejectsZeroRootPublisher() public {
        vm.expectRevert(ScoopLaunchDeployer.ZeroRootPublisher.selector);
        new ScoopLaunchDeployer(positionManager, address(0));
    }

    function test_deployLaunchWiresHolderRewards() public {
        (address distributor, address locker, address holder) = _deploy(bytes32(uint256(1)));
        assertGt(distributor.code.length, 0);
        assertGt(locker.code.length, 0);
        assertGt(holder.code.length, 0);

        ScoopHolderRewards vault = ScoopHolderRewards(payable(holder));
        assertEq(vault.feeDistributor(), distributor);
        assertEq(vault.rootPublisher(), rootPublisher);
        assertEq(vault.launchDeployer(), address(launchDeployer));
        assertEq(ScoopFeeDistributor(payable(distributor)).holderRewards(), holder);
        assertEq(ScoopLiquidityLocker(locker).feeDistributor(), distributor);
    }

    function test_predictLaunchMatchesDeployed() public {
        bytes32 salt = bytes32(uint256(4));
        (address pDist, address pLock, address pHold) = launchDeployer.predictLaunch(_cfg(0), salt);
        (address distributor, address locker, address holder) = _deploy(salt);
        assertEq(distributor, pDist);
        assertEq(locker, pLock);
        assertEq(holder, pHold);
    }

    function test_differentAdditionalFeeDifferentDistributor() public {
        (address s1,,) = launchDeployer.predictLaunch(_cfg(0), bytes32(uint256(7)));
        (address s2,,) = launchDeployer.predictLaunch(_cfg(10_000), bytes32(uint256(7)));
        assertTrue(s1 != s2);
    }

    function test_duplicateSaltReverts() public {
        bytes32 salt = bytes32(uint256(8));
        _deploy(salt);
        vm.expectRevert(Errors.FailedDeployment.selector);
        _deploy(salt);
    }

    function test_invalidAdditionalFeeRevertsOnDeploy() public {
        ScoopLaunchDeployer.LaunchFeeConfig memory bad = _cfg(2500);
        vm.expectRevert(abi.encodeWithSelector(ScoopFeeMath.InvalidAdditionalFee.selector, uint24(2500)));
        launchDeployer.deployLaunch(bad, bytes32(uint256(9)));
    }

    function test_holderVaultAcceptsDistributorDeposits() public {
        ScoopLaunchDeployer.LaunchFeeConfig memory cfg = ScoopLaunchDeployer.LaunchFeeConfig({
            creatorRewards: creatorRewards,
            deployer: deployerRecipient,
            buybackVault: buybackVault,
            operations: operations,
            additionalFee: 10_000,
            creatorAllocationDestination: ScoopFeeTypes.CreatorAllocationDestination.Holders,
            additionalFeeDestination: ScoopFeeTypes.AdditionalFeeDestination.Holders
        });
        (address distributor,, address holder) = launchDeployer.deployLaunch(cfg, bytes32(uint256(42)));
        ScoopHolderRewards vault = ScoopHolderRewards(payable(holder));

        vm.deal(distributor, 30_000);
        ScoopFeeDistributor(payable(distributor)).distributeETH();

        assertEq(vault.uncommitted(address(0)), 25_500);
        assertEq(vault.totalDeposited(address(0)), 25_500);
        assertEq(deployerRecipient.balance, 600);
        assertEq(buybackVault.balance, 3000);
        assertEq(operations.balance, 900);
    }

    function test_predictedHolderMatchesAndOnlyLaunchDeployerInits() public {
        ScoopLaunchDeployer.LaunchFeeConfig memory cfg = _cfg(0);
        bytes32 salt = bytes32(uint256(77));
        (address pDist, address pLock, address pHold) = launchDeployer.predictLaunch(cfg, salt);

        // Pre-deploy: predicted vault has no code — no initializer surface yet.
        assertEq(pHold.code.length, 0);

        (address distributor, address locker, address holder) = launchDeployer.deployLaunch(cfg, salt);
        assertEq(distributor, pDist);
        assertEq(locker, pLock);
        assertEq(holder, pHold);

        ScoopHolderRewards vault = ScoopHolderRewards(payable(holder));
        assertEq(vault.feeDistributor(), distributor);
        assertEq(vault.rootPublisher(), rootPublisher);
        assertEq(vault.launchDeployer(), address(launchDeployer));

        // Post-deploy: write-once already consumed by LaunchDeployer.
        vm.prank(address(launchDeployer));
        vm.expectRevert(ScoopHolderRewards.AlreadyInitialized.selector);
        vault.initializeFeeDistributor(makeAddr("other"));
    }

    function test_launcherCannotOverrideRootPublisher() public view {
        // LaunchFeeConfig / LaunchParams have no publisher field; publisher is LaunchDeployer immutable only.
        ScoopLaunchDeployer.LaunchFeeConfig memory cfg = _cfg(0);
        assertEq(launchDeployer.rootPublisher(), rootPublisher);
        // Silence unused warning for cfg shape stability.
        assertEq(cfg.additionalFee, 0);
    }
}
