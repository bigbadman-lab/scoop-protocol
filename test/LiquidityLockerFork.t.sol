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
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";

interface IHasPermit2 {
    function permit2() external view returns (IAllowanceTransfer);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Prove permanently locked Uniswap v4 LP via ScoopLiquidityLocker on Robinhood fork.
 *         NFT is transferred to the locker; fees remain collectible to an immutable feeDistributor.
 */
contract LiquidityLockerForkTest is Test {
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
    ScoopLiquidityLocker locker;
    PoolKey key;
    PoolId poolId;
    address trader;
    address feeDistributor;
    address lpCreator;
    uint256 tokenId;
    uint128 mintedLiquidity;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER_ADDR);
        posm = IPositionManager(POSITION_MANAGER_ADDR);
        router = IUniversalRouter(UNIVERSAL_ROUTER_ADDR);
        permit2 = IHasPermit2(POSITION_MANAGER_ADDR).permit2();

        // Stand-in destination for fee TAKE_PAIR (full distributor integration covered elsewhere).
        feeDistributor = makeAddr("feeDistributor");
        trader = makeAddr("trader");
        lpCreator = address(this);

        locker = new ScoopLiquidityLocker(POSITION_MANAGER_ADDR, feeDistributor);

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

        // Permanently lock the LP NFT in the locker.
        IERC721(address(posm)).safeTransferFrom(address(this), address(locker), tokenId);

        vm.deal(trader, 10 ether);
    }

    function test_lockerReceivesAndOwnsLpNft() public view {
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertEq(IERC721(address(posm)).balanceOf(address(locker)), 1);
        assertEq(IERC721(address(posm)).balanceOf(lpCreator), 0);
    }

    function test_immutablesArePinned() public view {
        assertEq(address(locker.positionManager()), POSITION_MANAGER_ADDR);
        assertEq(locker.feeDistributor(), feeDistributor);
    }

    function test_noEscapeHatchSelectors() public {
        // Probe for transfer / rescue / principal-remove surfaces — all must be absent.
        bytes4[] memory probes = new bytes4[](11);
        probes[0] = bytes4(keccak256("transferFrom(address,address,uint256)"));
        probes[1] = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
        probes[2] = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));
        probes[3] = bytes4(keccak256("rescueNFT(uint256,address)"));
        probes[4] = bytes4(keccak256("withdrawNFT(uint256)"));
        probes[5] = bytes4(keccak256("emergencyWithdraw(uint256)"));
        probes[6] = bytes4(keccak256("decreaseLiquidity(uint256,uint256)"));
        probes[7] = bytes4(keccak256("burn(uint256)"));
        probes[8] = bytes4(keccak256("setFeeDistributor(address)"));
        probes[9] = bytes4(keccak256("setFeeRecipient(address)"));
        probes[10] = bytes4(keccak256("execute(address,uint256,bytes)"));

        for (uint256 i; i < probes.length; ++i) {
            (bool ok,) = address(locker).call(abi.encodePacked(probes[i]));
            assertFalse(ok, "escape-hatch selector must not succeed");
        }
    }

    function test_swapsSucceedWhileNftLocked() public {
        uint256 scoopBought = _buyScoop(BUY_ETH_AMOUNT);
        assertGt(scoopBought, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
    }

    function test_feesAccrueAndCollectToFeeDistributor() public {
        _generateFees();

        uint256 ethBefore = feeDistributor.balance;
        uint256 scoopBefore = scoopToken.balanceOf(feeDistributor);
        uint128 liqBefore = posm.getPositionLiquidity(tokenId);

        // Anyone can trigger collection; fees always go to immutable feeDistributor.
        vm.prank(makeAddr("randomCaller"));
        locker.collectFees(tokenId);

        uint256 ethFees = feeDistributor.balance - ethBefore;
        uint256 scoopFees = scoopToken.balanceOf(feeDistributor) - scoopBefore;

        console2.log("locked ETH fees", ethFees);
        console2.log("locked Scoop fees", scoopFees);

        assertTrue(ethFees > 0 || scoopFees > 0, "feeDistributor received fees");
        assertGt(ethFees, 0, "ETH fees");
        assertGt(scoopFees, 0, "Scoop fees");
        assertEq(posm.getPositionLiquidity(tokenId), liqBefore);
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
    }

    function test_cannotRedirectFeesOrChangeConfig() public {
        _generateFees();

        address attacker = makeAddr("attacker");
        uint256 attackerEthBefore = attacker.balance;
        uint256 attackerScoopBefore = scoopToken.balanceOf(attacker);
        uint256 distributorEthBefore = feeDistributor.balance;

        vm.prank(attacker);
        locker.collectFees(tokenId);

        assertEq(attacker.balance, attackerEthBefore, "attacker got no ETH");
        assertEq(scoopToken.balanceOf(attacker), attackerScoopBefore, "attacker got no Scoop");
        assertGt(feeDistributor.balance, distributorEthBefore, "fees still to feeDistributor");

        // No setter exists — feeDistributor / positionManager are immutable.
        (bool setFeeOk,) = address(locker).call(abi.encodeWithSignature("setFeeDistributor(address)", attacker));
        (bool setPosmOk,) = address(locker).call(abi.encodeWithSignature("setPositionManager(address)", attacker));
        assertFalse(setFeeOk);
        assertFalse(setPosmOk);
        assertEq(locker.feeDistributor(), feeDistributor);
        assertEq(address(locker.positionManager()), POSITION_MANAGER_ADDR);
    }

    function test_collectFeesRevertsForUnownedToken() public {
        // Mint a second position that remains owned by the test contract, not the locker.
        uint256 otherId = _mintOneSidedLiquidity();
        assertEq(IERC721(address(posm)).ownerOf(otherId), address(this));

        vm.expectRevert(ScoopLiquidityLocker.NotTokenOwner.selector);
        locker.collectFees(otherId);
    }

    function test_swapSucceedsAfterLockedFeeCollection() public {
        _generateFees();
        locker.collectFees(tokenId);

        uint256 bought = _buyScoop(0.01 ether);
        assertGt(bought, 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ScoopLiquidityLocker.ZeroPositionManager.selector);
        new ScoopLiquidityLocker(address(0), feeDistributor);

        vm.expectRevert(ScoopLiquidityLocker.ZeroFeeDistributor.selector);
        new ScoopLiquidityLocker(POSITION_MANAGER_ADDR, address(0));
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _generateFees() internal {
        uint256 scoop1 = _buyScoop(BUY_ETH_AMOUNT);
        _approveTraderScoopForRouter();
        _sellScoop(scoop1 / 2);

        uint256 scoop2 = _buyScoop(BUY_ETH_AMOUNT);
        _sellScoop(scoop2 / 2);
    }

    function _buyScoop(uint256 ethAmount) internal returns (uint256 scoopReceived) {
        uint256 scoopBefore = scoopToken.balanceOf(trader);

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(true, uint128(ethAmount), 1, key.currency0, key.currency1);

        vm.prank(trader);
        router.execute{value: ethAmount}(commands, inputs, block.timestamp + 60);

        scoopReceived = scoopToken.balanceOf(trader) - scoopBefore;
    }

    function _sellScoop(uint256 scoopAmount) internal returns (uint256 ethReceived) {
        uint256 ethBefore = trader.balance;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(false, uint128(scoopAmount), 1, key.currency1, key.currency0);

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
}
