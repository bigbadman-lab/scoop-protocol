// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../src/ScoopFactoryDeployer.sol";
import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopLaunchMath} from "../src/libraries/ScoopLaunchMath.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev Malicious launch-fee recipient that rejects all ETH.
contract RejectEther {
    receive() external payable {
        revert("no eth");
    }

    fallback() external payable {
        revert("no eth");
    }
}

/// @dev Malicious recipient that attempts to reenter `launch` with the just-received fee.
contract ReenterLaunchFee {
    ScoopFactory public factory;
    ScoopFactory.LaunchParams public params;
    bool public attacked;

    function setTarget(ScoopFactory f, ScoopFactory.LaunchParams memory p) external {
        factory = f;
        params = p;
    }

    receive() external payable {
        if (!attacked && address(factory) != address(0)) {
            attacked = true;
            // Attempt reenter with the fee just received — must fail due to nonReentrant.
            try factory.launch{value: msg.value}(params) {} catch {}
        }
    }
}

/**
 * @notice Milestone 4J: fork coverage for fixed `LAUNCH_FEE` collection on ScoopFactory.
 * @dev Uses `factory.LAUNCH_FEE()` (instance getter). Type-level `ScoopFactory.LAUNCH_FEE` is
 *      unavailable under the current Foundry/solc toolchain.
 */
