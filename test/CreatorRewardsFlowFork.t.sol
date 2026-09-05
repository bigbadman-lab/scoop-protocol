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
import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";

interface IHasPermit2 {
    function permit2() external view returns (IAllowanceTransfer);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Robinhood fork E2E: LP fees → locker → distributor → CreatorRewards → claim.
 */
contract CreatorRewardsFlowForkTest is Test {
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

    uint16 constant CREATOR_REWARDS_BPS = 7000;
    uint16 constant DEPLOYER_BPS = 400;
    uint16 constant BUYBACK_BPS = 2000;
    uint16 constant OPERATIONS_BPS = 600;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LIQUIDITY_AMOUNT = 100_000_000 ether;
    uint256 constant BUY_ETH_AMOUNT = 0.02 ether;

    IPoolManager manager;
    IPositionManager posm;
    IUniversalRouter router;
    IAllowanceTransfer permit2;
    ScoopTestToken scoopToken;
    ScoopFeeDistributor distributor;
    ScoopLiquidityLocker locker;
    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    PoolKey key;

    address authority;
    uint256 authorityKey;
    address registrar;
    address walletCreator;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address trader;
    address relayer;
    bytes32 walletCreatorId;
    uint256 tokenId;
    uint128 mintedLiquidity;

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        manager = IPoolManager(POOL_MANAGER_ADDR);
        posm = IPositionManager(POSITION_MANAGER_ADDR);
        router = IUniversalRouter(UNIVERSAL_ROUTER_ADDR);
        permit2 = IHasPermit2(POSITION_MANAGER_ADDR).permit2();

        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        registrar = makeAddr("sourceRegistrar");
        walletCreator = makeAddr("walletCreator");
        deployerRecipient = makeAddr("scoopDeployerReward");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        trader = makeAddr("trader");
        relayer = makeAddr("relayer");

        registry = new ScoopCreatorRegistry(authority);
        rewards = new ScoopCreatorRewards(address(registry), registrar);
        walletCreatorId = registry.walletCreatorId(walletCreator);

        distributor = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        locker = new ScoopLiquidityLocker(POSITION_MANAGER_ADDR, address(distributor));

        vm.prank(registrar);
        rewards.registerSource(address(distributor), walletCreatorId);

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

        manager.initialize(key, SQRT_PRICE_1_1);
        tokenId = _mintOneSidedLiquidity();
        mintedLiquidity = posm.getPositionLiquidity(tokenId);

        IERC721(address(posm)).safeTransferFrom(address(this), address(locker), tokenId);
        vm.deal(trader, 10 ether);
    }

    function test_endToEndFeeCollectDistributeClaim() public {
        _generateFees();

        uint256 distributorEthBefore = address(distributor).balance;
        uint256 distributorScoopBefore = scoopToken.balanceOf(address(distributor));
        uint128 liqBefore = posm.getPositionLiquidity(tokenId);

        locker.collectFees(tokenId);

        uint256 ethFees = address(distributor).balance - distributorEthBefore;
        uint256 scoopFees = scoopToken.balanceOf(address(distributor)) - distributorScoopBefore;

        console2.log("fork ETH fees collected", ethFees);
        console2.log("fork Scoop fees collected", scoopFees);

        assertGt(ethFees, 0);
        assertGt(scoopFees, 0);
        assertEq(walletCreator.balance, 0);
        assertEq(scoopToken.balanceOf(walletCreator), 0);
        assertEq(address(locker).balance, 0);
        assertEq(scoopToken.balanceOf(address(locker)), 0);

        uint256 expectedCreatorEth = (ethFees * CREATOR_REWARDS_BPS) / 10_000;
        uint256 expectedDeployerEth = (ethFees * DEPLOYER_BPS) / 10_000;
        uint256 expectedBuybackEth = (ethFees * BUYBACK_BPS) / 10_000;
        uint256 expectedOpsEth = ethFees - expectedCreatorEth - expectedDeployerEth - expectedBuybackEth;

        uint256 expectedCreatorScoop = (scoopFees * CREATOR_REWARDS_BPS) / 10_000;
        uint256 expectedDeployerScoop = (scoopFees * DEPLOYER_BPS) / 10_000;
        uint256 expectedBuybackScoop = (scoopFees * BUYBACK_BPS) / 10_000;
        uint256 expectedOpsScoop = scoopFees - expectedCreatorScoop - expectedDeployerScoop - expectedBuybackScoop;

        address randomCaller = makeAddr("randomDistributeCaller");
        vm.prank(randomCaller);
        distributor.distributeETH();
        vm.prank(randomCaller);
        distributor.distributeToken(address(scoopToken));

        assertEq(rewards.claimableETH(walletCreatorId), expectedCreatorEth);
        assertEq(rewards.claimableToken(walletCreatorId, address(scoopToken)), expectedCreatorScoop);
        assertEq(address(rewards).balance, expectedCreatorEth);
        assertEq(scoopToken.balanceOf(address(rewards)), expectedCreatorScoop);

        assertEq(deployerRecipient.balance, expectedDeployerEth);
        assertEq(buybackVault.balance, expectedBuybackEth);
        assertEq(operations.balance, expectedOpsEth);
        assertEq(scoopToken.balanceOf(deployerRecipient), expectedDeployerScoop);
        assertEq(scoopToken.balanceOf(buybackVault), expectedBuybackScoop);
        assertEq(scoopToken.balanceOf(operations), expectedOpsScoop);

        assertEq(address(distributor).balance, 0);
        assertEq(scoopToken.balanceOf(address(distributor)), 0);
        assertEq(walletCreator.balance, 0);
        assertEq(scoopToken.balanceOf(walletCreator), 0);

        console2.log("credited creator ETH", expectedCreatorEth);
        console2.log("deployer ETH", expectedDeployerEth);
        console2.log("buyback ETH", expectedBuybackEth);
        console2.log("operations ETH", expectedOpsEth);

        vm.prank(relayer);
        rewards.claimETH(walletCreatorId, walletCreator);
        vm.prank(relayer);
        rewards.claimToken(walletCreatorId, address(scoopToken), walletCreator);

        assertEq(walletCreator.balance, expectedCreatorEth);
        assertEq(scoopToken.balanceOf(walletCreator), expectedCreatorScoop);
        assertEq(relayer.balance, 0);
        assertEq(scoopToken.balanceOf(relayer), 0);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
        assertEq(rewards.claimableToken(walletCreatorId, address(scoopToken)), 0);

        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertEq(posm.getPositionLiquidity(tokenId), liqBefore);
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);

        uint256 bought = _buyScoop(0.01 ether);
        assertGt(bought, 0);
    }

    function test_xLifecycleOnLocalStylePathWithinForkSetup() public {
        // Use a second distributor/source registered to an X creatorId with synthetic fees.
        uint256 xUser = 777001;
        bytes32 xId = registry.xCreatorId(xUser);

        ScoopFeeDistributor xDistributor = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        vm.prank(registrar);
        rewards.registerSource(address(xDistributor), xId);

        vm.deal(address(xDistributor), 1 ether);
        xDistributor.distributeETH();

        assertEq(rewards.claimableETH(xId), 0.7 ether);
        assertFalse(registry.isXClaimed(xUser));

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(xId, walletCreator);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(xUser, walletCreator, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, digest);
        registry.claimXIdentity(xUser, walletCreator, deadline, abi.encodePacked(r, s, v));

        uint256 beforeBal = walletCreator.balance;
        rewards.claimETH(xId, address(0));
        assertEq(walletCreator.balance, beforeBal + 0.7 ether);
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
