// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ScoopToken
 * @notice Production fixed-supply ERC-20 for a SCOOP Protocol V1 market launch.
 * @dev Mints the entire `MAX_SUPPLY` to `recipient_` at construction. There is no
 *      post-deployment mint authority, owner, pause, tax, or transfer restriction.
 */
contract ScoopToken is ERC20 {
    error ZeroRecipient();

    /// @notice Hard-fixed launch supply for every standard SCOOP market token.
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    constructor(string memory name_, string memory symbol_, address recipient_) ERC20(name_, symbol_) {
        if (recipient_ == address(0)) revert ZeroRecipient();
        _mint(recipient_, MAX_SUPPLY);
    }
}