contract ScoopFactoryLaunchFeeForkTest is Test {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    /// @dev Mirrors production `ScoopFactory.LAUNCH_FEE` for pure/fuzz contexts.
    uint256 constant EXPECTED_LAUNCH_FEE = 0.0005 ether;

    uint8 constant CMD_V4_SWAP = 0x10;
    uint48 constant TEST_MAX_AGE = 7 days;
    uint256 constant FDV_REL_TOL = 1e15;

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
    address trader;
    address relayer;

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
        trader = makeAddr("trader");
        relayer = makeAddr("relayer");

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

        _deployProtocol(launchFeeRecipient);

        vm.deal(deployer, 100 ether);
        vm.deal(trader, 100 ether);
    }

    function _deployProtocol(address feeRecipient) internal {
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
            feeRecipient
        );
        factory = protocol.factory();
        rewards = protocol.creatorRewards();
        assertEq(rewards.sourceRegistrar(), address(factory));
    }

    // ──────────────────────────────────────────────
    // Constants / deployer / immutables
    // ──────────────────────────────────────────────

    function test_launchFeeConstant() public view {
        assertEq(EXPECTED_LAUNCH_FEE, 0.0005 ether);
        assertEq(0.0005 ether, EXPECTED_LAUNCH_FEE);
    }

    function test_deployerRejectsZeroRecipient() public {
        vm.expectRevert(ScoopFactory.ZeroAddress.selector);
        new ScoopFactoryDeployer(
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
            address(0)
        );
    }

    function test_immutableRecipientExposed() public view {
        assertEq(factory.launchFeeRecipient(), launchFeeRecipient);
    }

    // ──────────────────────────────────────────────
    // Plain launch value / fee routing
    // ──────────────────────────────────────────────

    function test_plainLaunch_exactFee() public {
        uint256 fee = factory.LAUNCH_FEE();
        uint256 recipientBefore = launchFeeRecipient.balance;
        ScoopFactory.LaunchParams memory params = _ethParams("FeeOk", "FOK", bytes32(uint256(1)));

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,) = factory.launch{value: fee}(params);

        assertTrue(factory.isScoopToken(token));
        assertEq(launchFeeRecipient.balance, recipientBefore + fee);
        assertEq(address(factory).balance, 0);
        assertEq(_countTopic(vm.getRecordedLogs(), _launchFeePaidTopic()), 1);
    }

    function test_plainLaunch_rejectsZeroUnderOver() public {
        uint256 fee = factory.LAUNCH_FEE();
        ScoopFactory.LaunchParams memory params = _ethParams("BadVal", "BV", bytes32(uint256(2)));

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, 0));
        factory.launch{value: 0}(params);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, fee - 1));
        factory.launch{value: fee - 1}(params);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, fee + 1));
        factory.launch{value: fee + 1}(params);
    }

    function testFuzz_plainLaunch_valueMustBeExact(uint256 v) public {
        vm.assume(v != EXPECTED_LAUNCH_FEE);
        ScoopFactory.LaunchParams memory params = _ethParams("Fuzz", "FZ", bytes32(uint256(99)));

        vm.deal(deployer, v > 50 ether ? v : 50 ether);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, EXPECTED_LAUNCH_FEE, v));
        factory.launch{value: v}(params);
    }

    // ──────────────────────────────────────────────
    // launchAndBuy — native + ERC20
    // ──────────────────────────────────────────────

    function test_nativeLaunchAndBuy_exactCombined() public {
        uint256 fee = factory.LAUNCH_FEE();
        uint256 quoteIn = 0.01 ether;
        uint256 recipientBefore = launchFeeRecipient.balance;
        ScoopFactory.LaunchParams memory params = _ethParams("BuyEth", "BE", bytes32(uint256(3)));

        vm.prank(deployer);
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: fee + quoteIn}(params, quoteIn, 1);

        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(launchFeeRecipient.balance, recipientBefore + fee);
        assertEq(address(factory).balance, 0);
    }

    function test_nativeLaunchAndBuy_rejectsWrongValue() public {
        uint256 fee = factory.LAUNCH_FEE();
        uint256 quoteIn = 0.01 ether;
        ScoopFactory.LaunchParams memory params = _ethParams("BadBuy", "BB", bytes32(uint256(4)));
        uint256 expected = fee + quoteIn;

        // Missing fee (send only quote).
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, expected, quoteIn));
        factory.launchAndBuy{value: quoteIn}(params, quoteIn, 1);

        // Excess value.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, expected, expected + 1));
        factory.launchAndBuy{value: expected + 1}(params, quoteIn, 1);

        // Mismatch: fee + wrong quote amount.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, expected, fee + 0.02 ether));
        factory.launchAndBuy{value: fee + 0.02 ether}(params, quoteIn, 1);
    }

    function test_erc20LaunchAndBuy_exactFeePlusAapl() public {
        uint256 fee = factory.LAUNCH_FEE();
        bytes32 salt = _findSalt("BuyAapl", "BA", true);
        uint256 aaplIn = 0.1e18;
        uint256 recipientBefore = launchFeeRecipient.balance;

        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "BuyAapl",
            symbol: "BA",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        vm.prank(deployer);
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: fee}(params, aaplIn, 1);

        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(launchFeeRecipient.balance, recipientBefore + fee);
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
    }

    function test_erc20LaunchAndBuy_rejectsWrongEth() public {
        uint256 fee = factory.LAUNCH_FEE();
        bytes32 salt = _findSalt("EthX", "EX", true);
        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "EthX",
            symbol: "EX",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, 0));
        factory.launchAndBuy{value: 0}(params, aaplIn, 1);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, fee, fee + 1));
        factory.launchAndBuy{value: fee + 1}(params, aaplIn, 1);
    }

    // ──────────────────────────────────────────────
    // Atomic failures — fee balance unchanged
    // ──────────────────────────────────────────────

    function test_atomicFailure_minTokensOut_feeUnchanged() public {
        uint256 fee = factory.LAUNCH_FEE();
        uint256 recipientBefore = launchFeeRecipient.balance;
        ScoopFactory.LaunchParams memory params = _ethParams("Slip", "SLP", bytes32(uint256(5)));

        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: fee + 0.01 ether}(params, 0.01 ether, type(uint128).max);

        assertEq(launchFeeRecipient.balance, recipientBefore);
        assertEq(address(factory).balance, 0);
    }

    function test_atomicFailure_invalidQuote_feeUnchanged() public {
        uint256 fee = factory.LAUNCH_FEE();
        uint256 recipientBefore = launchFeeRecipient.balance;
        address bogus = address(0xB0B);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "BadQ",
            symbol: "BQ",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: bogus,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(6))
        });

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.QuoteNotRegistered.selector, bogus));
        factory.launch{value: fee}(params);

        assertEq(launchFeeRecipient.balance, recipientBefore);
    }

    function test_atomicFailure_duplicateSalt_feeUnchanged() public {
        uint256 fee = factory.LAUNCH_FEE();
        ScoopFactory.LaunchParams memory params = _ethParams("Dup", "DUP", bytes32(uint256(7)));

        vm.prank(deployer);
        factory.launch{value: fee}(params);
        uint256 recipientAfterFirst = launchFeeRecipient.balance;

        vm.prank(deployer);
        vm.expectRevert();
        factory.launch{value: fee}(params);

        assertEq(launchFeeRecipient.balance, recipientAfterFirst);
    }

    function test_atomicFailure_badMetadata_feeUnchanged() public {
        uint256 fee = factory.LAUNCH_FEE();
        uint256 recipientBefore = launchFeeRecipient.balance;
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "BadMd",
            symbol: "BM",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopFactory.LaunchMetadata({description: "", externalUrl: "", imageUri: "ipfs://x"}),
            salt: bytes32(uint256(8))
        });

        vm.prank(deployer);
        vm.expectRevert(ScoopFactory.EmptyDescription.selector);
        factory.launch{value: fee}(params);

        assertEq(launchFeeRecipient.balance, recipientBefore);
    }

    function test_atomicFailure_insufficientErc20Approval() public {
        uint256 fee = factory.LAUNCH_FEE();
        bytes32 salt = _findSalt("NoAp", "NAP", true);
        uint256 aaplIn = 0.1e18;
        uint256 recipientBefore = launchFeeRecipient.balance;

        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn / 2);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "NoAp",
            symbol: "NAP",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        uint256 aaplBefore = IERC20(AAPL_TOKEN).balanceOf(deployer);
        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: fee}(params, aaplIn, 1);

        assertEq(launchFeeRecipient.balance, recipientBefore);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), aaplBefore);
    }

    // ──────────────────────────────────────────────
    // Malicious recipients
    // ──────────────────────────────────────────────

    function test_rejectingRecipient_revertsFully() public {
        RejectEther rejector = new RejectEther();
        _deployProtocol(address(rejector));

        uint256 fee = factory.LAUNCH_FEE();
        ScoopFactory.LaunchParams memory params = _ethParams("Rej", "REJ", bytes32(uint256(10)));
        uint256 deployerBefore = deployer.balance;

        vm.prank(deployer);
        vm.expectRevert(ScoopFactory.LaunchFeeTransferFailed.selector);
        factory.launch{value: fee}(params);

        assertEq(deployer.balance, deployerBefore);
        assertEq(address(rejector).balance, 0);
        assertEq(address(factory).balance, 0);
        assertFalse(factory.isScoopToken(address(0)));
    }

    function test_reentrantRecipient_cannotReenter() public {
        ReenterLaunchFee attacker = new ReenterLaunchFee();
        _deployProtocol(address(attacker));

        uint256 fee = factory.LAUNCH_FEE();
        ScoopFactory.LaunchParams memory params = _ethParams("Reent", "RE", bytes32(uint256(11)));
        attacker.setTarget(factory, params);

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,) = factory.launch{value: fee}(params);

        assertTrue(attacker.attacked());
        assertTrue(factory.isScoopToken(token));
        assertEq(_countTopic(vm.getRecordedLogs(), _scoopTokenCreatedTopic()), 1);
        assertEq(address(factory).balance, 0);
        assertEq(address(attacker).balance, fee);
    }

    // ──────────────────────────────────────────────
    // Events / geometry / fee split / admin surface
    // ──────────────────────────────────────────────

    function test_eventOrder_plain() public {
        uint256 fee = factory.LAUNCH_FEE();
        ScoopFactory.LaunchParams memory params = _ethParams("Ord", "ORD", bytes32(uint256(12)));

        vm.prank(deployer);
        vm.recordLogs();
        factory.launch{value: fee}(params);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeTopic = _launchFeePaidTopic();
        bytes32 createdTopic = _scoopTokenCreatedTopic();

        int256 feeIdx = -1;
        int256 createdIdx = -1;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == feeTopic && feeIdx < 0) feeIdx = int256(i);
            if (logs[i].topics[0] == createdTopic && createdIdx < 0) createdIdx = int256(i);
        }
        assertTrue(feeIdx >= 0, "LaunchFeePaid missing");
        assertTrue(createdIdx >= 0, "ScoopTokenCreated missing");
        assertTrue(feeIdx < createdIdx, "LaunchFeePaid must precede ScoopTokenCreated");
    }

    function test_lpPrincipalAndGeometryUnchanged() public {
        uint256 fee = factory.LAUNCH_FEE();
        ScoopFactory.LaunchParams memory params = _ethParams("Geo", "GEO", bytes32(uint256(13)));

        vm.prank(deployer);
        (address token,, address locker, uint256 lpId, PoolId poolId) = factory.launch{value: fee}(params);

        assertEq(factory.TICK_SPACING(), 10);
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        (PoolKey memory key, PositionInfo info) = IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);

        assertEq(key.tickSpacing, 10);
        assertEq(key.fee, 10_000);
        assertTrue(key.currency0 == CurrencyLibrary.ADDRESS_ZERO);
        assertEq(Currency.unwrap(key.currency1), token);

        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), locker);
        assertEq(info.tickLower(), rec.tickLower);
        assertEq(info.tickUpper(), rec.tickUpper);
        assertEq(rec.tickLower, TickMath.minUsableTick(10));
        assertEq(rec.tickUpper, ScoopLaunchMath.floorToSpacing(rec.openingTick, 10));

        uint128 liq = IPositionManager(POSITION_MANAGER_ADDR).getPositionLiquidity(lpId);
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(rec.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(rec.tickUpper);
        assertEq(liq, LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtU, ScoopToken(token).MAX_SUPPLY()));

        (, uint256 fdv) = _reconstructFdv(rec, 18, priceOracle.getPriceUsd(address(0)));
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);

        assertEq(address(factory).balance, 0);
        (uint160 liveSqrt,,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertEq(liveSqrt, rec.openingSqrtPriceX96);
    }

    function test_feeSplitRegression() public {
        uint256 fee = factory.LAUNCH_FEE();
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Split",
            symbol: "SPL",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(14))
        });

        vm.prank(deployer);
        (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId,) =
            factory.launch{value: fee}(params);

        ScoopFeeDistributor distributor = ScoopFeeDistributor(payable(feeDistributor));
        assertEq(distributor.creatorRewardsBps(), 7000);
        assertEq(distributor.deployerBps(), 400);
        assertEq(distributor.buybackBps(), 2000);
        assertEq(distributor.operationsBps(), 600);

        uint256 deployerEthBefore = deployer.balance;
        _generateFees(token);
        ScoopLiquidityLocker(liquidityLocker).collectFees(lpTokenId);

        uint256 ethFees = feeDistributor.balance;
        uint256 tokFees = IERC20(token).balanceOf(feeDistributor);
        assertGt(ethFees, 0);
        assertGt(tokFees, 0);

        distributor.distributeETH();
        distributor.distributeToken(token);

        uint256 cEth = (ethFees * 7000) / 10_000;
        uint256 dEth = (ethFees * 400) / 10_000;
        uint256 bEth = (ethFees * 2000) / 10_000;
        uint256 oEth = ethFees - cEth - dEth - bEth;
        uint256 cTok = (tokFees * 7000) / 10_000;
        uint256 dTok = (tokFees * 400) / 10_000;
        uint256 bTok = (tokFees * 2000) / 10_000;
        uint256 oTok = tokFees - cTok - dTok - bTok;

        assertEq(rewards.claimableETH(creatorId), cEth);
        assertEq(rewards.claimableToken(creatorId, token), cTok);
        assertEq(deployer.balance - deployerEthBefore, dEth);
        assertEq(buybackVault.balance, bEth);
        assertEq(operations.balance, oEth);
        assertEq(IERC20(token).balanceOf(deployer), dTok);
        assertEq(IERC20(token).balanceOf(buybackVault), bTok);
        assertEq(IERC20(token).balanceOf(operations), oTok);
    }

    function test_noAdminSurface() public view {
        (bool setFeeOk,) = address(factory).staticcall(abi.encodeWithSignature("setLaunchFee(uint256)", uint256(1)));
        (bool setRecipientOk,) =
            address(factory).staticcall(abi.encodeWithSignature("setLaunchFeeRecipient(address)", trader));
        (bool ownerOk,) = address(factory).staticcall(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(factory).staticcall(abi.encodeWithSignature("pause()"));
        assertFalse(setFeeOk);
        assertFalse(setRecipientOk);
        assertFalse(ownerOk);
        assertFalse(pauseOk);

        assertEq(factory.launchFeeRecipient(), launchFeeRecipient);
        assertEq(0.0005 ether, EXPECTED_LAUNCH_FEE);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _ethParams(string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (ScoopFactory.LaunchParams memory)
    {
        return ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
    }

    function _findSalt(string memory name, string memory symbol, bool tokenGreaterThanAapl)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = factory.TOKEN_DOMAIN();
        for (uint256 i = 1; i < 20_000; ++i) {
            bytes32 userSalt = bytes32(i);
            bytes32 launchSalt = keccak256(abi.encode(deployer, userSalt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, domain));
            address predicted = tokenDeployer.predictTokenAddress(name, symbol, address(factory), tokenSalt);
            if (tokenGreaterThanAapl && predicted > AAPL_TOKEN) return userSalt;
            if (!tokenGreaterThanAapl && predicted < AAPL_TOKEN && predicted != address(0)) return userSalt;
        }
        revert("orientation salt not found");
    }

    function _launchFeePaidTopic() internal pure returns (bytes32) {
        return keccak256("LaunchFeePaid(address,address,uint256)");
    }

    function _scoopTokenCreatedTopic() internal pure returns (bytes32) {
        return keccak256("ScoopTokenCreated(address,string,string,string)");
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }

    function _reconstructFdv(ScoopFactory.Launch memory rec, uint8 quoteDecimals, uint256 quoteUsd)
        internal
        pure
        returns (uint256 tokenUsd, uint256 fdv)
    {
        bool launchedIsC1 = uint160(rec.token) > uint160(rec.quoteAsset);
        uint256 tokenUnits = 1e18;
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        uint256 quoteRaw = launchedIsC1
            ? _mulDivInversePrice(tokenUnits, rec.openingSqrtPriceX96)
            : _mulDivPrice(tokenUnits, rec.openingSqrtPriceX96);
        uint256 quotePerToken1e18 = FullMath.mulDiv(quoteRaw, 1e18, quoteScale);
        tokenUsd = FullMath.mulDiv(quotePerToken1e18, quoteUsd, 1e18);
        fdv = tokenUsd * 1_000_000_000;
    }

    function _mulDivPrice(uint256 amount, uint160 sqrtP) internal pure returns (uint256) {
        uint256 a = FullMath.mulDiv(amount, sqrtP, FixedPoint96.Q96);
        return FullMath.mulDiv(a, sqrtP, FixedPoint96.Q96);
    }

    function _mulDivInversePrice(uint256 amount, uint160 sqrtP) internal pure returns (uint256) {
        uint256 a = FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtP);
        return FullMath.mulDiv(a, FixedPoint96.Q96, sqrtP);
    }

    function _generateFees(address token) internal {
        uint256 bought = _buyEth(token, 0.02 ether);
        _approveTraderToken(token);
        _sellEth(token, bought / 2);
        bought = _buyEth(token, 0.02 ether);
        _sellEth(token, bought / 2);
    }

    function _buyEth(address token, uint256 ethAmount) internal returns (uint256 scoopReceived) {
        PoolKey memory key = _ethPoolKey(token);
        uint256 beforeBal = IERC20(token).balanceOf(trader);

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, true, uint128(ethAmount), 1, key.currency0, key.currency1);

        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute{value: ethAmount}(commands, inputs, block.timestamp + 60);

        scoopReceived = IERC20(token).balanceOf(trader) - beforeBal;
    }

    function _sellEth(address token, uint256 amount) internal returns (uint256 ethReceived) {
        PoolKey memory key = _ethPoolKey(token);
        uint256 ethBefore = trader.balance;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, false, uint128(amount), 1, key.currency1, key.currency0);

        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute(commands, inputs, block.timestamp + 60);

        ethReceived = trader.balance - ethBefore;
    }

    function _ethPoolKey(address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 10_000,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
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
