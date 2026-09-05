// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain fixed-supply ERC-20 for SCOOP protocol testing. Not production architecture.
contract ScoopTestToken is ERC20 {
    error ZeroRecipient();

    constructor(string memory name_, string memory symbol_, address recipient_, uint256 supply_) ERC20(name_, symbol_) {
        if (recipient_ == address(0)) revert ZeroRecipient();
        _mint(recipient_, supply_);
    }
}
