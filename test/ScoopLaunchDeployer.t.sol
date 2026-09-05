// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";

contract ScoopLaunchDeployerTest is Test {
    uint16 constant CREATOR_REWARDS_BPS = 7000;
    uint16 constant DEPLOYER_BPS = 400;
    uint16 constant BUYBACK_BPS = 2000;
    uint16 constant OPERATIONS_BPS = 600;

    address positionManager;
    address creatorRewards;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address caller;

    ScoopLaunchDeployer launchDeployer;

    event LaunchDeployed(
        address indexed caller, address indexed feeDistributor, address indexed liquidityLocker, bytes32 baseSalt
    );

    function setUp() public {
        positionManager = makeAddr("positionManager");
        creatorRewards = makeAddr("creatorRewards");
        deployerRecipient = makeAddr("deployer");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        caller = makeAddr("caller");

        launchDeployer = new ScoopLaunchDeployer(positionManager);
    }

    function _deploy(bytes32 baseSalt) internal returns (address distributor, address locker) {
        return launchDeployer.deployLaunch(
            creatorRewards,
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            baseSalt
        );
    }

    function _predict(bytes32 baseSalt) internal view returns (address distributor, address locker) {
        return launchDeployer.predictLaunch(
            creatorRewards,
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            baseSalt
        );
    }

    function test_constructorStoresPositionManager() public view {
        assertEq(launchDeployer.positionManager(), positionManager);
    }

    function test_constructorRejectsZeroPositionManager() public {
        vm.expectRevert(ScoopLaunchDeployer.ZeroPositionManager.selector);
        new ScoopLaunchDeployer(address(0));
    }

    function test_deployLaunchDeploysDistributorAndLockerWithBytecode() public {
        (address distributor, address locker) = _deploy(bytes32(uint256(1)));
        assertGt(distributor.code.length, 0);
        assertGt(locker.code.length, 0);
    }

    function test_deployedDistributorContainsCorrectFourWayConfig() public {
        (address distributorAddr,) = _deploy(bytes32(uint256(2)));
        ScoopFeeDistributor distributor = ScoopFeeDistributor(payable(distributorAddr));

        assertEq(distributor.creatorRewards(), creatorRewards);
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.creatorRewardsBps(), CREATOR_REWARDS_BPS);
        assertEq(distributor.deployerBps(), DEPLOYER_BPS);
        assertEq(distributor.buybackBps(), BUYBACK_BPS);
        assertEq(distributor.operationsBps(), OPERATIONS_BPS);
    }

    function test_v1EconomicsExposedOnDeployedDistributor() public {
        (address distributorAddr,) = _deploy(bytes32(uint256(100)));
        ScoopFeeDistributor distributor = ScoopFeeDistributor(payable(distributorAddr));

        assertEq(distributor.creatorRewardsBps(), 7000);
        assertEq(distributor.deployerBps(), 400);
        assertEq(distributor.buybackBps(), 2000);
        assertEq(distributor.operationsBps(), 600);
    }

    function test_deployedLockerContainsCorrectConfig() public {
        (address distributorAddr, address lockerAddr) = _deploy(bytes32(uint256(3)));
        ScoopLiquidityLocker locker = ScoopLiquidityLocker(lockerAddr);

        assertEq(address(locker.positionManager()), positionManager);
        assertEq(locker.feeDistributor(), distributorAddr);
    }

    function test_predictLaunchMatchesDeployed() public {
        bytes32 baseSalt = bytes32(uint256(4));
        (address predictedFeeDistributor, address predLocker) = _predict(baseSalt);
        (address distributor, address locker) = _deploy(baseSalt);
        assertEq(distributor, predictedFeeDistributor);
        assertEq(locker, predLocker);
    }

    function test_sameInputsAlwaysPredictSameAddresses() public {
        bytes32 baseSalt = bytes32(uint256(5));
        (address a1, address b1) = _predict(baseSalt);
        (address a2, address b2) = _predict(baseSalt);
        assertEq(a1, a2);
        assertEq(b1, b2);
    }

    function test_differentBaseSaltProducesDifferentAddresses() public {
        (address s1, address l1) = _predict(bytes32(uint256(10)));
        (address s2, address l2) = _predict(bytes32(uint256(11)));
        assertTrue(s1 != s2);
        assertTrue(l1 != l2);
    }

    function test_differentCreatorRewardsChangesDistributorAndLockerAddresses() public {
        bytes32 baseSalt = bytes32(uint256(12));
        (address s1, address l1) = _predict(baseSalt);
        (address s2, address l2) = launchDeployer.predictLaunch(
            makeAddr("otherCreatorRewards"),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            baseSalt
        );
        assertTrue(s1 != s2);
        assertTrue(l1 != l2);
    }

    function test_differentDeployerChangesDistributorAndLockerAddresses() public {
        bytes32 baseSalt = bytes32(uint256(13));
        (address s1, address l1) = _predict(baseSalt);
        (address s2, address l2) = launchDeployer.predictLaunch(
            creatorRewards,
            makeAddr("otherDeployer"),
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            baseSalt
        );
        assertTrue(s1 != s2);
        assertTrue(l1 != l2);
    }

    function test_differentBpsChangesPredictedAddresses() public {
        bytes32 baseSalt = bytes32(uint256(14));
        (address s1, address l1) = launchDeployer.predictLaunch(
            creatorRewards, deployerRecipient, buybackVault, operations, 7000, 400, 2000, 600, baseSalt
        );
        (address s2, address l2) = launchDeployer.predictLaunch(
            creatorRewards, deployerRecipient, buybackVault, operations, 6000, 500, 2500, 1000, baseSalt
        );
        assertTrue(s1 != s2);
        assertTrue(l1 != l2);
    }

    function test_duplicateDeploymentReverts() public {
        bytes32 baseSalt = bytes32(uint256(15));
        _deploy(baseSalt);
        vm.expectRevert(Errors.FailedDeployment.selector);
        _deploy(baseSalt);
    }

    function test_zeroCreatorRewardsReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        launchDeployer.deployLaunch(
            address(0),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            bytes32(uint256(16))
        );
    }

    function test_zeroDeployerReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        launchDeployer.deployLaunch(
            creatorRewards,
            address(0),
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            bytes32(uint256(17))
        );
    }

    function test_zeroBuybackVaultReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        launchDeployer.deployLaunch(
            creatorRewards,
            deployerRecipient,
            address(0),
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            bytes32(uint256(18))
        );
    }

    function test_zeroOperationsReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        launchDeployer.deployLaunch(
            creatorRewards,
            deployerRecipient,
            buybackVault,
            address(0),
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            bytes32(uint256(19))
        );
    }

    function test_invalidBpsBelow10000Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopFeeDistributor.InvalidBpsTotal.selector, uint16(9999)));
        launchDeployer.deployLaunch(
            creatorRewards, deployerRecipient, buybackVault, operations, 6999, 400, 2000, 600, bytes32(uint256(20))
        );
    }

    function test_invalidBpsAbove10000Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopFeeDistributor.InvalidBpsTotal.selector, uint16(10001)));
        launchDeployer.deployLaunch(
            creatorRewards, deployerRecipient, buybackVault, operations, 7001, 400, 2000, 600, bytes32(uint256(21))
        );
    }

    function test_failedDeploymentLeavesNoPredictedCode() public {
        bytes32 baseSalt = bytes32(uint256(22));
        (address predictedFeeDistributor, address predLocker) = launchDeployer.predictLaunch(
            address(0),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            baseSalt
        );

        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        launchDeployer.deployLaunch(
            address(0),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            baseSalt
        );

        assertEq(predictedFeeDistributor.code.length, 0);
        assertEq(predLocker.code.length, 0);
    }

    function test_permissionlessCallerCanDeploy() public {
        vm.prank(caller);
        (address distributor, address locker) = _deploy(bytes32(uint256(23)));
        assertGt(distributor.code.length, 0);
        assertGt(locker.code.length, 0);
    }

    function test_deployerHasNoOwnerAdmin() public {
        (bool ownerOk,) = address(launchDeployer).call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = address(launchDeployer).call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        (bool setOk,) = address(launchDeployer).call(abi.encodeWithSignature("setPositionManager(address)", caller));
        assertFalse(ownerOk);
        assertFalse(adminOk);
        assertFalse(setOk);
    }

    function test_deploymentEventEmitted() public {
        bytes32 baseSalt = bytes32(uint256(24));
        (address predictedFeeDistributor, address predLocker) = _predict(baseSalt);

        vm.expectEmit(true, true, true, true, address(launchDeployer));
        emit LaunchDeployed(address(this), predictedFeeDistributor, predLocker, baseSalt);

        (address distributor, address locker) = _deploy(baseSalt);
        assertEq(distributor, predictedFeeDistributor);
        assertEq(locker, predLocker);
    }

    function testFuzz_predictMatchesDeploy(bytes32 baseSalt, address c, address d, address b, address o) public {
        vm.assume(c != address(0) && d != address(0) && b != address(0) && o != address(0));

        bytes32 uniqueSalt = keccak256(abi.encode(baseSalt, c, d, b, o));

        (address predictedFeeDistributor, address predLocker) = launchDeployer.predictLaunch(
            c, d, b, o, CREATOR_REWARDS_BPS, DEPLOYER_BPS, BUYBACK_BPS, OPERATIONS_BPS, uniqueSalt
        );
        (address distributor, address locker) = launchDeployer.deployLaunch(
            c, d, b, o, CREATOR_REWARDS_BPS, DEPLOYER_BPS, BUYBACK_BPS, OPERATIONS_BPS, uniqueSalt
        );

        assertEq(distributor, predictedFeeDistributor);
        assertEq(locker, predLocker);
        assertEq(ScoopFeeDistributor(payable(distributor)).creatorRewardsBps(), CREATOR_REWARDS_BPS);
        assertEq(ScoopFeeDistributor(payable(distributor)).deployerBps(), DEPLOYER_BPS);
        assertEq(ScoopLiquidityLocker(locker).feeDistributor(), distributor);
    }
}
