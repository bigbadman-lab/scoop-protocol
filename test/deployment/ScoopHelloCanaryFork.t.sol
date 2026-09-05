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

import {ScoopProtocolDeploy} from "../../script/ScoopProtocolDeploy.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopToken} from "../../src/ScoopToken.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../../src/ScoopLiquidityLocker.sol";
import {ScoopLaunchDeployer} from "../../src/ScoopLaunchDeployer.sol";
import {ScoopLiquidityCurveHelpers} from "../helpers/ScoopLiquidityCurveHelpers.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Milestone 5C — HELLO World canary launch rehearsal on a Robinhood fork.
 */
contract ScoopHelloCanaryForkTest is Test {
    using StateLibrary for IPoolManager;

    uint8 internal constant CMD_V4_SWAP = 0x10;
    uint48 internal constant REHEARSAL_ETH_MAX_AGE = 1 days;

    ScoopProtocolDeploy.Deployed internal d;
    ScoopFactory internal factory;
    ScoopCreatorRegistry internal registry;
    ScoopCreatorRewards internal rewards;
    ScoopLaunchDeployer internal launchDeployer;

    address internal verificationAuthority;
    address internal registryAuthority;
    address internal launchFeeRecipient;
    address internal buybackVault;
    address internal operations;
    address internal deployer;
    address internal walletCreator;
    address internal trader;
    address internal attacker;
    address internal relayer;

    uint256 internal launchFee;
    address internal helloToken;
    address internal helloFeeDistributor;
    address internal helloLocker;
    uint256 internal helloLpTokenId;
    PoolId internal helloPoolId;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        verificationAuthority = makeAddr("verificationAuthority_TEST_FORK_ONLY");
        registryAuthority = makeAddr("opsAuthority_TEST_FORK_ONLY");
        launchFeeRecipient = makeAddr("launchFeeRecipient_TEST_FORK_ONLY");
        buybackVault = makeAddr("buybackVault_TEST_FORK_ONLY");
        operations = makeAddr("operations_TEST_FORK_ONLY");
        deployer = makeAddr("helloLauncher_TEST_FORK_ONLY");
        walletCreator = makeAddr("helloCreator_TEST_FORK_ONLY");
        trader = makeAddr("trader_TEST_FORK_ONLY");
        attacker = makeAddr("attacker_TEST_FORK_ONLY");
        relayer = makeAddr("relayer_TEST_FORK_ONLY");

        ScoopProtocolDeploy.Config memory cfg = ScoopProtocolDeploy.Config({
            verificationAuthority: verificationAuthority,
            registryAuthority: registryAuthority,
            oracleAuthority: registryAuthority,
            launchFeeRecipient: launchFeeRecipient,
            buybackVault: buybackVault,
            operations: operations,
            ethMaxAge: REHEARSAL_ETH_MAX_AGE,
            includeAaplRehearsal: false,
            aaplMaxAge: 0
        });

        d = ScoopProtocolDeploy.deployGlobals(cfg);
        vm.startPrank(registryAuthority);
        ScoopProtocolDeploy.configureEthQuoteAndOracle(d.quoteRegistry, d.priceOracle, cfg.ethMaxAge);
        vm.stopPrank();
        ScoopProtocolDeploy.assertPostDeployment(d, cfg);

        factory = d.factory;
        registry = d.creatorRegistry;
        rewards = d.creatorRewards;
        launchDeployer = d.launchDeployer;
        launchFee = factory.LAUNCH_FEE();

        vm.deal(deployer, 50 ether);
        vm.deal(trader, 50 ether);
        vm.deal(attacker, 5 ether);
    }

    function test_hello_plainLaunch_marketAssertions() public {
        ScoopFactory.LaunchParams memory params = _helloParams(bytes32(uint256(101)));

        uint256 feeBefore = launchFeeRecipient.balance;
        vm.prank(deployer);
        vm.recordLogs();
        (helloToken, helloFeeDistributor, helloLocker, helloLpTokenId, helloPoolId) =
            factory.launch{value: launchFee}(params);

        assertEq(launchFeeRecipient.balance - feeBefore, launchFee);
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(helloToken).balanceOf(address(factory)), 0);

        ScoopToken token = ScoopToken(helloToken);
        assertEq(token.name(), "Hello World");
        assertEq(token.symbol(), "HELLO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
        assertEq(token.MAX_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.logo(), params.metadata.imageUri);
        assertEq(token.description(), params.metadata.description);
        assertEq(token.deployer(), deployer);
        assertEq(token.launchFactory(), address(factory));
        assertGt(bytes(token.contractURI()).length, 0);

        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = token.socials();
        assertEq(tw, params.metadata.twitter);
        assertEq(tg, "");
        assertEq(dc, "");
        assertEq(web, params.metadata.website);
        assertEq(fc, "");

        ScoopFactory.Launch memory rec = factory.getLaunch(helloToken);
        assertEq(rec.deployer, deployer);
        assertEq(rec.creatorId, registry.walletCreatorId(walletCreator));
        assertEq(rec.quoteAsset, address(0));
        assertEq(rec.feeDistributor, helloFeeDistributor);
        assertEq(rec.liquidityLocker, helloLocker);
        assertEq(rec.lpTokenId, helloLpTokenId);
        assertEq(PoolId.unwrap(rec.poolId), PoolId.unwrap(helloPoolId));

        assertEq(IERC721(ScoopProtocolDeploy.POSITION_MANAGER).ownerOf(helloLpTokenId), helloLocker);
        assertGt(IPositionManager(ScoopProtocolDeploy.POSITION_MANAGER).getPositionLiquidity(helloLpTokenId), 0);

        (PoolKey memory key,) =
            IPositionManager(ScoopProtocolDeploy.POSITION_MANAGER).getPoolAndPositionInfo(helloLpTokenId);
        assertTrue(key.currency0 == CurrencyLibrary.ADDRESS_ZERO);
        assertEq(Currency.unwrap(key.currency1), helloToken);
        assertEq(uint256(key.fee), 10_000);
        assertEq(int256(key.tickSpacing), int256(10));
        assertEq(address(key.hooks), address(0));

        uint256 fdv = _reconstructFdv(rec);
        console2.log("HELLO openingTick", uint256(int256(rec.openingTick)));
        console2.log("HELLO tickLower", uint256(int256(rec.tickLower)));
        console2.log("HELLO tickUpper", uint256(int256(rec.tickUpper)));
        console2.log("HELLO FDV", fdv);
        assertApproxEqRel(fdv, 5_000e18, 1e15); // ~$5k within 0.1%

        _assertEvents(vm.getRecordedLogs(), helloToken, false);
    }

    function test_hello_launchAndBuy_recordsPurchase() public {
        ScoopFactory.LaunchParams memory params = _helloParams(bytes32(uint256(102)));
        uint256 quoteIn = 0.01 ether;

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,, uint256 tokensBought) = factory.launchAndBuy{value: launchFee + quoteIn}(params, quoteIn, 1);

        assertGt(tokensBought, 0);
        assertEq(IERC20(token).balanceOf(deployer), tokensBought);
        assertEq(address(factory).balance, 0);
        _assertEvents(vm.getRecordedLogs(), token, true);
        console2.log("HELLO launchAndBuy tokensBought", tokensBought);
    }

    function test_hello_buySell_feeSplit_claim() public {
        ScoopFactory.LaunchParams memory params = _helloParams(bytes32(uint256(103)));
        vm.prank(deployer);
        (address token, address feeDist, address locker, uint256 lpId,) = factory.launch{value: launchFee}(params);

        uint256 bought = _buy(token, 0.02 ether);
        assertGt(bought, 0);
        _approveTraderToken(token);
        uint256 ethBack = _sell(token, bought / 2);
        assertGt(ethBack, 0);

        _generateFees(token);
        ScoopLiquidityLocker(locker).collectFees(lpId);

        uint256 ethFees = feeDist.balance;
        uint256 tokFees = IERC20(token).balanceOf(feeDist);
        assertGt(ethFees, 0);

        uint256 deployerEthBefore = deployer.balance;
        uint256 buybackBefore = buybackVault.balance;
        uint256 opsBefore = operations.balance;

        ScoopFeeDistributor(payable(feeDist)).distributeETH();
        if (tokFees > 0) {
            ScoopFeeDistributor(payable(feeDist)).distributeToken(token);
        }

        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        uint256 cEth = (ethFees * 7000) / 10_000;
        uint256 dEth = (ethFees * 400) / 10_000;
        uint256 bEth = (ethFees * 2000) / 10_000;
        uint256 oEth = ethFees - cEth - dEth - bEth;

        assertEq(rewards.claimableETH(creatorId), cEth);
        assertEq(deployer.balance - deployerEthBefore, dEth);
        assertEq(buybackVault.balance - buybackBefore, bEth);
        assertEq(operations.balance - opsBefore, oEth);

        uint256 creatorBefore = walletCreator.balance;
        vm.prank(relayer);
        rewards.claimETH(creatorId, walletCreator);
        assertEq(walletCreator.balance - creatorBefore, cEth);
    }

    function test_hello_create2Grief_thenFreshSaltRecovers() public {
        bytes32 userSalt = bytes32(uint256(777));
        bytes32 launchSalt = keccak256(abi.encode(deployer, userSalt));
        bytes32 launchDomainSalt = keccak256(abi.encode(launchSalt, factory.LAUNCH_DOMAIN()));

        // Pre-occupy launch CREATE2 slot with identical constructor args.
        vm.prank(attacker);
        launchDeployer.deployLaunch(
            address(rewards),
            deployer,
            buybackVault,
            operations,
            factory.CREATOR_REWARDS_BPS(),
            factory.DEPLOYER_BPS(),
            factory.BUYBACK_BPS(),
            factory.OPERATIONS_BPS(),
            launchDomainSalt
        );

        ScoopFactory.LaunchParams memory griefed = _helloParams(userSalt);
        vm.prank(deployer);
        vm.expectRevert();
        factory.launch{value: launchFee}(griefed);

        // Fresh unpredictable salt recovers.
        ScoopFactory.LaunchParams memory recovered = _helloParams(bytes32(uint256(778)));
        vm.prank(deployer);
        (address token,,,,) = factory.launch{value: launchFee}(recovered);
        assertTrue(factory.isScoopToken(token));
    }

    function test_hello_tokenOnlyDiscovery() public {
        // Build params before prank — walletCreatorId is an external call that would consume prank.
        ScoopFactory.LaunchParams memory params = _helloParams(bytes32(uint256(104)));
        vm.prank(deployer);
        (address token,,,,) = factory.launch{value: launchFee}(params);

        ScoopToken t = ScoopToken(token);
        // Token-only discovery path (no factory required).
        assertEq(t.name(), "Hello World");
        assertEq(t.symbol(), "HELLO");
        assertEq(t.decimals(), 18);
        assertEq(t.logo(), _helloMetadata().imageUri);
        assertEq(t.description(), _helloMetadata().description);
        assertEq(t.deployer(), deployer);
        assertEq(t.launchFactory(), address(factory));
        assertGt(bytes(t.contractURI()).length, 0);
    }

    function _helloMetadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: "Hello, world. The first token launched on SCOOP.",
            imageUri: "ipfs://bafyrehearsalhello5c000000000000000000001", // REHEARSAL ONLY CID
            twitter: "https://x.com/scoopprotocol",
            telegram: "",
            discord: "",
            website: "https://scoop.fun",
            farcaster: ""
        });
    }

    function _helloParams(bytes32 salt) internal view returns (ScoopFactory.LaunchParams memory) {
        return ScoopFactory.LaunchParams({
            name: "Hello World",
            symbol: "HELLO",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: _helloMetadata(),
            salt: salt
        });
    }

    function _assertEvents(Vm.Log[] memory logs, address token, bool expectInitialBuy) internal view {
        bytes32 feeTopic = keccak256("LaunchFeePaid(address,address,uint256)");
        bytes32 createdTopic = keccak256("ScoopTokenCreated(address,string,string,string)");
        bytes32 launchedTopic = keccak256(
            "TokenLaunched(address,address,bytes32,address,address,address,bytes32,uint256,uint160,int24,int24,int24,string,string)"
        );
        bytes32 buyTopic = keccak256("InitialBuyExecuted(address,address,address,uint256,uint256)");

        bool sawFee;
        bool sawCreated;
        bool sawLaunched;
        bool sawBuy;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == feeTopic) sawFee = true;
            if (t0 == createdTopic && logs[i].topics.length > 1) {
                if (address(uint160(uint256(logs[i].topics[1]))) == token) sawCreated = true;
            }
            if (t0 == launchedTopic && logs[i].topics.length > 1) {
                if (address(uint160(uint256(logs[i].topics[1]))) == token) sawLaunched = true;
            }
            if (t0 == buyTopic) sawBuy = true;
        }
        assertTrue(sawFee, "LaunchFeePaid");
        assertTrue(sawCreated, "ScoopTokenCreated");
        assertTrue(sawLaunched, "TokenLaunched");
        if (expectInitialBuy) assertTrue(sawBuy, "InitialBuyExecuted");
        else assertFalse(sawBuy, "no InitialBuyExecuted on plain launch");
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

    function _buy(address token, uint256 ethAmount) internal returns (uint256 scoopReceived) {
        PoolKey memory key = _poolKey(token);
        uint256 beforeBal = IERC20(token).balanceOf(trader);
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, true, uint128(ethAmount), 1, key.currency0, key.currency1);
        vm.prank(trader);
        IUniversalRouter(ScoopProtocolDeploy.UNIVERSAL_ROUTER).execute{value: ethAmount}(
            commands, inputs, block.timestamp + 60
        );
        scoopReceived = IERC20(token).balanceOf(trader) - beforeBal;
    }

    function _sell(address token, uint256 amount) internal returns (uint256 ethReceived) {
        PoolKey memory key = _poolKey(token);
        uint256 ethBefore = trader.balance;
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, false, uint128(amount), 1, key.currency1, key.currency0);
        vm.prank(trader);
        IUniversalRouter(ScoopProtocolDeploy.UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 60);
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
        IERC20(token).approve(ScoopProtocolDeploy.PERMIT2, type(uint256).max);
        IAllowanceTransfer(ScoopProtocolDeploy.PERMIT2)
            .approve(token, ScoopProtocolDeploy.UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _generateFees(address token) internal {
        uint256 bought = _buy(token, 0.02 ether);
        _approveTraderToken(token);
        _sell(token, bought / 2);
        bought = _buy(token, 0.02 ether);
        _sell(token, bought / 2);
    }

    function _reconstructFdv(ScoopFactory.Launch memory rec) internal view returns (uint256 fdv) {
        uint256 ethUsd = d.priceOracle.getPriceUsd(address(0));
        bool launchedIsC1 = uint160(rec.token) > uint160(rec.quoteAsset);
        fdv = ScoopLiquidityCurveHelpers.reconstructFdv(rec.openingSqrtPriceX96, launchedIsC1, 18, ethUsd);
    }
}
