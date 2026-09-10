// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {ScoopFeeDistributor} from "./ScoopFeeDistributor.sol";
import {ScoopHolderRewards} from "./ScoopHolderRewards.sol";
import {ScoopLiquidityLocker} from "./ScoopLiquidityLocker.sol";
import {ScoopFeeTypes} from "./libraries/ScoopFeeTypes.sol";

/**
 * @title ScoopLaunchDeployer
 * @notice Deterministic CREATE2 deployment of per-launch fee modules and LP locker.
 * @dev Deploy order: ScoopHolderRewards → FeeDistributor → initializeFeeDistributor → LiquidityLocker.
 *      HolderRewards needs the distributor address and vice versa; feeDistributor is bound once
 *      via `initializeFeeDistributor` (LaunchDeployer-only) after both CREATE2 deploys.
 */
contract ScoopLaunchDeployer {
    error ZeroPositionManager();
    error ZeroRootPublisher();

    bytes32 public constant HOLDER_DOMAIN = keccak256("SCOOP_HOLDER_REWARDS");
    bytes32 public constant DISTRIBUTOR_DOMAIN = keccak256("SCOOP_FEE_DISTRIBUTOR");
    bytes32 public constant LOCKER_DOMAIN = keccak256("SCOOP_LOCKER");

    address public immutable positionManager;
    /// @notice Protocol-level Merkle root publisher for all launches from this deployer.
    address public immutable rootPublisher;

    struct LaunchFeeConfig {
        address creatorRewards;
        address deployer;
        address buybackVault;
        address operations;
        uint24 additionalFee;
        ScoopFeeTypes.CreatorAllocationDestination creatorAllocationDestination;
        ScoopFeeTypes.AdditionalFeeDestination additionalFeeDestination;
    }

    event LaunchDeployed(
        address indexed caller,
        address indexed feeDistributor,
        address indexed liquidityLocker,
        address holderRewards,
        bytes32 baseSalt
    );

    constructor(address positionManager_, address rootPublisher_) {
        if (positionManager_ == address(0)) revert ZeroPositionManager();
        if (rootPublisher_ == address(0)) revert ZeroRootPublisher();
        positionManager = positionManager_;
        rootPublisher = rootPublisher_;
    }

    /// @notice Deploy immutable per-launch holder vault, fee distributor, then locker via CREATE2.
    function deployLaunch(LaunchFeeConfig calldata config, bytes32 baseSalt)
        external
        returns (address feeDistributor, address liquidityLocker, address holderRewards)
    {
        holderRewards = Create2.deploy(
            0,
            _holderSalt(baseSalt),
            abi.encodePacked(type(ScoopHolderRewards).creationCode, abi.encode(rootPublisher, address(this)))
        );

        bytes memory distributorCtorArgs = abi.encode(
            config.creatorRewards,
            config.deployer,
            config.buybackVault,
            config.operations,
            holderRewards,
            config.additionalFee,
            config.creatorAllocationDestination,
            config.additionalFeeDestination
        );

        feeDistributor = Create2.deploy(
            0, _distributorSalt(baseSalt), abi.encodePacked(type(ScoopFeeDistributor).creationCode, distributorCtorArgs)
        );

        ScoopHolderRewards(payable(holderRewards)).initializeFeeDistributor(feeDistributor);

        liquidityLocker = Create2.deploy(0, _lockerSalt(baseSalt), _lockerInitCode(feeDistributor));

        emit LaunchDeployed(msg.sender, feeDistributor, liquidityLocker, holderRewards, baseSalt);
    }

    /// @notice Predict CREATE2 addresses for a given launch fee config + salt.
    function predictLaunch(LaunchFeeConfig calldata config, bytes32 baseSalt)
        public
        view
        returns (address predictedFeeDistributor, address predictedLiquidityLocker, address predictedHolderRewards)
    {
        predictedHolderRewards = Create2.computeAddress(
            _holderSalt(baseSalt),
            keccak256(
                abi.encodePacked(type(ScoopHolderRewards).creationCode, abi.encode(rootPublisher, address(this)))
            ),
            address(this)
        );

        bytes memory distributorCtorArgs = abi.encode(
            config.creatorRewards,
            config.deployer,
            config.buybackVault,
            config.operations,
            predictedHolderRewards,
            config.additionalFee,
            config.creatorAllocationDestination,
            config.additionalFeeDestination
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

    function _holderSalt(bytes32 baseSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(baseSalt, HOLDER_DOMAIN));
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
