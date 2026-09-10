// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IScoopHolderRewards} from "../../src/interfaces/IScoopHolderRewards.sol";

/// @dev Minimal holder vault stand-in for FeeDistributor unit tests.
contract MockHolderRewards is IScoopHolderRewards {
    uint256 public ethDeposited;
    mapping(address => uint256) public tokenDeposited;

    function depositETH() external payable override {
        ethDeposited += msg.value;
    }

    function depositToken(address token, uint256 amount) external override {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenDeposited[token] += amount;
    }
}
