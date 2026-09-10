// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IScoopCreatorRewards} from "./interfaces/IScoopCreatorRewards.sol";
import {ScoopFeeMath} from "./libraries/ScoopFeeMath.sol";
import {ScoopFeeTypes} from "./libraries/ScoopFeeTypes.sol";

/**
 * @title ScoopFeeDistributor
 * @notice Immutable per-launch fee distribution for SCOOP Protocol.
 * @dev Receives native ETH and/or ERC-20 assets (typically collected Uniswap v4 LP fees)
 *      and splits the current balance into:
 *      - basePart  proportional to BASE_FEE / totalPoolFee → 70/4/20/6 economics
 *      - extraPart proportional to additionalFee / totalPoolFee → 100% one destination
 *
 *      Creator allocation (70% of base) routes to CreatorRewards or holderRewards.
 *      Additional fee routes to Creator, Deployer, or Holders.
 *
 *      Creator identity attribution is external: ScoopCreatorRewards resolves
 *      `sourceCreatorId[address(this)]`. This distributor never stores a creatorId.
 *
 *      Permissionless: anyone may call `distributeETH` / `distributeToken`.
 *      Configuration is permanent: no owner, no setters, no rescue, no upgrade path.
 */
contract ScoopFeeDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ScoopFeeMath for uint24;

    error ZeroRecipient();
    error ZeroToken();
    error ZeroBalance();
    error NativeTransferFailed(address recipient, uint256 amount);
    error HolderRewardsRequired();

    address public immutable creatorRewards;
    address public immutable deployer;
    address public immutable buybackVault;
    address public immutable operations;
    address public immutable holderRewards;

    uint24 public immutable baseFee;
    uint24 public immutable additionalFee;
    uint24 public immutable totalPoolFee;
    ScoopFeeTypes.CreatorAllocationDestination public immutable creatorAllocationDestination;
    ScoopFeeTypes.AdditionalFeeDestination public immutable additionalFeeDestination;

    uint16 public constant CREATOR_REWARDS_BPS = ScoopFeeMath.CREATOR_REWARDS_BPS;
    uint16 public constant DEPLOYER_BPS = ScoopFeeMath.DEPLOYER_BPS;
    uint16 public constant BUYBACK_BPS = ScoopFeeMath.BUYBACK_BPS;
    uint16 public constant OPERATIONS_BPS = ScoopFeeMath.OPERATIONS_BPS;

    event ETHDistributed(
        uint256 totalAmount,
        uint256 basePart,
        uint256 extraPart,
        uint256 baseCreatorAmount,
        uint256 baseHoldersAmount,
        uint256 baseDeployerAmount,
        uint256 baseBuybackAmount,
        uint256 baseOperationsAmount,
        uint256 extraCreatorAmount,
        uint256 extraDeployerAmount,
        uint256 extraHoldersAmount
    );

    event TokenDistributed(
        address indexed token,
        uint256 totalAmount,
        uint256 basePart,
        uint256 extraPart,
        uint256 baseCreatorAmount,
        uint256 baseHoldersAmount,
        uint256 baseDeployerAmount,
        uint256 baseBuybackAmount,
        uint256 baseOperationsAmount,
        uint256 extraCreatorAmount,
        uint256 extraDeployerAmount,
        uint256 extraHoldersAmount
    );

    constructor(
        address creatorRewards_,
        address deployer_,
        address buybackVault_,
        address operations_,
        address holderRewards_,
        uint24 additionalFee_,
        ScoopFeeTypes.CreatorAllocationDestination creatorAllocationDestination_,
        ScoopFeeTypes.AdditionalFeeDestination additionalFeeDestination_
    ) {
        if (
            creatorRewards_ == address(0) || deployer_ == address(0) || buybackVault_ == address(0)
                || operations_ == address(0)
        ) {
            revert ZeroRecipient();
        }

        ScoopFeeMath.validateAdditionalFee(additionalFee_);
        ScoopFeeMath.validateCreatorAllocationDestination(creatorAllocationDestination_);
        ScoopFeeMath.validateAdditionalFeeDestination(additionalFeeDestination_);

        if (
            ScoopFeeMath.usesHoldersPath(creatorAllocationDestination_, additionalFeeDestination_)
                && holderRewards_ == address(0)
        ) {
            revert HolderRewardsRequired();
        }

        creatorRewards = creatorRewards_;
        deployer = deployer_;
        buybackVault = buybackVault_;
        operations = operations_;
        holderRewards = holderRewards_;
        baseFee = ScoopFeeMath.BASE_FEE;
        additionalFee = additionalFee_;
        totalPoolFee = ScoopFeeMath.totalPoolFee(additionalFee_);
        creatorAllocationDestination = creatorAllocationDestination_;
        additionalFeeDestination = additionalFeeDestination_;
    }

    receive() external payable {}

    function distributeETH() external nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroBalance();

        ScoopFeeMath.SplitResult memory s =
            ScoopFeeMath.split(balance, additionalFee, creatorAllocationDestination, additionalFeeDestination);

        uint256 creatorTotal = s.baseCreatorAmount + s.extraCreatorAmount;
        if (creatorTotal > 0) {
            IScoopCreatorRewards(creatorRewards).creditETH{value: creatorTotal}();
        }

        uint256 holdersTotal = s.baseHoldersAmount + s.extraHoldersAmount;
        _sendETH(holderRewards, holdersTotal);

        _sendETH(deployer, s.baseDeployerAmount + s.extraDeployerAmount);
        _sendETH(buybackVault, s.baseBuybackAmount);
        _sendETH(operations, s.baseOperationsAmount);

        emit ETHDistributed(
            balance,
            s.basePart,
            s.extraPart,
            s.baseCreatorAmount,
            s.baseHoldersAmount,
            s.baseDeployerAmount,
            s.baseBuybackAmount,
            s.baseOperationsAmount,
            s.extraCreatorAmount,
            s.extraDeployerAmount,
            s.extraHoldersAmount
        );
    }

    function distributeToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroToken();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        ScoopFeeMath.SplitResult memory s =
            ScoopFeeMath.split(balance, additionalFee, creatorAllocationDestination, additionalFeeDestination);

        uint256 creatorTotal = s.baseCreatorAmount + s.extraCreatorAmount;
        if (creatorTotal > 0) {
            IERC20(token).forceApprove(creatorRewards, creatorTotal);
            IScoopCreatorRewards(creatorRewards).creditToken(token, creatorTotal);
            IERC20(token).forceApprove(creatorRewards, 0);
        }

        uint256 holdersTotal = s.baseHoldersAmount + s.extraHoldersAmount;
        if (holdersTotal > 0) {
            IERC20(token).safeTransfer(holderRewards, holdersTotal);
        }

        uint256 deployerTotal = s.baseDeployerAmount + s.extraDeployerAmount;
        if (deployerTotal > 0) {
            IERC20(token).safeTransfer(deployer, deployerTotal);
        }
        if (s.baseBuybackAmount > 0) {
            IERC20(token).safeTransfer(buybackVault, s.baseBuybackAmount);
        }
        if (s.baseOperationsAmount > 0) {
            IERC20(token).safeTransfer(operations, s.baseOperationsAmount);
        }

        emit TokenDistributed(
            token,
            balance,
            s.basePart,
            s.extraPart,
            s.baseCreatorAmount,
            s.baseHoldersAmount,
            s.baseDeployerAmount,
            s.baseBuybackAmount,
            s.baseOperationsAmount,
            s.extraCreatorAmount,
            s.extraDeployerAmount,
            s.extraHoldersAmount
        );
    }

    function _sendETH(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);
    }
}
