// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {ScoopFactory} from "../../src/ScoopFactory.sol";

/// @dev P1 live-canary guards: old Factory bytecode lacks fee-config ABI.
library ScoopFeeConfigFactoryGuard {
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice True when `factory` exposes P1 `MAX_ADDITIONAL_FEE()`.
    function supportsFeeConfig(ScoopFactory factory) internal view returns (bool) {
        (bool ok, bytes memory data) = address(factory).staticcall(abi.encodeWithSignature("MAX_ADDITIONAL_FEE()"));
        return ok && data.length >= 32;
    }

    /// @notice Skip the current test when pointing at pre-P1 live Factory bytecode.
    function skipUnlessFeeConfig(ScoopFactory factory) internal {
        if (!supportsFeeConfig(factory)) {
            VM.skip(true);
        }
    }
}
