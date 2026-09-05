// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IScoopCreatorRewards} from "./interfaces/IScoopCreatorRewards.sol";

/**
 * @title ScoopFeeDistributor
 * @notice Immutable per-launch fee distribution primitive for SCOOP Protocol V1.
 * @dev Receives native ETH and/or ERC-20 assets (typically collected Uniswap v4 LP fees)
 *      and splits the current balance across four immutable destinations according to
 *      immutable basis-point weights that must sum to exactly 10_000 at deployment:
 *      creatorRewards, deployer, buybackVault, and operations.
 *
 *      The creator allocation is credited into a ScoopCreatorRewards-compatible contract
 *      via `creditETH` / `creditToken`. Creator identity attribution is external to this
 *      distributor: the rewards contract resolves `sourceCreatorId[address(this)]` permanently.
 *      This distributor never chooses or stores a creatorId.
 *
 *      Deployer, buybackVault, and operations remain direct transfer destinations.
 *      `buybackVault` receives an allocation but does NOT execute $SCOOP buybacks.
 *
 *      Permissionless: anyone may call `distributeETH` / `distributeToken`.
 *      The caller receives no reward.
 *
 *      Rounding: creatorRewards, deployer, and buyback amounts are floored via integer
 *      division; any remainder is assigned to operations so the full balance is allocated.
 *
 *      Configuration is permanent: no owner, no setters, no rescue, no upgrade path.
 */
contract ScoopFeeDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    error ZeroRecipient();
    error InvalidBpsTotal(uint16 total);
    error ZeroToken();
    error ZeroBalance();
    error NativeTransferFailed(address recipient, uint256 amount);

    /// @notice ScoopCreatorRewards-compatible credit destination for the creator allocation.
    address public immutable creatorRewards;
    address public immutable deployer;
    address public immutable buybackVault;
    address public immutable operations;

    uint16 public immutable creatorRewardsBps;
    uint16 public immutable deployerBps;
    uint16 public immutable buybackBps;
    uint16 public immutable operationsBps;

    event ETHDistributed(
        uint256 totalAmount,
        uint256 creatorRewardsAmount,
        uint256 deployerAmount,
        uint256 buybackAmount,
        uint256 operationsAmount
    );

    event TokenDistributed(
        address indexed token,
        uint256 totalAmount,
        uint256 creatorRewardsAmount,
        uint256 deployerAmount,
        uint256 buybackAmount,
        uint256 operationsAmount
    );

    constructor(
        address creatorRewards_,
        address deployer_,
        address buybackVault_,
        address operations_,
        uint16 creatorRewardsBps_,
        uint16 deployerBps_,
        uint16 buybackBps_,
        uint16 operationsBps_
    ) {
        if (
            creatorRewards_ == address(0) || deployer_ == address(0) || buybackVault_ == address(0)
                || operations_ == address(0)
        ) {
            revert ZeroRecipient();
        }

        uint16 totalBps = creatorRewardsBps_ + deployerBps_ + buybackBps_ + operationsBps_;
        if (totalBps != BPS_DENOMINATOR) revert InvalidBpsTotal(totalBps);

        creatorRewards = creatorRewards_;
        deployer = deployer_;
        buybackVault = buybackVault_;
        operations = operations_;
        creatorRewardsBps = creatorRewardsBps_;
        deployerBps = deployerBps_;
        buybackBps = buybackBps_;
        operationsBps = operationsBps_;
    }

    /// @notice Accept native ETH deposits (e.g. forwarded LP fee collections).
    receive() external payable {}

    /// @notice Permissionlessly distribute the distributor's entire ETH balance.
    function distributeETH() external nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroBalance();

        (uint256 creatorRewardsAmount, uint256 deployerAmount, uint256 buybackAmount, uint256 operationsAmount) =
            _split(balance);

        // Creator first via credit API; remaining legs are direct transfers. Any failure reverts all.
        if (creatorRewardsAmount > 0) {
            IScoopCreatorRewards(creatorRewards).creditETH{value: creatorRewardsAmount}();
        }
        _sendETH(deployer, deployerAmount);
        _sendETH(buybackVault, buybackAmount);
        _sendETH(operations, operationsAmount);

        emit ETHDistributed(balance, creatorRewardsAmount, deployerAmount, buybackAmount, operationsAmount);
    }

    /// @notice Permissionlessly distribute the distributor's entire balance of `token`.
    function distributeToken(address token) external nonReentrant {
        if (token == address(0)) revert ZeroToken();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert ZeroBalance();

        (uint256 creatorRewardsAmount, uint256 deployerAmount, uint256 buybackAmount, uint256 operationsAmount) =
            _split(balance);

        if (creatorRewardsAmount > 0) {
            // Exact allowance for this credit only; reset afterward for non-standard ERC-20s.
            IERC20(token).forceApprove(creatorRewards, creatorRewardsAmount);
            IScoopCreatorRewards(creatorRewards).creditToken(token, creatorRewardsAmount);
            IERC20(token).forceApprove(creatorRewards, 0);
        }

        IERC20(token).safeTransfer(deployer, deployerAmount);
        IERC20(token).safeTransfer(buybackVault, buybackAmount);
        IERC20(token).safeTransfer(operations, operationsAmount);

        emit TokenDistributed(token, balance, creatorRewardsAmount, deployerAmount, buybackAmount, operationsAmount);
    }

    /// @dev Floor creatorRewards/deployer/buyback; remainder goes to operations.
    function _split(uint256 balance)
        internal
        view
        returns (uint256 creatorRewardsAmount, uint256 deployerAmount, uint256 buybackAmount, uint256 operationsAmount)
    {
        creatorRewardsAmount = (balance * creatorRewardsBps) / BPS_DENOMINATOR;
        deployerAmount = (balance * deployerBps) / BPS_DENOMINATOR;
        buybackAmount = (balance * buybackBps) / BPS_DENOMINATOR;
        operationsAmount = balance - creatorRewardsAmount - deployerAmount - buybackAmount;
    }

    function _sendETH(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert NativeTransferFailed(recipient, amount);
    }
}
