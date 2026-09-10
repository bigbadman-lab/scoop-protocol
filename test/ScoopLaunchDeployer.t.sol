// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopHolderRewardsReceiver} from "../src/ScoopHolderRewardsReceiver.sol";
import {ScoopFeeTypes} from "../src/libraries/ScoopFeeTypes.sol";
import {ScoopFeeMath} from "../src/libraries/ScoopFeeMath.sol";

contract ScoopLaunchDeployerTest is Test {
    address positionManager;
    address creatorRewards;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address caller;

    ScoopLaunchDeployer launchDeployer;

    function setUp() public {
        positionManager = makeAddr("positionManager");
        creatorRewards = makeAddr("creatorRewards");
        deployerRecipient = makeAddr("deployer");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        caller = makeAddr("caller");

        launchDeployer = new ScoopLaunchDeployer(positionManager);
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

    function _predict(bytes32 baseSalt) internal view returns (address distributor, address locker, address holder) {
        return launchDeployer.predictLaunch(_cfg(0), baseSalt);
    }

    function test_constructorStoresPositionManager() public view {
        assertEq(launchDeployer.positionManager(), positionManager);
    }

    function test_constructorRejectsZeroPositionManager() public {
        vm.expectRevert(ScoopLaunchDeployer.ZeroPositionManager.selector);
        new ScoopLaunchDeployer(address(0));
    }

    function test_deployLaunchDeploysThreeModules() public {
        (address distributor, address locker, address holder) = _deploy(bytes32(uint256(1)));
        assertGt(distributor.code.length, 0);
        assertGt(locker.code.length, 0);
        assertGt(holder.code.length, 0);
    }

    function test_deployedDistributorContainsCorrectConfig() public {
        (address distributorAddr,, address holder) = _deploy(bytes32(uint256(2)));
        ScoopFeeDistributor distributor = ScoopFeeDistributor(payable(distributorAddr));

        assertEq(distributor.creatorRewards(), creatorRewards);
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.holderRewards(), holder);
        assertEq(distributor.additionalFee(), 0);
        assertEq(distributor.totalPoolFee(), 10_000);
        assertEq(distributor.CREATOR_REWARDS_BPS(), 7000);
    }

    function test_deployedLockerContainsCorrectConfig() public {
        (address distributorAddr, address lockerAddr,) = _deploy(bytes32(uint256(3)));
        ScoopLiquidityLocker locker = ScoopLiquidityLocker(lockerAddr);

        assertEq(address(locker.positionManager()), positionManager);
        assertEq(locker.feeDistributor(), distributorAddr);
    }

    function test_predictLaunchMatchesDeployed() public {
        bytes32 baseSalt = bytes32(uint256(4));
        (address pDist, address pLock, address pHold) = _predict(baseSalt);
        (address distributor, address locker, address holder) = _deploy(baseSalt);
        assertEq(distributor, pDist);
        assertEq(locker, pLock);
        assertEq(holder, pHold);
    }

    function test_differentSaltsDifferentAddresses() public {
        (address s1,,) = _predict(bytes32(uint256(5)));
        (address s2,,) = _predict(bytes32(uint256(6)));
        assertTrue(s1 != s2);
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
}
