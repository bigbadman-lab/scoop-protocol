// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";

import {ScoopTestToken} from "../src/ScoopTestToken.sol";

/// @dev Minimal surface to read PositionManager's immutable Permit2.
interface IHasPermit2 {
    function permit2() external view returns (IAllowanceTransfer);
}

/**
 * @notice Mint one-sided (currency1 / ScoopTestToken-only) liquidity via the canonical
 *         Robinhood Chain PositionManager on a mainnet fork.
 *
 * Tick range choice (tickSpacing = 200, current tick = 0):
 *   tickLower = -400, tickUpper = -200
 *
 * Uniswap v4 LiquidityAmounts (same as v3): when current sqrtPrice >= sqrt(tickUpper),
 * the position is composed entirely of token1. With current tick = 0 and tickUpper = -200,
 * price is strictly above the range, so amount0 (native ETH) required is 0 and only
 * ScoopTestToken (currency1) is deposited.
 */
contract OneSidedLiquidityForkTest is Test {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    uint24 constant LP_FEE = 10_000;
    int24 constant TICK_SPACING = 200;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Entirely below current tick 0 → token1-only. Multiples of tickSpacing 200.
    int24 constant TICK_LOWER = -400;
    int24 constant TICK_UPPER = -200;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant MINT_AMOUNT = 100_000_000 ether;

    IPoolManager manager;
    IPositionManager posm;
    IAllowanceTransfer permit2;
    ScoopTestToken scoopToken;
    PoolKey key;
    PoolId poolId;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER_ADDR);
        posm = IPositionManager(POSITION_MANAGER_ADDR);
        permit2 = IHasPermit2(POSITION_MANAGER_ADDR).permit2();

        assertGt(POOL_MANAGER_ADDR.code.length, 0, "PoolManager missing");
        assertGt(POSITION_MANAGER_ADDR.code.length, 0, "PositionManager missing");
        assertGt(address(permit2).code.length, 0, "Permit2 missing");

        // Test contract owns the full supply.
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

        // ETH balance available to prove we do not spend it.
        vm.deal(address(this), 100 ether);

        _configureApprovals();
    }

    function test_poolInitializesSuccessfully() public view {
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(tick, 0);
        assertEq(lpFee, LP_FEE);
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(scoopToken));
    }

    function test_testContractBeginsWithExpectedScoopBalance() public view {
        assertEq(scoopToken.balanceOf(address(this)), SUPPLY);
        assertEq(scoopToken.totalSupply(), SUPPLY);
    }

    function test_permit2AndPositionManagerApprovalsConfigured() public view {
        assertEq(scoopToken.allowance(address(this), address(permit2)), type(uint256).max);

        (uint160 amount, uint48 expiration, uint48 nonce) =
            permit2.allowance(address(this), address(scoopToken), address(posm));
        assertEq(amount, type(uint160).max);
        assertEq(expiration, type(uint48).max);
        // nonce starts at 0 for a fresh allowance
        assertEq(nonce, 0);
    }

    function test_liquidityMintSucceedsViaCanonicalPositionManager() public {
        uint256 tokenId = _mintOneSidedPosition();
        assertGt(tokenId, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(this));
    }

    function test_validLpPositionTokenIdCreated() public {
        uint256 expectedId = posm.nextTokenId();
        uint256 tokenId = _mintOneSidedPosition();
        assertEq(tokenId, expectedId);
        assertEq(posm.nextTokenId(), expectedId + 1);
        assertEq(IERC721(address(posm)).balanceOf(address(this)), 1);
    }

    function test_poolTickLiquidityBecomesNonZero() public {
        // Out-of-range positions do not increase active `pools[id].liquidity`, but they
        // do write liquidityGross into the pool's tick state — that is the real pool update.
        (uint128 grossBeforeLower,) = manager.getTickLiquidity(poolId, TICK_LOWER);
        assertEq(grossBeforeLower, 0);

        uint256 tokenId = _mintOneSidedPosition();
        uint128 positionLiq = posm.getPositionLiquidity(tokenId);
        assertGt(positionLiq, 0);

        (uint128 grossLower,) = manager.getTickLiquidity(poolId, TICK_LOWER);
        (uint128 grossUpper,) = manager.getTickLiquidity(poolId, TICK_UPPER);
        assertEq(grossLower, positionLiq);
        assertEq(grossUpper, positionLiq);

        // Active in-range liquidity remains 0 for a fully out-of-range position.
        assertEq(manager.getLiquidity(poolId), 0);
    }

    function test_scoopBalanceDecreasesAndEthSpendIsZero() public {
        uint256 scoopBefore = scoopToken.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        _mintOneSidedPosition();

        uint256 scoopAfter = scoopToken.balanceOf(address(this));
        uint256 ethAfter = address(this).balance;

        assertEq(ethAfter, ethBefore, "ETH must not be spent for token1-only range");
        assertLt(scoopAfter, scoopBefore);
        // Liquidity math rounds down liquidity then may round token usage; bound the spend.
        assertGe(scoopAfter, scoopBefore - MINT_AMOUNT);
        assertGt(scoopBefore - scoopAfter, 0);
        // Should consume nearly all of MINT_AMOUNT (allow small rounding dust unused).
        assertLe(scoopBefore - scoopAfter, MINT_AMOUNT);
    }

    function test_mintedPositionHasExpectedKeyRangeAndLiquidity() public {
        uint256 tokenId = _mintOneSidedPosition();

        (PoolKey memory storedKey, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = posm.getPositionLiquidity(tokenId);

        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(storedKey.currency1), Currency.unwrap(key.currency1));
        assertEq(storedKey.fee, key.fee);
        assertEq(storedKey.tickSpacing, key.tickSpacing);
        assertEq(address(storedKey.hooks), address(key.hooks));

        assertEq(info.tickLower(), TICK_LOWER);
        assertEq(info.tickUpper(), TICK_UPPER);
        assertGt(liquidity, 0);
    }

    // ──────────────────────────────────────────────
    // Internals
    // ──────────────────────────────────────────────

    function _configureApprovals() internal {
        // 1) ERC-20 approve Permit2 as spender
        scoopToken.approve(address(permit2), type(uint256).max);
        // 2) Permit2 allowance: PositionManager may pull ScoopTestToken
        permit2.approve(address(scoopToken), address(posm), type(uint160).max, type(uint48).max);
    }

    function _mintOneSidedPosition() internal returns (uint256 tokenId) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);

        // Current price (tick 0) is above tickUpper → liquidity from amount1 only.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, MINT_AMOUNT);
        assertGt(liquidity, 0, "computed liquidity");

        tokenId = posm.nextTokenId();

        bytes memory unlockData = _encodeMintSettlePair(
            key,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            0, // amount0Max: no ETH
            uint128(MINT_AMOUNT), // amount1Max
            address(this)
        );

        posm.modifyLiquidities(unlockData, block.timestamp + 60);
    }

    /// @dev Official PositionManager action sequence: MINT_POSITION then SETTLE_PAIR.
    function _encodeMintSettlePair(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address recipient
    ) internal pure returns (bytes memory) {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        return abi.encode(actions, params);
    }

    receive() external payable {}
}
