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
 * @notice Production integration: locked Uniswap v4 LP → ScoopLiquidityLocker.collectFees
 *         → ScoopFeeDistributor → ScoopCreatorRewards (70%) + direct 4/20/6 on Robinhood fork.
 */
contract LiquidityLockerDistributorForkTest is Test {
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
    PoolId poolId;

    address walletCreator;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address trader;
    address registrar;
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

        registrar = makeAddr("sourceRegistrar");
        walletCreator = makeAddr("walletCreator");
        // Avoid makeAddr("deployer"): that address has code on Robinhood Chain and forwards ETH.
        deployerRecipient = makeAddr("scoopDeployerReward");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        trader = makeAddr("trader");

        registry = new ScoopCreatorRegistry(makeAddr("verificationAuthority"));
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
        poolId = key.toId();

        manager.initialize(key, SQRT_PRICE_1_1);
        tokenId = _mintOneSidedLiquidity();
        mintedLiquidity = posm.getPositionLiquidity(tokenId);

        IERC721(address(posm)).safeTransferFrom(address(this), address(locker), tokenId);
        vm.deal(trader, 10 ether);
    }

    function test_lockerConstructorPinsPositionManager() public view {
        assertEq(address(locker.positionManager()), POSITION_MANAGER_ADDR);
    }

    function test_lockerConstructorPinsFeeDistributor() public view {
        assertEq(locker.feeDistributor(), address(distributor));
    }

    function test_distributorStoresV1FourWayEconomics() public view {
        assertEq(distributor.creatorRewards(), address(rewards));
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.creatorRewardsBps(), 7000);
        assertEq(distributor.deployerBps(), 400);
        assertEq(distributor.buybackBps(), 2000);
        assertEq(distributor.operationsBps(), 600);
    }

    function test_zeroPositionManagerRejected() public {
        vm.expectRevert(ScoopLiquidityLocker.ZeroPositionManager.selector);
        new ScoopLiquidityLocker(address(0), address(distributor));
    }

    function test_zeroFeeDistributorRejected() public {
        vm.expectRevert(ScoopLiquidityLocker.ZeroFeeDistributor.selector);
        new ScoopLiquidityLocker(POSITION_MANAGER_ADDR, address(0));
    }

    function test_lockerReceivesLpNft() public view {
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
    }

    function test_collectFeesLandsOnDistributorNotRecipients() public {
        _generateFees();

        uint256 distributorEthBefore = address(distributor).balance;
        uint256 distributorScoopBefore = scoopToken.balanceOf(address(distributor));
        uint128 liqBefore = posm.getPositionLiquidity(tokenId);

        address randomCaller = makeAddr("randomCaller");
        uint256 callerEthBefore = randomCaller.balance;
        uint256 callerScoopBefore = scoopToken.balanceOf(randomCaller);

        vm.prank(randomCaller);
        locker.collectFees(tokenId);

        uint256 ethFees = address(distributor).balance - distributorEthBefore;
        uint256 scoopFees = scoopToken.balanceOf(address(distributor)) - distributorScoopBefore;

        console2.log("distributor ETH fees", ethFees);
        console2.log("distributor Scoop fees", scoopFees);

        assertGt(ethFees, 0, "ETH to distributor");
        assertGt(scoopFees, 0, "Scoop to distributor");

        // Recipients must NOT receive until distribute* is called.
        assertEq(address(rewards).balance, 0);
        assertEq(deployerRecipient.balance, 0);
        assertEq(buybackVault.balance, 0);
        assertEq(operations.balance, 0);
        assertEq(scoopToken.balanceOf(address(rewards)), 0);
        assertEq(scoopToken.balanceOf(deployerRecipient), 0);
        assertEq(scoopToken.balanceOf(buybackVault), 0);
        assertEq(scoopToken.balanceOf(operations), 0);

        // Caller gets no reward.
        assertEq(randomCaller.balance, callerEthBefore);
        assertEq(scoopToken.balanceOf(randomCaller), callerScoopBefore);

        assertEq(posm.getPositionLiquidity(tokenId), liqBefore);
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertEq(address(locker).balance, 0, "locker must not custody ETH fees");
        assertEq(scoopToken.balanceOf(address(locker)), 0, "locker must not custody Scoop fees");
    }

    function test_collectFeesRevertsForUnownedToken() public {
        uint256 otherId = _mintOneSidedLiquidity();
        vm.expectRevert(ScoopLiquidityLocker.NotTokenOwner.selector);
        locker.collectFees(otherId);
    }

    function test_distributeETH_afterCollect_v1Split() public {
        _generateFees();
        locker.collectFees(tokenId);

        uint256 ethFees = address(distributor).balance;
        assertGt(ethFees, 0);

        uint256 expectedCreator = (ethFees * CREATOR_REWARDS_BPS) / 10_000;
        uint256 expectedDeployer = (ethFees * DEPLOYER_BPS) / 10_000;
        uint256 expectedBuyback = (ethFees * BUYBACK_BPS) / 10_000;
        uint256 expectedOps = ethFees - expectedCreator - expectedDeployer - expectedBuyback;

        distributor.distributeETH();

        assertEq(rewards.claimableETH(walletCreatorId), expectedCreator);
        assertEq(address(rewards).balance, expectedCreator);
        assertEq(deployerRecipient.balance, expectedDeployer);
        assertEq(buybackVault.balance, expectedBuyback);
        assertEq(operations.balance, expectedOps);
        assertEq(address(distributor).balance, 0);
        assertEq(walletCreator.balance, 0);

        console2.log("ETH fees collected", ethFees);
        console2.log("distributed ETH creatorRewards", expectedCreator);
        console2.log("distributed ETH deployer", expectedDeployer);
        console2.log("distributed ETH buyback", expectedBuyback);
        console2.log("distributed ETH operations", expectedOps);
    }

    function test_distributeToken_afterCollect_v1Split() public {
        _generateFees();
        locker.collectFees(tokenId);

        uint256 scoopFees = scoopToken.balanceOf(address(distributor));
        assertGt(scoopFees, 0);

        uint256 expectedCreator = (scoopFees * CREATOR_REWARDS_BPS) / 10_000;
        uint256 expectedDeployer = (scoopFees * DEPLOYER_BPS) / 10_000;
        uint256 expectedBuyback = (scoopFees * BUYBACK_BPS) / 10_000;
        uint256 expectedOps = scoopFees - expectedCreator - expectedDeployer - expectedBuyback;

        distributor.distributeToken(address(scoopToken));

        assertEq(rewards.claimableToken(walletCreatorId, address(scoopToken)), expectedCreator);
        assertEq(scoopToken.balanceOf(address(rewards)), expectedCreator);
        assertEq(scoopToken.balanceOf(deployerRecipient), expectedDeployer);
        assertEq(scoopToken.balanceOf(buybackVault), expectedBuyback);
        assertEq(scoopToken.balanceOf(operations), expectedOps);
        assertEq(scoopToken.balanceOf(address(distributor)), 0);
        assertEq(scoopToken.balanceOf(walletCreator), 0);

        console2.log("Scoop fees collected", scoopFees);
        console2.log("distributed Scoop creatorRewards", expectedCreator);
        console2.log("distributed Scoop deployer", expectedDeployer);
        console2.log("distributed Scoop buyback", expectedBuyback);
        console2.log("distributed Scoop operations", expectedOps);
    }

    function test_lpRemainsLockedAndMarketUsableAfterCollectAndDistribute() public {
        _generateFees();
        locker.collectFees(tokenId);
        distributor.distributeETH();
        distributor.distributeToken(address(scoopToken));

        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);

        uint256 bought = _buyScoop(0.01 ether);
        assertGt(bought, 0);
    }

    function test_repeatedSwapCollectDistributeWorks() public {
        _generateFees();
        locker.collectFees(tokenId);
        uint256 eth1 = address(distributor).balance;
        distributor.distributeETH();
        distributor.distributeToken(address(scoopToken));

        _generateFees();
        locker.collectFees(tokenId);
        uint256 eth2 = address(distributor).balance;
        uint256 scoop2 = scoopToken.balanceOf(address(distributor));
        assertGt(eth2, 0);
        assertGt(scoop2, 0);

        distributor.distributeETH();
        distributor.distributeToken(address(scoopToken));

        assertEq(address(distributor).balance, 0);
        assertEq(scoopToken.balanceOf(address(distributor)), 0);
        assertEq(IERC721(address(posm)).ownerOf(tokenId), address(locker));
        assertEq(posm.getPositionLiquidity(tokenId), mintedLiquidity);

        // Cumulative creator credits should reflect both rounds (still escrowed until claim).
        assertEq(
            rewards.claimableETH(walletCreatorId),
            ((eth1 * CREATOR_REWARDS_BPS) / 10_000) + ((eth2 * CREATOR_REWARDS_BPS) / 10_000)
        );
        assertEq(deployerRecipient.balance, ((eth1 * DEPLOYER_BPS) / 10_000) + ((eth2 * DEPLOYER_BPS) / 10_000));
    }

    function test_noEscapeHatchSelectors() public {
        bytes4[] memory probes = new bytes4[](10);
        probes[0] = bytes4(keccak256("transferFrom(address,address,uint256)"));
        probes[1] = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
        probes[2] = bytes4(keccak256("rescueNFT(uint256,address)"));
        probes[3] = bytes4(keccak256("withdrawNFT(uint256)"));
        probes[4] = bytes4(keccak256("emergencyWithdraw(uint256)"));
        probes[5] = bytes4(keccak256("decreaseLiquidity(uint256,uint256)"));
        probes[6] = bytes4(keccak256("burn(uint256)"));
        probes[7] = bytes4(keccak256("setFeeDistributor(address)"));
        probes[8] = bytes4(keccak256("setPositionManager(address)"));
        probes[9] = bytes4(keccak256("execute(address,uint256,bytes)"));

        for (uint256 i; i < probes.length; ++i) {
            (bool ok,) = address(locker).call(abi.encodePacked(probes[i]));
            assertFalse(ok);
        }
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
