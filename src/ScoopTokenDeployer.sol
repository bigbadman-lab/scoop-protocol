// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {ScoopToken} from "./ScoopToken.sol";

/**
 * @title ScoopTokenDeployer
 * @notice Deterministic CREATE2 deployment primitive for ScoopToken.
 * @dev Predicts and deploys ScoopToken instances from a caller-supplied salt and
 *      constructor args. Launch economics (liquidity, fees, locking) are not handled here.
 */
contract ScoopTokenDeployer {
    event TokenDeployed(
        address indexed token,
        address indexed caller,
        address indexed recipient,
        bytes32 salt,
        string name,
        string symbol
    );

    /// @notice Deploy a ScoopToken via CREATE2 and mint its full supply to `recipient`.
    function deployToken(string calldata name, string calldata symbol, address recipient, bytes32 salt)
        external
        returns (address token)
    {
        bytes memory initCode = _initCode(name, symbol, recipient);
        token = Create2.deploy(0, salt, initCode);
        emit TokenDeployed(token, msg.sender, recipient, salt, name, symbol);
    }

    /// @notice Predict the CREATE2 address for a ScoopToken deployment from this deployer.
    function predictTokenAddress(string calldata name, string calldata symbol, address recipient, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(_initCode(name, symbol, recipient));
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    function _initCode(string calldata name, string calldata symbol, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(type(ScoopToken).creationCode, abi.encode(name, symbol, recipient));
    }
}
