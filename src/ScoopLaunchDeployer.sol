// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {ScoopFeeDistributor} from "./ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "./ScoopLiquidityLocker.sol";

/**
 * @title ScoopLaunchDeployer
 * @notice Deterministic CREATE2 deployment of per-launch ScoopFeeDistributor and ScoopLiquidityLocker.
 * @dev Fee distributor is deployed first. Locker address prediction depends on the predicted
 *      distributor address, which is passed as the locker's immutable feeDistributor.
 *      Launch economics remain immutable inside ScoopFeeDistributor (four-way destinations).
 *      The distributor's `creatorRewards` address is expected to be a ScoopCreatorRewards-
 *      compatible contract; source→creatorId registration is performed separately by the
 *      sourceRegistrar (ScoopFactory). This contract contains no liquidity or trading logic.
 */
contract ScoopLaunchDeployer {
    error ZeroPositionManager();

    /// @dev Domain separators for child-salt derivation from a caller-supplied baseSalt.
    bytes32 public constant DISTRIBUTOR_DOMAIN = keccak256("SCOOP_FEE_DISTRIBUTOR");
    bytes32 public constant LOCKER_DOMAIN = keccak256("SCOOP_LOCKER");

    address public immutable positionManager;

    event LaunchDeployed(
        address indexed caller, address indexed feeDistributor, address indexed liquidityLocker, bytes32 baseSalt
    );

    constructor(address positionManager_) {
        if (positionManager_ == address(0)) revert ZeroPositionManager();
        positionManager = positionManager_;
    }

    /// @notice Deploy immutable per-launch fee distributor then locker via CREATE2.
    function deployLaunch(
        address creatorRewards,
        address deployer_,
        address buybackVault,
        address operations,
        uint16 creatorRewardsBps,
        uint16 deployerBps,
        uint16 buybackBps,
        uint16 operationsBps,
        bytes32 baseSalt
    ) external returns (address feeDistributor, address liquidityLocker) {
        bytes memory distributorCtorArgs = abi.encode(
            creatorRewards,
            deployer_,
            buybackVault,
            operations,
            creatorRewardsBps,
            deployerBps,
            buybackBps,
            operationsBps
        );

        feeDistributor = Create2.deploy(
            0, _distributorSalt(baseSalt), abi.encodePacked(type(ScoopFeeDistributor).creationCode, distributorCtorArgs)
        );

        liquidityLocker = Create2.deploy(0, _lockerSalt(baseSalt), _lockerInitCode(feeDistributor));

        emit LaunchDeployed(msg.sender, feeDistributor, liquidityLocker, baseSalt);
    }

    /// @notice Predict CREATE2 addresses for fee distributor and locker for a given launch config.
    /// @dev Locker prediction uses the predicted fee distributor address as constructor input.
    function predictLaunch(
        address creatorRewards,
        address deployer_,
        address buybackVault,
        address operations,
        uint16 creatorRewardsBps,
        uint16 deployerBps,
        uint16 buybackBps,
        uint16 operationsBps,
        bytes32 baseSalt
    ) public view returns (address predictedFeeDistributor, address predictedLiquidityLocker) {
        bytes memory distributorCtorArgs = abi.encode(
            creatorRewards,
            deployer_,
            buybackVault,
            operations,
            creatorRewardsBps,
            deployerBps,
            buybackBps,
            operationsBps
        );

        predictedFeeDistributor = Create2.computeAddress(
            _distributorSalt(baseSalt),
            keccak256(abi.encodePacked(type(ScoopFeeDistributor).creationCode, distributorCtorArgs)),
            address(this)
        );

        predictedLiquidityLocker = Create2.computeAddress(
            _lockerSalt(baseSalt), keccak256(_lockerInitCode(predictedFeeDistributor)), address(this)
        );
    }

    function _distributorSalt(bytes32 baseSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseSalt, DISTRIBUTOR_DOMAIN));
    }

    function _lockerSalt(bytes32 baseSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseSalt, LOCKER_DOMAIN));
    }

    function _lockerInitCode(address feeDistributor) internal view returns (bytes memory) {
        return abi.encodePacked(type(ScoopLiquidityLocker).creationCode, abi.encode(positionManager, feeDistributor));
    }
}
