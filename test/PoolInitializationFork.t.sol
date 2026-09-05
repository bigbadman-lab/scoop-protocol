// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";

contract PoolInitializationForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @dev 1% static LP fee (10000 / 1e6)
    uint24 constant LP_FEE = 10_000;

    /// @dev Compatible with 1% fee tier (matches Uniswap Deployers: fee / 100 * 2)
    int24 constant TICK_SPACING = 200;

    /// @dev 1:1 raw unit price = sqrt(1) * 2^96 = TickMath.getSqrtPriceAtTick(0)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    uint256 constant SUPPLY = 1_000_000_000 ether;

    IPoolManager manager;
    ScoopTestToken scoopToken;
    address recipient;
    PoolKey key;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER_ADDR);
        recipient = makeAddr("recipient");

        scoopToken = new ScoopTestToken("SCOOP Test", "SCOOPT", recipient, SUPPLY);

        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency scoop = Currency.wrap(address(scoopToken));

        // Currencies MUST be sorted numerically (currency0 < currency1).
        (Currency currency0, Currency currency1) = scoop < eth ? (scoop, eth) : (eth, scoop);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function test_scoopTestTokenDeployed() public view {
        assertGt(address(scoopToken).code.length, 0);
        assertEq(scoopToken.name(), "SCOOP Test");
        assertEq(scoopToken.symbol(), "SCOOPT");
        assertEq(scoopToken.totalSupply(), SUPPLY);
        assertEq(scoopToken.balanceOf(recipient), SUPPLY);
    }

    function test_poolKeyCurrenciesSorted() public view {
        assertTrue(key.currency0 < key.currency1);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(scoopToken));
        assertEq(key.fee, LP_FEE);
        assertEq(key.tickSpacing, TICK_SPACING);
        assertEq(address(key.hooks), address(0));
    }

    function test_initializePoolSucceeds() public {
        int24 tick = manager.initialize(key, SQRT_PRICE_1_1);
        assertEq(tick, TickMath.getTickAtSqrtPrice(SQRT_PRICE_1_1));
    }

    function test_initializedPoolHasExpectedState() public {
        manager.initialize(key, SQRT_PRICE_1_1);

        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(0));
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, LP_FEE);
        assertGt(sqrtPriceX96, 0);
    }

    function test_reinitializeSamePoolReverts() public {
        manager.initialize(key, SQRT_PRICE_1_1);

        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, SQRT_PRICE_1_1);
    }
}
