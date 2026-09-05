// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";

/**
 * @title ParEagleLiquidityForensicsFork
 * @notice Milestone 4I.1 — read-only forensics of PAR-launched EAGLE on Robinhood Chain.
 * @dev No production state changes. Re-proves values claimed as PROVEN from launch tx
 *      0x617a719bc91dbbe47510dedf60fcd5c48c1fedf8d446cbecb61a9538f455f911 @ block 54630613.
 */
contract ParEagleLiquidityForensicsForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    // ─── Observed launch constants (from RPC receipt decoding) ─────────────
    address constant EAGLE = 0xB36CD262e108750F2EeCd8C859C074eA528Af4Ee;
    address constant PAR_TOKEN = 0x507B6F349a80114097A67B8b4677367acC15b220;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    /// @dev Transaction `to` — PAR launch entrypoint that executed create/init/mint/buy.
    address constant PAR_LAUNCH_ROUTER = 0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120;
    /// @dev Launch tx `from`.
    address constant LAUNCHER_EOA = 0x92A7Ad9238565921dada10F1D24F6EC81cc7133e;
    /// @dev First minter of the full 1B EAGLE supply in the launch tx.
    address constant SUPPLY_CUSTODY = 0xDaB26Bb66F29863F2d68CeD54F65cC614c4e65dC;
    /// @dev ERC-721 recipient of PositionManager tokenId 1829354.
    address constant LP_NFT_RECIPIENT = 0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231;
    /// @dev `owner()` of LP_NFT_RECIPIENT (EOA; code size 0).
    address constant LP_NFT_RECIPIENT_OWNER = 0x6053FC7a871AF434F5F26701B206469bAcB03966;
    /// @dev Returned by SUPPLY_CUSTODY.factory().
    address constant PAR_RELATED_FACTORY = 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F;

    uint256 constant LAUNCH_BLOCK = 54_630_613;
    bytes32 constant LAUNCH_TX = 0x617a719bc91dbbe47510dedf60fcd5c48c1fedf8d446cbecb61a9538f455f911;
    bytes32 constant EAGLE_POOL_ID = 0xca20630459c885c186c03251f15fea95d3eba6e7645b95a5dc13b479d75feb4a;

    uint24 constant PAR_FEE = 15_000;
    int24 constant PAR_TICK_SPACING = 10;
    uint160 constant OPENING_SQRT_PRICE_X96 = 2_558_453_067_953_332_899_258_195_263_169;
    int24 constant OPENING_TICK = 69_500;
    int24 constant TICK_LOWER = -887_270;
    int24 constant TICK_UPPER = 69_500;
    uint256 constant LP_TOKEN_ID = 1_829_354;
    uint128 constant INITIAL_LIQUIDITY = 30_967_213_550_508_438_589_083_991;
    uint256 constant LAUNCH_SUPPLY = 1_000_000_000 ether; // 1e27

    IPoolManager manager;
    IPositionManager posm;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        // Fork at/after launch so historical creation + live position state are both readable.
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER);
        posm = IPositionManager(POSITION_MANAGER);

        assertGt(EAGLE.code.length, 0, "EAGLE missing");
        assertGt(PAR_TOKEN.code.length, 0, "PAR token missing");
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager missing");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager missing");
        assertGt(PAR_LAUNCH_ROUTER.code.length, 0, "PAR launch router missing");
        assertGt(SUPPLY_CUSTODY.code.length, 0, "supply custody missing");
        assertGt(LP_NFT_RECIPIENT.code.length, 0, "LP NFT recipient missing");
        assertEq(LP_NFT_RECIPIENT_OWNER.code.length, 0, "LP recipient owner should be EOA");
    }

    // ─── Phase 1 / identity ────────────────────────────────────────────────

    function test_eagleIdentity() public view {
        IERC20Metadata eagle = IERC20Metadata(EAGLE);
        assertEq(eagle.name(), "eagle");
        assertEq(eagle.symbol(), "eagle");
        assertEq(eagle.decimals(), 18);
        // Supply moves with trading/burns; only assert it is below launch mint.
        assertLe(eagle.totalSupply(), LAUNCH_SUPPLY);
        assertGt(eagle.totalSupply(), 0);
    }

    function test_creationBlock_hasCodeAfterLaunch_notBefore() public {
        // Independent of eth_getCode binary-search clue: prove bytecode appears at LAUNCH_BLOCK.
        uint256 tip = block.number;
        vm.rollFork(LAUNCH_BLOCK - 1);
        assertEq(EAGLE.code.length, 0, "EAGLE must not exist before launch block");
        vm.rollFork(LAUNCH_BLOCK);
        assertGt(EAGLE.code.length, 0, "EAGLE must exist at launch block");
        vm.rollFork(tip);
    }

    function test_launchTxConstantsDocumented() public pure {
        // Anchors for reproducibility / report cross-check (not RPC-dependent).
        assertEq(LAUNCH_BLOCK, 54_630_613);
        assertEq(LAUNCH_TX, bytes32(0x617a719bc91dbbe47510dedf60fcd5c48c1fedf8d446cbecb61a9538f455f911));
        assertEq(LP_TOKEN_ID, 1_829_354);
        assertEq(uint256(uint160(LAUNCHER_EOA)), uint256(uint160(0x92A7Ad9238565921dada10F1D24F6EC81cc7133e)));
        assertEq(uint256(uint160(PAR_LAUNCH_ROUTER)), uint256(uint160(0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120)));
        assertEq(uint256(uint160(PAR_RELATED_FACTORY)), uint256(uint160(0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F)));
    }

    // ─── Phase 3–5: pool + position geometry ───────────────────────────────

    function test_poolKey_matchesInitializeEvidence() public view {
        PoolKey memory key = _eaglePoolKey();
        assertEq(PoolId.unwrap(key.toId()), EAGLE_POOL_ID, "PoolId mismatch");
        assertEq(Currency.unwrap(key.currency0), PAR_TOKEN, "currency0 is PAR");
        assertEq(Currency.unwrap(key.currency1), EAGLE, "currency1 is EAGLE");
        assertEq(key.fee, PAR_FEE);
        assertEq(key.tickSpacing, PAR_TICK_SPACING);
        assertEq(address(key.hooks), address(0));

        IERC20Metadata par = IERC20Metadata(PAR_TOKEN);
        assertEq(par.name(), "par");
        assertEq(par.symbol(), "par");
        assertEq(par.decimals(), 18);
    }

    function test_openingSqrtPrice_matchesTickMath() public view {
        assertEq(TickMath.getSqrtPriceAtTick(OPENING_TICK), OPENING_SQRT_PRICE_X96);
        assertEq(TickMath.getTickAtSqrtPrice(OPENING_SQRT_PRICE_X96), OPENING_TICK);
    }

    function test_initialPosition_stillLiveWithProvenGeometry() public view {
        uint128 liq = posm.getPositionLiquidity(LP_TOKEN_ID);
        assertEq(liq, INITIAL_LIQUIDITY, "liquidity must still equal launch delta");

        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(LP_TOKEN_ID);
        assertEq(PoolId.unwrap(key.toId()), EAGLE_POOL_ID);
        assertEq(info.tickLower(), TICK_LOWER);
        assertEq(info.tickUpper(), TICK_UPPER);
        assertEq(TICK_UPPER - TICK_LOWER, 956_770);

        // One-sided geometry: opening tick equals tickUpper so at init
        // LiquidityAmounts uses amount1-only branch (sqrtPrice >= sqrtUpper).
        assertEq(OPENING_TICK, TICK_UPPER);
        assertEq(TICK_LOWER, TickMath.minUsableTick(PAR_TICK_SPACING));
    }

    function test_lpNftCustody_recipientStillOwns() public view {
        assertEq(IERC721(POSITION_MANAGER).ownerOf(LP_TOKEN_ID), LP_NFT_RECIPIENT);
        assertEq(_ownerOf(LP_NFT_RECIPIENT), LP_NFT_RECIPIENT_OWNER);
    }

    function test_currentTick_stillInsideInitialRange() public view {
        (, int24 tick,,) = manager.getSlot0(PoolId.wrap(EAGLE_POOL_ID));
        // Buy direction (PAR→EAGLE / zeroForOne) decreases tick from OPENING_TICK toward TICK_LOWER.
        assertLt(tick, OPENING_TICK, "price should have moved down from opening after buys");
        assertGe(tick, TICK_LOWER, "initial lower bound not crossed");
        assertLt(tick, TICK_UPPER, "tick should be below tickUpper so position can be in-range");
    }

    function test_rangeWidth_ordersOfMagnitudeWiderThanScoop200() public pure {
        int24 parWidth = TICK_UPPER - TICK_LOWER;
        int24 scoopWidth = 200;
        assertEq(parWidth, 956_770);
        assertGt(parWidth, scoopWidth * 4_000);
    }

    function test_supplyCustody_reportsRelatedFactory() public view {
        (bool ok, bytes memory data) = SUPPLY_CUSTODY.staticcall(abi.encodeWithSignature("factory()"));
        assertTrue(ok, "factory() readable");
        assertEq(abi.decode(data, (address)), PAR_RELATED_FACTORY);
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    function _eaglePoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(PAR_TOKEN),
            currency1: Currency.wrap(EAGLE),
            fee: PAR_FEE,
            tickSpacing: PAR_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _ownerOf(address target) internal view returns (address o) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && data.length >= 32, "owner() failed");
        o = abi.decode(data, (address));
    }
}
