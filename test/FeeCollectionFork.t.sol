// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
 * @notice Accrue Uniswap v4 LP fees via real swaps, then collect them through the canonical
 *         PositionManager on a Robinhood Chain mainnet fork.
 *
 * Fee collection (official v4-periphery pattern):
 *   Actions.DECREASE_LIQUIDITY with liquidity = 0  → credits accrued fees
 *   Actions.CLOSE_CURRENCY for currency0 + currency1 → settles/takes deltas to msg.sender
 *
 * See PositionManager._decrease: "Calling decrease with 0 liquidity will credit the caller
 * with any underlying fees of the position."
 */
contract FeeCollectionForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    uint8 constant CMD_V4_SWAP = 0x10;

    uint24 constant LP_FEE = 10_000;
    int24 constant TICK_SPACING = 200;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    int24 constant TICK_LOWER = -400;
    int24 constant TICK_UPPER = -200;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LIQUIDITY_AMOUNT = 100_000_000 ether;
    uint256 constant BUY_ETH_AMOUNT = 0.02 ether;

    IPoolManager manager;
    IPositionManager posm;
    IUniversalRouter router;
    IAllowanceTransfer permit2;
    ScoopTestToken scoopToken;
    PoolKey key;
    PoolId poolId;
    address trader;
    uint256 tokenId;
    uint128 mintedLiquidity;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER_ADDR);
        posm = IPositionManager(POSITION_MANAGER_ADDR);
        router = IUniversalRouter(UNIVERSAL_ROUTER_ADDR);
        permit2 = IHasPermit2(POSITION_MANAGER_ADDR).permit2();

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
        tokenId = _mintOneSidedLiquidity();
        mintedLiquidity = posm.getPositionLiquidity(tokenId);

        trader = makeAddr("trader");
        vm.deal(trader, 10 ether);

        // Seed ETH so fee collection of native currency is observable against a non-zero baseline.
        vm.deal(address(this), 1 ether);
    }

    function test_swapsAccrueFeesAndCollectionSucceeds() public {
        _generateFees();

        uint256 ethBefore = address(this).balance;
        uint256 scoopBefore = scoopToken.balanceOf(address(this));
        uint128 liqBefore = posm.getPositionLiquidity(tokenId);

        _collectFees(tokenId);

        uint256 ethFees = address(this).balance - ethBefore;
        uint256 scoopFees = scoopToken.balanceOf(address(this)) - scoopBefore;

        console2.log("ETH fees collected", ethFees);
        console2.log("Scoop fees collected", scoopFees);

        // At least one asset must be collected; with buy+sell activity both usually are.
        assertTrue(ethFees > 0 || scoopFees > 0, "collected fees > 0");
        assertGt(ethFees + scoopFees, 0);
        assertEq(posm.getPositionLiquidity(tokenId), liqBefore, "liquidity unchanged by collect");
    }

    function test_feeCollectionLeavesPositionActive() public {
        _generateFees();
        _collectFees(tokenId);

        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(this));
        assertGt(posm.getPositionLiquidity(tokenId), 0);
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);

        (PoolKey memory storedKey,) = posm.getPoolAndPositionInfo(tokenId);
        assertEq(Currency.unwrap(storedKey.currency1), address(scoopToken));
    }

    function test_collectsEthAndOrScoopFeesSeparately() public {
        _generateFees();

        uint256 ethBefore = address(this).balance;
        uint256 scoopBefore = scoopToken.balanceOf(address(this));

        _collectFees(tokenId);

        uint256 ethFees = address(this).balance - ethBefore;
        uint256 scoopFees = scoopToken.balanceOf(address(this)) - scoopBefore;

        // Buy (ETH→Scoop) charges the 1% fee on ETH input while the position is in range.
        // Sell (Scoop→ETH) charges the 1% fee on Scoop input. Both legs therefore contribute.
        assertGt(ethFees, 0, "ETH LP fees from zeroForOne swaps");
        assertGt(scoopFees, 0, "Scoop LP fees from oneForZero swaps");

        console2.log("ETH fees", ethFees);
        console2.log("Scoop fees", scoopFees);
    }

    function test_poolUsableAfterFeeCollection() public {
        _generateFees();
        _collectFees(tokenId);

        uint256 scoopBefore = scoopToken.balanceOf(trader);
        uint256 bought = _buyScoop(0.01 ether);
        assertGt(bought, 0);
        assertEq(scoopToken.balanceOf(trader), scoopBefore + bought);

        // Tick liquidity from the LP position remains present.
        (uint128 grossLower,) = manager.getTickLiquidity(poolId, TICK_LOWER);
        assertGt(grossLower, 0);
    }

    function test_secondCollectionAfterMoreSwapsAlsoSucceeds() public {
        _generateFees();
        _collectFees(tokenId);

        // Accrue a second round of fees and collect again.
        _generateFees();

        uint256 ethBefore = address(this).balance;
        uint256 scoopBefore = scoopToken.balanceOf(address(this));
        _collectFees(tokenId);

        assertTrue(
            address(this).balance > ethBefore || scoopToken.balanceOf(address(this)) > scoopBefore,
            "second collection yields fees"
        );
        assertGt(posm.getPositionLiquidity(tokenId), 0);
    }

    // ──────────────────────────────────────────────
    // Fee generation + collection
    // ──────────────────────────────────────────────

    function _generateFees() internal {
        // Two buy/sell cycles against in-range liquidity to accrue both token0 and token1 fees.
        uint256 scoop1 = _buyScoop(BUY_ETH_AMOUNT);
        _approveTraderScoopForRouter();
        _sellScoop(scoop1 / 2);

        uint256 scoop2 = _buyScoop(BUY_ETH_AMOUNT);
        _sellScoop(scoop2 / 2);
    }

    /// @dev Official collect: decrease liquidity by 0, then close both currency deltas.
    function _collectFees(uint256 _tokenId) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(_tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);

        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    // ──────────────────────────────────────────────
    // Swap helpers
    // ──────────────────────────────────────────────

    function _buyScoop(uint256 ethAmount) internal returns (uint256 scoopReceived) {
        uint256 scoopBefore = scoopToken.balanceOf(trader);

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle({
            zeroForOne: true,
            amountIn: uint128(ethAmount),
            amountOutMinimum: 1,
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
            amountOutMinimum: 1,
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

    function _mintOneSidedLiquidity() internal returns (uint256 id) {
        scoopToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(scoopToken), address(posm), type(uint160).max, type(uint48).max);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, LIQUIDITY_AMOUNT);

        id = posm.nextTokenId();

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

    receive() external payable {}
}
