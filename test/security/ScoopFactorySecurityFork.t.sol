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

import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopToken} from "../../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../../src/ScoopLaunchDeployer.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../../src/ScoopFactoryDeployer.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../../src/ScoopLiquidityLocker.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Milestone 5B fork security suite. setUp mirrors `ScoopFactoryForkTest`.
 */
contract ScoopFactorySecurityForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

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
    address launchFeeRecipient;
    address deployer;
    address walletCreator;
    address walletCreatorB;
    address trader;
    address attacker;

    uint256 launchFee;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        quoteAuthority = makeAddr("quoteAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        launchFeeRecipient = makeAddr("launchFeeRecipient");
        deployer = makeAddr("launchDeployer");
        walletCreator = makeAddr("walletCreator");
        walletCreatorB = makeAddr("walletCreatorB");
        trader = makeAddr("trader");
        attacker = makeAddr("attacker");

        registry = new ScoopCreatorRegistry(authority);
        tokenDeployer = new ScoopTokenDeployer();
        launchDeployer = new ScoopLaunchDeployer(POSITION_MANAGER_ADDR);
        quoteRegistry = new ScoopQuoteRegistry(quoteAuthority);
        priceOracle = new ScoopPriceOracle(oracleAuthority);

        vm.startPrank(quoteAuthority);
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        quoteRegistry.registerQuote(AAPL_TOKEN, ScoopQuoteRegistry.QuoteType.Stock);
        vm.stopPrank();

        vm.startPrank(oracleAuthority);
        priceOracle.configureFeed(address(0), ETH_USD_FEED, TEST_MAX_AGE);
        priceOracle.configureFeed(AAPL_TOKEN, AAPL_USD_FEED, TEST_MAX_AGE);
        vm.stopPrank();

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
            operations,
            launchFeeRecipient
        );
        factory = protocol.factory();
        rewards = protocol.creatorRewards();

        assertEq(rewards.sourceRegistrar(), address(factory));
        assertEq(factory.buybackVault(), buybackVault);
        assertEq(factory.operations(), operations);
        assertEq(factory.launchFeeRecipient(), launchFeeRecipient);

        vm.deal(deployer, 100 ether);
        vm.deal(trader, 50 ether);
        vm.deal(attacker, 10 ether);

        launchFee = factory.LAUNCH_FEE();
    }

    function test_factoryCustodyZero_afterLaunchAndLaunchAndBuy() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);

        vm.prank(deployer);
        (address token,,,,) = factory.launch{value: launchFee}(
            ScoopFactory.LaunchParams({
                name: "Cust",
                symbol: "CST",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(1))
            })
        );
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(ScoopToken(token).totalSupply(), ScoopToken(token).MAX_SUPPLY());

        vm.prank(deployer);
        (address token2,,,,,) = factory.launchAndBuy{value: launchFee + 0.01 ether}(
            ScoopFactory.LaunchParams({
                name: "Cust2",
                symbol: "CS2",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(2))
            }),
            0.01 ether,
            1
        );
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(token2).balanceOf(address(factory)), 0);
    }

    function test_lpNftOwnerIsLockerForever_throughCollectFees() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (address token,, address locker, uint256 lpTokenId,) = factory.launch{value: launchFee}(
            ScoopFactory.LaunchParams({
                name: "LP",
                symbol: "LP",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(3))
            })
        );
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpTokenId), locker);

        _generateFees(token);
        ScoopLiquidityLocker(locker).collectFees(lpTokenId);
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpTokenId), locker);
    }

    function test_atomicFailure_badMinTokensOut_noState() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        uint256 feeBefore = launchFeeRecipient.balance;
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Slip",
            symbol: "SLP",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(4))
        });

        uint256 fee = factory.LAUNCH_FEE();
        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: fee + 0.01 ether}(params, 0.01 ether, type(uint128).max);

        assertEq(launchFeeRecipient.balance, feeBefore);
        assertEq(address(factory).balance, 0);

        vm.prank(deployer);
        (address token,,,,) = factory.launch{value: fee}(params);
        assertTrue(factory.isScoopToken(token));
    }

    function test_atomicFailure_wrongMsgValue_noState() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        uint256 feeBefore = launchFeeRecipient.balance;
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Val",
            symbol: "VAL",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(5))
        });

        uint256 fee = factory.LAUNCH_FEE();
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, fee + 1));
        factory.launch{value: fee + 1}(params);

        assertEq(launchFeeRecipient.balance, feeBefore);
    }

    function test_nativeOversizedBuys_ladder_recordLeftoverRefundFactoryBalance() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        uint256[3] memory sizes = [uint256(1 ether), 5 ether, 20 ether];

        for (uint256 i; i < sizes.length; ++i) {
            ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
                name: "Ovr",
                symbol: "OVR",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(100 + i))
            });

            uint256 depBefore = deployer.balance;
            uint256 feeBefore = launchFeeRecipient.balance;
            uint256 fee = factory.LAUNCH_FEE();

            vm.prank(deployer);
            try factory.launchAndBuy{value: fee + sizes[i]}(params, sizes[i], 1) returns (
                address token, address, address, uint256, PoolId, uint256 bought
            ) {
                console2.log("native oversized ok size", sizes[i]);
                console2.log("tokensBought", bought);
                console2.log("deployer delta", depBefore - deployer.balance);
                assertEq(address(factory).balance, 0, "factory must not retain ETH");
                assertEq(IERC20(token).balanceOf(address(factory)), 0);
                assertEq(launchFeeRecipient.balance, feeBefore + fee);
            } catch {
                console2.log("native oversized FAILED size", sizes[i]);
                assertEq(deployer.balance, depBefore);
                assertEq(launchFeeRecipient.balance, feeBefore);
                assertEq(address(factory).balance, 0);
            }
        }
    }

    function test_erc20AaplOversizedBuy_revertsAtomically() public {
        bytes32 salt = _findSaltTokenGtAapl();
        uint256 fee = factory.LAUNCH_FEE();
        uint256 feeBefore = launchFeeRecipient.balance;
        uint256 huge = 1_000_000e18;

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "AaplO",
            symbol: "AO",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        deal(AAPL_TOKEN, deployer, 1e18);
        vm.startPrank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), huge);
        vm.expectRevert();
        factory.launchAndBuy{value: fee}(params, huge, 1);
        vm.stopPrank();

        assertEq(launchFeeRecipient.balance, feeBefore);
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
    }

    function test_crossLaunchIsolation_feesOfADoNotCreditCreatorB() public {
        bytes32 idA = registry.walletCreatorId(walletCreator);
        bytes32 idB = registry.walletCreatorId(walletCreatorB);

        vm.prank(deployer);
        (address tokenA, address distA, address lockerA, uint256 lpA,) = factory.launch{value: launchFee}(
            ScoopFactory.LaunchParams({
                name: "A",
                symbol: "A",
                creatorId: idA,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(20))
            })
        );
        vm.prank(deployer);
        (, address distB,,,) = factory.launch{value: launchFee}(
            ScoopFactory.LaunchParams({
                name: "B",
                symbol: "B",
                creatorId: idB,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(21))
            })
        );

        assertEq(rewards.sourceCreatorId(distA), idA);
        assertEq(rewards.sourceCreatorId(distB), idB);

        _generateFees(tokenA);
        ScoopLiquidityLocker(lockerA).collectFees(lpA);
        ScoopFeeDistributor(payable(distA)).distributeETH();

        assertGt(rewards.claimableETH(idA), 0);
        assertEq(rewards.claimableETH(idB), 0);
    }

    function test_oracleStaleAfterLaunch_tradingAndFeeCollectStillWork() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (address token,, address locker, uint256 lpTokenId,) = factory.launch{value: launchFee}(
            ScoopFactory.LaunchParams({
                name: "Stale",
                symbol: "ST",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(30))
            })
        );

        vm.prank(oracleAuthority);
        priceOracle.setFeedEnabled(address(0), false);

        uint256 bought = _buy(token, 0.02 ether);
        assertGt(bought, 0);
        _approveTraderToken(token);
        uint256 ethBack = _sell(token, bought / 2);
        assertGt(ethBack, 0);

        ScoopLiquidityLocker(locker).collectFees(lpTokenId);
        assertGt(factory.getLaunch(token).feeDistributor.balance, 0);
    }

    function test_permissionlessPredeployGrief_onFork() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        address dep = makeAddr("griefDep");
        vm.deal(dep, 1 ether);
        bytes32 userSalt = bytes32(uint256(77));
        bytes32 launchSalt = keccak256(abi.encode(dep, userSalt));
        bytes32 launchDomainSalt = keccak256(abi.encode(launchSalt, factory.LAUNCH_DOMAIN()));

        vm.prank(attacker);
        launchDeployer.deployLaunch(
            address(rewards),
            dep,
            buybackVault,
            operations,
            factory.CREATOR_REWARDS_BPS(),
            factory.DEPLOYER_BPS(),
            factory.BUYBACK_BPS(),
            factory.OPERATIONS_BPS(),
            launchDomainSalt
        );

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Grief",
            symbol: "GRF",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: userSalt
        });

        vm.startPrank(dep);
        vm.expectRevert();
        factory.launch{value: launchFee}(params);
        vm.stopPrank();
    }

    function test_gasSnapshot_maxMetadataLaunch() public {
        uint256 maxDesc = factory.MAX_DESCRIPTION_BYTES();
        uint256 maxImg = factory.MAX_IMAGE_URI_BYTES();
        uint256 maxSocial = factory.MAX_SOCIAL_URL_BYTES();
        uint256 maxWeb = factory.MAX_WEBSITE_BYTES();

        ScoopFactory.LaunchMetadata memory md = ScoopFactory.LaunchMetadata({
            description: _repeat("d", maxDesc),
            imageUri: string(abi.encodePacked("ipfs://", _repeat("i", maxImg - 7))),
            twitter: string(abi.encodePacked("https://x.com/", _repeat("t", maxSocial - 14))),
            telegram: string(abi.encodePacked("https://t.me/", _repeat("g", maxSocial - 13))),
            discord: string(abi.encodePacked("https://discord.gg/", _repeat("c", maxSocial - 19))),
            website: string(abi.encodePacked("https://", _repeat("w", maxWeb - 8))),
            farcaster: string(abi.encodePacked("https://warpcast.com/", _repeat("f", maxSocial - 21)))
        });

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "MaxMeta",
            symbol: "MAX",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: md,
            salt: bytes32(uint256(40))
        });

        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        factory.launch{value: launchFee}(params);
        console2.log("max metadata launch gas", gasBefore - gasleft());
    }

    function test_events_oneTokenLaunched_oneLaunchFeePaid_perSuccess_noneOnRevert() public {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Evt",
            symbol: "EVT",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(50))
        });

        vm.prank(deployer);
        vm.recordLogs();
        factory.launch{value: launchFee}(params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topicLaunch = keccak256(
            "TokenLaunched(address,address,bytes32,address,address,address,bytes32,uint256,uint160,int24,int24,int24,string,string)"
        );
        bytes32 topicFee = keccak256("LaunchFeePaid(address,address,uint256)");
        uint256 launchCount;
        uint256 feeCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topicLaunch) launchCount++;
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topicFee) feeCount++;
        }
        assertEq(launchCount, 1);
        assertEq(feeCount, 1);

        ScoopFactory.LaunchParams memory bad = params;
        bad.salt = bytes32(uint256(51));
        vm.prank(deployer);
        vm.recordLogs();
        try factory.launch{value: 1}(bad) {} catch {}
        Vm.Log[] memory failLogs = vm.getRecordedLogs();
        uint256 failLaunch;
        uint256 failFee;
        for (uint256 i; i < failLogs.length; ++i) {
            if (failLogs[i].topics.length > 0 && failLogs[i].topics[0] == topicLaunch) failLaunch++;
            if (failLogs[i].topics.length > 0 && failLogs[i].topics[0] == topicFee) failFee++;
        }
        assertEq(failLaunch, 0);
        assertEq(failFee, 0);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _findSaltTokenGtAapl() internal view returns (bytes32) {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        for (uint256 i = 1; i < 800; ++i) {
            bytes32 salt = bytes32(i);
            bytes32 launchSalt = keccak256(abi.encode(deployer, salt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, factory.TOKEN_DOMAIN()));
            address predicted = tokenDeployer.predictTokenAddress(
                "AaplO",
                "AO",
                address(factory),
                deployer,
                address(factory),
                md.imageUri,
                md.description,
                ScoopLaunchMetadataHelpers.toSocials(md),
                tokenSalt
            );
            if (predicted > AAPL_TOKEN) return salt;
        }
        revert("salt not found");
    }

    function _repeat(string memory ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        bytes1 c = bytes(ch)[0];
        for (uint256 i; i < n; ++i) {
            b[i] = c;
        }
        return string(b);
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

    function _generateFees(address token) internal {
        uint256 bought = _buy(token, 0.02 ether);
        _approveTraderToken(token);
        _sell(token, bought / 2);
        bought = _buy(token, 0.02 ether);
        _sell(token, bought / 2);
    }

    function _buy(address token, uint256 ethAmount) internal returns (uint256 scoopReceived) {
        PoolKey memory key = _poolKey(token);
        uint256 beforeBal = IERC20(token).balanceOf(trader);

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, true, uint128(ethAmount), 1, key.currency0, key.currency1);

        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute{value: ethAmount}(commands, inputs, block.timestamp + 60);

        scoopReceived = IERC20(token).balanceOf(trader) - beforeBal;
    }

    function _sell(address token, uint256 amount) internal returns (uint256 ethReceived) {
        PoolKey memory key = _poolKey(token);
        uint256 ethBefore = trader.balance;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, false, uint128(amount), 1, key.currency1, key.currency0);

        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute(commands, inputs, block.timestamp + 60);

        ethReceived = trader.balance - ethBefore;
    }

    function _encodeV4ExactInSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 amountOutMinimum,
        Currency settleCurrency,
        Currency takeCurrency
    ) internal pure returns (bytes memory) {
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

    function _approveTraderToken(address token) internal {
        vm.startPrank(trader);
        IERC20(token).approve(PERMIT2_ADDR, type(uint256).max);
        IAllowanceTransfer(PERMIT2_ADDR).approve(token, UNIVERSAL_ROUTER_ADDR, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}
