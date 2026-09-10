// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IScoopHolderRewards
 * @notice Deposit surface used by ScoopFeeDistributor for holder-directed fee legs.
 */
interface IScoopHolderRewards {
    function depositETH() external payable;

    function depositToken(address token, uint256 amount) external;
}
