// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract PoolManagerForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);
    }

    function test_poolManagerHasBytecode() public view {
        assertGt(POOL_MANAGER.code.length, 0);
    }

    function test_poolManagerCastsToIPoolManager() public view {
        IPoolManager manager = IPoolManager(POOL_MANAGER);
        assertEq(address(manager), POOL_MANAGER);
    }
}
