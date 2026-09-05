// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IScoopCreatorRewards
 * @notice Minimal credit surface used by ScoopFeeDistributor for the 70% creator allocation.
 * @dev Attribution (source → creatorId) lives inside ScoopCreatorRewards; the fee distributor
 *      never selects a creatorId at distribution time.
 */
interface IScoopCreatorRewards {
    function creditETH() external payable;

    function creditToken(address token, uint256 amount) external;
}
