// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {ScoopTestToken} from "../src/ScoopTestToken.sol";

interface IHasPermit2 {
    function permit2() external view returns (IAllowanceTransfer);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Buy ScoopTestToken with ETH, then sell Scoop back for ETH, against one-sided
 *         liquidity on the canonical Robinhood Uniswap v4 stack.
 *
 * Routing: Universal Router command V4_SWAP (0x10) → V4Router actions
 *   SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL
 *
 * Liquidity is concentrated in [-400, -200] while the pool opens at tick 0. A zeroForOne
 * buy moves price down into that range; the subsequent sell moves price back up.
 */
contract SwapForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    /// @dev Universal Router Commands.V4_SWAP
    uint8 constant CMD_V4_SWAP = 0x10;

    uint24 constant LP_FEE = 10_000;
    int24 constant TICK_SPACING = 200;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    int24 constant TICK_LOWER = -400;
    int24 constant TICK_UPPER = -200;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LIQUIDITY_AMOUNT = 100_000_000 ether;
    uint256 constant BUY_ETH_AMOUNT = 0.01 ether;

    IPoolManager manager;
    IPositionManager posm;
    IUniversalRouter router;
    IAllowanceTransfer permit2;
    ScoopTestToken scoopToken;
    PoolKey key;
    PoolId poolId;
    address trader;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER_ADDR);
        posm = IPositionManager(POSITION_MANAGER_ADDR);
        router = IUniversalRouter(UNIVERSAL_ROUTER_ADDR);
        permit2 = IHasPermit2(POSITION_MANAGER_ADDR).permit2();

        assertGt(POOL_MANAGER_ADDR.code.length, 0, "PoolManager");
        assertGt(POSITION_MANAGER_ADDR.code.length, 0, "PositionManager");
        assertGt(UNIVERSAL_ROUTER_ADDR.code.length, 0, "UniversalRouter");
        assertGt(address(permit2).code.length, 0, "Permit2");

        scoopToken = new ScoopTestToken("SCOOP Test", "SCOOPT", address(this), SUPPLY);

        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency scoop = Currency.wrap(address(scoopToken));
        (Currency currency0, Currency currency1) = scoop < eth ? (scoop, eth) : (eth, scoop);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = key.toId();

        manager.initialize(key, SQRT_PRICE_1_1);
        _mintOneSidedLiquidity();

        trader = makeAddr("trader");
        vm.deal(trader, 1 ether);
    }

    function test_buyScoopWithEth() public {
        (uint160 sqrtBefore, int24 tickBefore,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, LP_FEE);

        uint256 ethBefore = trader.balance;
        uint256 scoopBefore = scoopToken.balanceOf(trader);

        uint256 scoopReceived = _buyScoop(BUY_ETH_AMOUNT);

        assertGt(scoopReceived, 0, "received Scoop");
        assertEq(scoopToken.balanceOf(trader), scoopBefore + scoopReceived);
        assertEq(trader.balance, ethBefore - BUY_ETH_AMOUNT);

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(poolId);
        assertLt(sqrtAfter, sqrtBefore, "sqrtPrice decreases on zeroForOne");
        assertLt(tickAfter, tickBefore, "tick decreases on zeroForOne");

        console2.log("buy ethIn", BUY_ETH_AMOUNT);
        console2.log("buy scoopOut", scoopReceived);
        console2.log("tickBefore", tickBefore);
        console2.log("tickAfter", tickAfter);
    }

    function test_sellScoopForEth() public {
        uint256 scoopBought = _buyScoop(BUY_ETH_AMOUNT);
        // Sell half so we keep a remainder and still prove the reverse swap.
        uint256 scoopToSell = scoopBought / 2;
        assertGt(scoopToSell, 0);

        _approveTraderScoopForRouter();

        uint256 ethBefore = trader.balance;
        uint256 scoopBefore = scoopToken.balanceOf(trader);
        (uint160 sqrtBefore, int24 tickBefore,,) = manager.getSlot0(poolId);

        uint256 ethReceived = _sellScoop(scoopToSell);

        assertGt(ethReceived, 0, "received ETH");
        assertEq(scoopToken.balanceOf(trader), scoopBefore - scoopToSell);
        assertEq(trader.balance, ethBefore + ethReceived);

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(poolId);
        assertGt(sqrtAfter, sqrtBefore, "sqrtPrice increases on oneForZero");
        // Small sells may stay inside the same tick; require non-decreasing tick.
        assertGe(tickAfter, tickBefore, "tick does not move down on oneForZero");

        console2.log("sell scoopIn", scoopToSell);
        console2.log("sell ethOut", ethReceived);
        console2.log("sell tickBefore", tickBefore);
        console2.log("sell tickAfter", tickAfter);
    }

    function test_buyThenSellRoundTripAndFeeImpact() public {
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, LP_FEE, "1% LP fee configured on pool");

        uint256 ethStart = trader.balance;
        uint256 scoopBought = _buyScoop(BUY_ETH_AMOUNT);

        _approveTraderScoopForRouter();
        uint256 ethFromSell = _sellScoop(scoopBought);

        // Round-trip cannot recover full ETH: 1% LP fee is charged on each swap leg,
        // and price impact compounds the shortfall.
        assertLt(ethFromSell, BUY_ETH_AMOUNT, "fees + impact reduce round-trip ETH");
        assertEq(trader.balance, ethStart - BUY_ETH_AMOUNT + ethFromSell);
        assertEq(scoopToken.balanceOf(trader), 0);

        // Position liquidity remains on the ticks after swaps.
        (uint128 grossLower,) = manager.getTickLiquidity(poolId, TICK_LOWER);
        assertGt(grossLower, 0, "LP liquidity still present");

        console2.log("roundTrip ethSpent", BUY_ETH_AMOUNT);
        console2.log("roundTrip scoopBought", scoopBought);
        console2.log("roundTrip ethReturned", ethFromSell);
        console2.log("roundTrip ethLostToFeesImpact", BUY_ETH_AMOUNT - ethFromSell);
    }

    function test_poolStateChangesAcrossBuyAndSell() public {
        (uint160 sqrt0, int24 tick0,,) = manager.getSlot0(poolId);

        _buyScoop(BUY_ETH_AMOUNT);
        (uint160 sqrt1, int24 tick1,,) = manager.getSlot0(poolId);
        assertLt(sqrt1, sqrt0);
        assertLt(tick1, tick0);

        _approveTraderScoopForRouter();
        uint256 scoopBal = scoopToken.balanceOf(trader);
        _sellScoop(scoopBal / 2);

        (uint160 sqrt2,,,) = manager.getSlot0(poolId);
        // After selling half back, sqrtPrice moves back toward the open (may share a tick).
        assertGt(sqrt2, sqrt1);
        assertLt(sqrt2, sqrt0);
    }

    // ──────────────────────────────────────────────
    // Swap helpers (Universal Router V4_SWAP)
    // ──────────────────────────────────────────────

    function _buyScoop(uint256 ethAmount) internal returns (uint256 scoopReceived) {
        uint256 scoopBefore = scoopToken.balanceOf(trader);

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle({
            zeroForOne: true,
            amountIn: uint128(ethAmount),
            amountOutMinimum: 1, // require non-zero Scoop out
            settleCurrency: key.currency0,
            takeCurrency: key.currency1
        });

        vm.prank(trader);
        router.execute{value: ethAmount}(commands, inputs, block.timestamp + 60);

        scoopReceived = scoopToken.balanceOf(trader) - scoopBefore;
    }

    function _sellScoop(uint256 scoopAmount) internal returns (uint256 ethReceived) {
        uint256 ethBefore = trader.balance;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle({
            zeroForOne: false,
            amountIn: uint128(scoopAmount),
            amountOutMinimum: 1, // require non-zero ETH out
            settleCurrency: key.currency1,
            takeCurrency: key.currency0
        });

        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp + 60);

        ethReceived = trader.balance - ethBefore;
    }

    function _encodeV4ExactInSingle(
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        Currency settleCurrency,
        Currency takeCurrency
    ) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(settleCurrency, uint256(amountIn));
        params[2] = abi.encode(takeCurrency, uint256(amountOutMinimum));

        return abi.encode(actions, params);
    }

    function _approveTraderScoopForRouter() internal {
        vm.startPrank(trader);
        scoopToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(scoopToken), address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Liquidity bootstrap (same as Milestone 2D)
    // ──────────────────────────────────────────────

    function _mintOneSidedLiquidity() internal {
        scoopToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(scoopToken), address(posm), type(uint160).max, type(uint48).max);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, LIQUIDITY_AMOUNT);

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            TICK_LOWER,
            TICK_UPPER,
            uint256(liquidity),
            uint128(0),
            uint128(LIQUIDITY_AMOUNT),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }
}
