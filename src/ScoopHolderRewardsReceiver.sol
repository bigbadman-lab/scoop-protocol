// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ScoopHolderRewardsReceiver
 * @notice P1 custody sink for holder-directed fee legs.
 * @dev Accepts native ETH and ERC-20 transfers. No Merkle/push/claim logic — that is P2
 *      (`ScoopHolderRewards`). Per-launch CREATE2 instance keeps holder funds isolated.
 */
contract ScoopHolderRewardsReceiver {
    event ETHReceived(address indexed from, uint256 amount);

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }
}
