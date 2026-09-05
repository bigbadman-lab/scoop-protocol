// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../src/ScoopFactoryDeployer.sol";
import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Robinhood fork: ScoopFactory.launchAndBuy atomic initial purchase path.
 */
contract ScoopFactoryInitialBuyForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    uint8 constant CMD_V4_SWAP = 0x10;
    uint48 constant TEST_MAX_AGE = 7 days;

    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopTokenDeployer tokenDeployer;
    ScoopLaunchDeployer launchDeployer;
    ScoopQuoteRegistry quoteRegistry;
    ScoopPriceOracle priceOracle;
    ScoopFactory factory;

    address authority;
    uint256 authorityKey;
    address quoteAuthority;
    address oracleAuthority;
    address buybackVault;
    address operations;
    address deployer;
    address walletCreator;
    address relayer;

    event InitialBuyExecuted(
        address indexed token,
        address indexed deployer,
        address indexed quoteAsset,
        uint256 quoteAmountIn,
        uint256 tokensOut
    );

    function setUp() public {
        string memory rpcUrl = vm.envString("ROBINHOOD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        quoteAuthority = makeAddr("quoteAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        deployer = makeAddr("launchDeployer");
        walletCreator = makeAddr("walletCreator");
        relayer = makeAddr("relayer");

        registry = new ScoopCreatorRegistry(authority);
        tokenDeployer = new ScoopTokenDeployer();
        launchDeployer = new ScoopLaunchDeployer(POSITION_MANAGER_ADDR);

        quoteRegistry = new ScoopQuoteRegistry(quoteAuthority);
        priceOracle = new ScoopPriceOracle(oracleAuthority);

        vm.prank(quoteAuthority);
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        vm.prank(oracleAuthority);
        priceOracle.configureFeed(address(0), ETH_USD_FEED, TEST_MAX_AGE);

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(registry),
            POOL_MANAGER_ADDR,
            POSITION_MANAGER_ADDR,
            PERMIT2_ADDR,
            UNIVERSAL_ROUTER_ADDR,
            address(tokenDeployer),
            address(launchDeployer),
            address(quoteRegistry),
            address(priceOracle),
            buybackVault,
            operations
        );

        factory = protocol.factory();
        rewards = protocol.creatorRewards();

        assertEq(rewards.sourceRegistrar(), address(factory));
        assertEq(address(factory.universalRouter()), UNIVERSAL_ROUTER_ADDR);

        vm.deal(deployer, 100 ether);
    }

    function test_launchAndBuy_0_01_eth_standard() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Buy",
            symbol: "BUY",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(1))
        });

        uint256 ethIn = 0.01 ether;
        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        (
            address token,
            address feeDistributor,
            address locker,
            uint256 lpTokenId,
            PoolId poolId,
            uint256 tokensBought
        ) = factory.launchAndBuy{value: ethIn}(params, ethIn, 1);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("launchAndBuy(0.01 ETH) gas", gasUsed);
        console2.log("tokensBought", tokensBought);

        assertGt(tokensBought, 0);
        assertEq(IERC20(token).balanceOf(deployer), tokensBought);
        assertEq(IERC20(token).balanceOf(walletCreator), 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, 0);
        assertTrue(factory.isScoopToken(token));
        assertEq(factory.getLaunch(token).deployer, deployer);
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpTokenId), locker);
        assertEq(rewards.sourceCreatorId(feeDistributor), creatorId);

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertTrue(tick != 0 || sqrtPriceX96 != 79228162514264337593543950336);
        console2.logInt(tick);

        // Sellable afterward.
        _approveDeployerToken(token);
        uint256 ethBack = _sell(token, tokensBought / 2);
        assertGt(ethBack, 0);
    }

    function test_launchAndBuy_isRealMarketPurchase() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Mkt",
            symbol: "MKT",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(2))
        });

        vm.prank(deployer);
        (address token,,, uint256 lpTokenId, PoolId poolId, uint256 tokensBought) =
            factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);

        // Pool moved and LP fees are accruable from the buy (not a factory inventory transfer).
        (, int24 tick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertTrue(tick < factory.getLaunch(token).openingTick, "ETH buy should move tick down from opening");
        assertGt(tokensBought, 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);

        ScoopLiquidityLocker(factory.getLaunch(token).liquidityLocker).collectFees(lpTokenId);
        assertGt(factory.getLaunch(token).feeDistributor.balance, 0, "initial buy generates LP ETH fees");
    }

    function test_launchAndBuy_slippageRevertsAtomically() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        bytes32 salt = bytes32(uint256(3));
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Slip",
            symbol: "SLP",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        uint256 ethBefore = deployer.balance;

        // Impossible minimum — entire launchAndBuy must revert.
        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, type(uint128).max);

        assertEq(deployer.balance, ethBefore);
        assertFalse(factory.isScoopToken(address(0)));

        // Same salt still available for a successful launch afterward.
        vm.prank(deployer);
        (address token,,,,,) = factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);
        assertTrue(factory.isScoopToken(token));
    }

    function test_launchAndBuy_zeroValueReverts() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Z",
            symbol: "Z",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(4))
        });

        vm.prank(deployer);
        vm.expectRevert(ScoopFactory.ZeroInitialBuy.selector);
        factory.launchAndBuy{value: 0}(params, 0, 1);
    }

    function test_launchAndBuy_incorrectNativeValueReverts() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "NV",
            symbol: "NV",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(40))
        });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectNativeValue.selector, 0.01 ether, 0.02 ether));
        factory.launchAndBuy{value: 0.02 ether}(params, 0.01 ether, 1);
    }

    function test_launchAndBuy_ethRangeCapacity() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        // Probe increasing sizes; report first failure if range exhausted.
        uint256[8] memory sizes =
            [uint256(0.001 ether), 0.01 ether, 0.05 ether, 0.1 ether, 0.5 ether, 1 ether, 5 ether, 20 ether];
        uint256 largestOk;
        int24 tickAfterLargest;
        uint256 firstFail;
        for (uint256 i; i < sizes.length; ++i) {
            ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
                name: "Cap",
                symbol: "CAP",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(200 + i))
            });
            uint256 ethBefore = deployer.balance;
            vm.prank(deployer);
            try factory.launchAndBuy{value: sizes[i]}(params, sizes[i], 1) returns (
                address token, address, address, uint256, PoolId poolId, uint256 bought
            ) {
                assertGt(bought, 0);
                (, int24 tick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
                console2.log("ETH size ok", sizes[i]);
                console2.log("tokensBought", bought);
                console2.logInt(tick);
                console2.logInt(factory.getLaunch(token).openingTick);
                largestOk = sizes[i];
                tickAfterLargest = tick;
            } catch {
                console2.log("ETH size FAILED", sizes[i]);
                assertEq(deployer.balance, ethBefore);
                firstFail = sizes[i];
                break;
            }
        }
        console2.log("ETH largest successful initial buy", largestOk);
        console2.log("ETH first failing input", firstFail);
        console2.logInt(tickAfterLargest);
        assertGt(largestOk, 0);
    }

    function test_plainLaunch_unchanged_noInitialBuy() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Plain",
            symbol: "PLN",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(5))
        });

        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,) = factory.launch(params);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("launch() gas", gasUsed);

        assertEq(IERC20(token).balanceOf(deployer), 0);
        assertEq(IERC20(token).balanceOf(walletCreator), 0);

        bytes32 buyTopic = keccak256("InitialBuyExecuted(address,address,address,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            assertTrue(entries[i].topics[0] != buyTopic, "no InitialBuyExecuted on plain launch");
        }
    }

    function test_launchAndBuy_differentSizes() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);

        uint256 out001 = _buySize(creatorId, bytes32(uint256(10)), 0.001 ether);
        uint256 out01 = _buySize(creatorId, bytes32(uint256(11)), 0.01 ether);
        uint256 out05 = _buySize(creatorId, bytes32(uint256(12)), 0.05 ether);

        assertGt(out001, 0);
        assertGt(out01, out001);
        assertGt(out05, out01);
        console2.log("out 0.001", out001);
        console2.log("out 0.01", out01);
        console2.log("out 0.05", out05);
    }

    function test_launchAndBuy_sellAfter() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Sell",
            symbol: "SEL",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(6))
        });

        vm.prank(deployer);
        (address token,,,,, uint256 tokensBought) = factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);

        _approveDeployerToken(token);
        uint256 ethBack = _sell(token, tokensBought / 3);
        assertGt(ethBack, 0);
    }

    function test_launchAndBuy_feeCollectionAndClaim() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Fee",
            symbol: "FEE",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(7))
        });

        vm.prank(deployer);
        (address token, address feeDistributor, address locker, uint256 lpTokenId,, uint256 tokensBought) =
            factory.launchAndBuy{value: 0.02 ether}(params, 0.02 ether, 1);
        assertGt(tokensBought, 0);

        uint256 ethBalBeforeDistribute = deployer.balance;

        ScoopLiquidityLocker(locker).collectFees(lpTokenId);
        uint256 ethFees = feeDistributor.balance;
        assertGt(ethFees, 0);
        console2.log("initial-buy ETH fees", ethFees);

        ScoopFeeDistributor(payable(feeDistributor)).distributeETH();

        uint256 expectedCreator = (ethFees * 7000) / 10_000;
        uint256 expectedDeployer = (ethFees * 400) / 10_000;
        uint256 expectedBuyback = (ethFees * 2000) / 10_000;
        uint256 expectedOps = ethFees - expectedCreator - expectedDeployer - expectedBuyback;

        assertEq(rewards.claimableETH(creatorId), expectedCreator);
        assertEq(deployer.balance - ethBalBeforeDistribute, expectedDeployer);
        assertEq(buybackVault.balance, expectedBuyback);
        assertEq(operations.balance, expectedOps);

        vm.prank(relayer);
        rewards.claimETH(creatorId, walletCreator);
        assertEq(walletCreator.balance, expectedCreator);
        assertEq(IERC20(token).balanceOf(deployer), tokensBought);
    }

    function test_launchAndBuy_xCreatorLifecycle() public {
        uint256 xUser = 900001;
        bytes32 creatorId = registry.xCreatorId(xUser);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "XBuy",
            symbol: "XB",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(8))
        });

        vm.prank(deployer);
        (address token, address feeDistributor, address locker, uint256 lpTokenId,, uint256 tokensBought) =
            factory.launchAndBuy{value: 0.02 ether}(params, 0.02 ether, 1);

        assertGt(tokensBought, 0);
        assertEq(IERC20(token).balanceOf(deployer), tokensBought);
        assertFalse(registry.isXClaimed(xUser));

        ScoopLiquidityLocker(locker).collectFees(lpTokenId);
        assertGt(feeDistributor.balance, 0);
        uint256 expectedCreator = (feeDistributor.balance * 7000) / 10_000;
        ScoopFeeDistributor(payable(feeDistributor)).distributeETH();

        assertEq(rewards.claimableETH(creatorId), expectedCreator);

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(creatorId, walletCreator);

        _claimX(xUser, walletCreator);

        uint256 beforeBal = walletCreator.balance;
        rewards.claimETH(creatorId, address(0));
        assertEq(walletCreator.balance, beforeBal + expectedCreator);
        assertEq(IERC20(token).balanceOf(deployer), tokensBought);
    }

    function _claimX(uint256 xUser, address wallet) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(xUser, wallet, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, digest);
        registry.claimXIdentity(xUser, wallet, deadline, abi.encodePacked(r, s, v));
    }

    function test_launchAndBuy_deployerAttribution() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Attr",
            symbol: "ATR",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(9))
        });

        vm.prank(deployer);
        (address token, address feeDistributor,,,, uint256 tokensBought) =
            factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);

        assertEq(factory.getLaunch(token).deployer, deployer);
        assertEq(IERC20(token).balanceOf(deployer), tokensBought);
        assertEq(ScoopFeeDistributor(payable(feeDistributor)).deployer(), deployer);
    }

    function test_launchAndBuy_duplicateSaltReverts() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Dup",
            symbol: "DUP",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(15))
        });

        vm.prank(deployer);
        factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);

        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);
    }

    function test_launchAndBuy_emitsInitialBuyExecuted() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Evt",
            symbol: "EVT",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(16))
        });

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,, uint256 tokensBought) = factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);

        bytes32 topic0 = keccak256("InitialBuyExecuted(address,address,address,uint256,uint256)");
        bool found;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length >= 4 && entries[i].topics[0] == topic0) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), token);
                assertEq(address(uint160(uint256(entries[i].topics[2]))), deployer);
                assertEq(address(uint160(uint256(entries[i].topics[3]))), address(0));
                (uint256 quoteAmountIn, uint256 tokensOut) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(quoteAmountIn, 0.01 ether);
                assertEq(tokensOut, tokensBought);
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_sourceRegistrarStillFactory() public view {
        assertEq(rewards.sourceRegistrar(), address(factory));
    }

    function test_noAdminSurface() public {
        (bool ownerOk,) = address(factory).call(abi.encodeWithSignature("owner()"));
        (bool setRouterOk,) = address(factory).call(abi.encodeWithSignature("setUniversalRouter(address)", address(1)));
        assertFalse(ownerOk);
        assertFalse(setRouterOk);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _buySize(bytes32 creatorId, bytes32 salt, uint256 ethIn) internal returns (uint256 tokensBought) {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Sz",
            symbol: "SZ",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        (,,,,, tokensBought) = factory.launchAndBuy{value: ethIn}(params, ethIn, 1);
    }

    function _poolKey(address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 10_000,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
    }

    function _sell(address token, uint256 amount) internal returns (uint256 ethReceived) {
        PoolKey memory key = _poolKey(token);
        uint256 ethBefore = deployer.balance;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: uint128(amount),
                amountOutMinimum: 1,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency1, uint256(amount));
        params[2] = abi.encode(key.currency0, uint256(1));
        inputs[0] = abi.encode(actions, params);

        vm.prank(deployer);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute(commands, inputs, block.timestamp + 60);

        ethReceived = deployer.balance - ethBefore;
    }

    function _approveDeployerToken(address token) internal {
        vm.startPrank(deployer);
        IERC20(token).approve(PERMIT2_ADDR, type(uint256).max);
        IAllowanceTransfer(PERMIT2_ADDR).approve(token, UNIVERSAL_ROUTER_ADDR, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}
