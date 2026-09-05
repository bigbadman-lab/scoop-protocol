// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

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
import {ScoopLaunchMath} from "../src/libraries/ScoopLaunchMath.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @notice Robinhood fork: multi-quote ScoopFactory (ETH + AAPL) with $5k FDV pricing.
 */
contract ScoopFactoryMultiQuoteForkTest is Test {
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
    address deployer;
    address walletCreator;
    address trader;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        quoteAuthority = makeAddr("quoteAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        deployer = makeAddr("launchDeployer");
        walletCreator = makeAddr("walletCreator");
        trader = makeAddr("trader");

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
            operations
        );
        factory = protocol.factory();
        rewards = protocol.creatorRewards();
        assertEq(rewards.sourceRegistrar(), address(factory));

        vm.deal(deployer, 50 ether);
        vm.deal(trader, 50 ether);
    }

    function test_launchWithEthUsesApprovedQuote() public {
        (address token,,,,) = _launchEth("EthQ", "EQ", bytes32(uint256(1)));
        assertEq(factory.getLaunch(token).quoteAsset, address(0));
        assertTrue(quoteRegistry.isEnabled(address(0)));
    }

    function test_ethLaunchUsesOracleDerivedFiveThousandDollarFdv() public {
        uint256 gasBefore = gasleft();
        (address token,,,, PoolId poolId) = _launchEth("Eth5k", "E5K", bytes32(uint256(2)));
        console2.log("ETH launch() gas", gasBefore - gasleft());

        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        uint256 ethUsd = priceOracle.getPriceUsd(address(0));
        (uint256 tokenUsd, uint256 fdv) = _reconstructFdv(rec, 18, ethUsd);

        console2.log("ETH USD", ethUsd);
        console2.log("ETH sqrt", rec.openingSqrtPriceX96);
        console2.logInt(rec.openingTick);
        console2.logInt(rec.tickLower);
        console2.logInt(rec.tickUpper);
        console2.log("ETH tokenUsd", tokenUsd);
        console2.log("ETH FDV", fdv);

        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        assertTrue(rec.tickUpper < rec.openingTick);
        assertEq(int256(rec.tickUpper - rec.tickLower), 200);

        (uint160 liveSqrt,,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertEq(liveSqrt, rec.openingSqrtPriceX96);
    }

    function test_ethLaunchUsesDynamicOneSidedTicks() public {
        (address token,,,,) = _launchEth("Dyn", "DYN", bytes32(uint256(3)));
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        assertTrue(rec.tickLower % 200 == 0);
        assertTrue(rec.tickUpper % 200 == 0);
        assertTrue(rec.tickUpper < rec.openingTick);
        // Must not be the legacy fixed range unless opening happens to land there.
        assertFalse(rec.openingTick == 0 && rec.tickLower == -400 && rec.tickUpper == -200);
    }

    function test_ethLaunchRequiresZeroQuotePrincipal() public {
        uint256 ethBefore = address(factory).balance;
        (address token,,,,) = _launchEth("ZEth", "ZE", bytes32(uint256(4)));
        assertEq(address(factory).balance, ethBefore);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(IERC20(token).balanceOf(deployer), 0);
    }

    function test_launchWithAaplAsCurrency0() public {
        bytes32 salt = _findSalt("AaplC0", "AC0", true);
        uint256 gasBefore = gasleft();
        (address token, address feeDist, address locker, uint256 lpId,) = _launchAapl("AaplC0", "AC0", salt);
        console2.log("AAPL c0 launch() gas", gasBefore - gasleft());

        assertTrue(token > AAPL_TOKEN);
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        assertEq(rec.quoteAsset, AAPL_TOKEN);
        assertTrue(rec.tickUpper < rec.openingTick);

        (PoolKey memory key,) = IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);
        assertEq(Currency.unwrap(key.currency0), AAPL_TOKEN);
        assertEq(Currency.unwrap(key.currency1), token);

        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), locker);

        uint256 aaplUsd = priceOracle.getPriceUsd(AAPL_TOKEN);
        (, uint256 fdv) = _reconstructFdv(rec, 18, aaplUsd);
        console2.log("AAPL c0 sqrt", rec.openingSqrtPriceX96);
        console2.logInt(rec.openingTick);
        console2.logInt(rec.tickLower);
        console2.logInt(rec.tickUpper);
        console2.log("AAPL c0 FDV", fdv);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        feeDist; // silence
    }

    function test_launchWithAaplAsCurrency1() public {
        bytes32 salt = _findSalt("AaplC1", "AC1", false);
        (address token,,, uint256 lpId,) = _launchAapl("AaplC1", "AC1", salt);

        assertTrue(token < AAPL_TOKEN);
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        assertTrue(rec.tickLower > rec.openingTick);

        (PoolKey memory key,) = IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);
        assertEq(Currency.unwrap(key.currency0), token);
        assertEq(Currency.unwrap(key.currency1), AAPL_TOKEN);

        (, uint256 fdv) = _reconstructFdv(rec, 18, priceOracle.getPriceUsd(AAPL_TOKEN));
        console2.log("AAPL c1 sqrt", rec.openingSqrtPriceX96);
        console2.logInt(rec.openingTick);
        console2.logInt(rec.tickLower);
        console2.logInt(rec.tickUpper);
        console2.log("AAPL c1 FDV", fdv);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
    }

    function test_aaplLaunchRequiresZeroAaplPrincipal() public {
        bytes32 salt = _findSalt("NoAapl", "NA", true);
        uint256 aaplBefore = IERC20(AAPL_TOKEN).balanceOf(address(factory));
        _launchAapl("NoAapl", "NA", salt);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), aaplBefore);
        assertEq(aaplBefore, 0);
    }

    function test_aaplPoolBuyAndRoundTrip() public {
        bytes32 salt = _findSalt("Trade", "TRD", true);
        (address token,,, uint256 lpId,) = _launchAapl("Trade", "TRD", salt);

        uint256 aaplIn = 1e18; // 1 AAPL
        deal(AAPL_TOKEN, trader, aaplIn);
        _approveTraderErc20(AAPL_TOKEN);

        uint256 tokenBefore = IERC20(token).balanceOf(trader);
        uint256 bought = _swapExactIn(token, AAPL_TOKEN, aaplIn / 2, true);
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(trader), tokenBefore + bought);

        _approveTraderErc20(token);
        uint256 aaplBack = _swapExactIn(token, AAPL_TOKEN, bought / 2, false);
        assertGt(aaplBack, 0);

        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), factory.getLaunch(token).liquidityLocker);
    }

    function test_aaplFeesCollectAndDistribute() public {
        bytes32 salt = _findSalt("Fees", "FEE", true);
        (address token, address feeDist, address locker, uint256 lpId,) = _launchAapl("Fees", "FEE", salt);

        deal(AAPL_TOKEN, trader, 20e18);
        _approveTraderErc20(AAPL_TOKEN);
        uint256 bought = _swapExactIn(token, AAPL_TOKEN, 5e18, true);
        _approveTraderErc20(token);
        _swapExactIn(token, AAPL_TOKEN, bought / 2, false);
        bought = _swapExactIn(token, AAPL_TOKEN, 5e18, true);
        _swapExactIn(token, AAPL_TOKEN, bought / 2, false);

        ScoopLiquidityLocker(locker).collectFees(lpId);

        uint256 aaplFees = IERC20(AAPL_TOKEN).balanceOf(feeDist);
        uint256 ethFees = feeDist.balance;
        assertTrue(aaplFees > 0 || ethFees > 0, "expected some fees");

        uint256 deployerAaplBefore = IERC20(AAPL_TOKEN).balanceOf(deployer);
        uint256 buybackAaplBefore = IERC20(AAPL_TOKEN).balanceOf(buybackVault);
        uint256 opsAaplBefore = IERC20(AAPL_TOKEN).balanceOf(operations);
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        uint256 claimableBefore = rewards.claimableToken(creatorId, AAPL_TOKEN);

        if (aaplFees > 0) {
            ScoopFeeDistributor(payable(feeDist)).distributeToken(AAPL_TOKEN);
            uint256 expectedCreator = (aaplFees * 7000) / 10_000;
            uint256 expectedDeployer = (aaplFees * 400) / 10_000;
            uint256 expectedBuyback = (aaplFees * 2000) / 10_000;
            uint256 expectedOps = aaplFees - expectedCreator - expectedDeployer - expectedBuyback;
            assertEq(rewards.claimableToken(creatorId, AAPL_TOKEN) - claimableBefore, expectedCreator);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer) - deployerAaplBefore, expectedDeployer);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(buybackVault) - buybackAaplBefore, expectedBuyback);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(operations) - opsAaplBefore, expectedOps);
            console2.log("AAPL fees", aaplFees);
            console2.log("creator 70%", expectedCreator);
            console2.log("deployer 4%", expectedDeployer);
            console2.log("buyback 20%", expectedBuyback);
            console2.log("ops 6%", expectedOps);
        }

        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), locker);
    }

    function test_unregisteredQuoteRevertsAtomically() public {
        address bogus = makeAddr("bogusQuote");
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Bad",
            symbol: "BAD",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: bogus,
            salt: bytes32(uint256(99))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.QuoteNotRegistered.selector, bogus));
        factory.launch(params);
    }

    function test_disabledQuoteRevertsAtomically() public {
        vm.prank(quoteAuthority);
        quoteRegistry.setQuoteEnabled(AAPL_TOKEN, false);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Dis",
            symbol: "DIS",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            salt: bytes32(uint256(100))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.QuoteNotEnabled.selector, AAPL_TOKEN));
        factory.launch(params);
    }

    function test_unconfiguredOracleRevertsAtomically() public {
        address extra = makeAddr("extraQuote");
        vm.etch(extra, hex"6000"); // minimal code so IERC20Metadata may fail differently — use real mock token instead
        // Register a fresh EOA-like quote with bytecode via mock: deploy a tiny ERC20? Simpler: disable ETH feed path
        // by registering a new stock address that has code but no oracle config.
        address stock2 = address(new MockAggregatorV3(8)); // has code; treat as quote token
        vm.prank(quoteAuthority);
        quoteRegistry.registerQuote(stock2, ScoopQuoteRegistry.QuoteType.Stock);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "NoOr",
            symbol: "NOR",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: stock2,
            salt: bytes32(uint256(101))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedNotConfigured.selector, stock2));
        factory.launch(params);
    }

    function test_disabledOracleRevertsAtomically() public {
        vm.prank(oracleAuthority);
        priceOracle.setFeedEnabled(address(0), false);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "OrDis",
            symbol: "OD",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            salt: bytes32(uint256(102))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedDisabled.selector, address(0)));
        factory.launch(params);
    }

    function test_staleOracleRevertsAtomically() public {
        vm.prank(oracleAuthority);
        priceOracle.setMaxAge(address(0), 1); // 1 second — fork feed age is hours

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Stale",
            symbol: "ST",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            salt: bytes32(uint256(103))
        });
        vm.prank(deployer);
        vm.expectRevert();
        factory.launch(params);
    }

    function test_launchAndBuyStillWorksForEth() public {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "BuyEth",
            symbol: "BE",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            salt: bytes32(uint256(104))
        });
        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);
        console2.log("ETH launchAndBuy gas", gasBefore - gasleft());
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        (, uint256 fdv) = _reconstructFdv(factory.getLaunch(token), 18, priceOracle.getPriceUsd(address(0)));
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
    }

    function test_launchAndBuyAcceptsAaplWithApproval() public {
        // 4G: ERC-20 initial buy is supported when deployer approves Factory.
        bytes32 salt = _findSalt("BuyAapl", "BA", true);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "BuyAapl",
            symbol: "BA",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            salt: salt
        });
        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        vm.prank(deployer);
        (address token,,,,, uint256 bought) = factory.launchAndBuy(params, aaplIn, 1);
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
    }

    function test_invalidQuoteDecimalsRevertsAtomically() public {
        WeirdDecimalsToken weird = new WeirdDecimalsToken(24);
        vm.prank(quoteAuthority);
        quoteRegistry.registerQuote(address(weird), ScoopQuoteRegistry.QuoteType.Stock);
        vm.prank(oracleAuthority);
        priceOracle.configureFeed(address(weird), ETH_USD_FEED, TEST_MAX_AGE);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Dec",
            symbol: "DEC",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(weird),
            salt: bytes32(uint256(106))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.UnsupportedQuoteDecimals.selector, uint8(24)));
        factory.launch(params);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _launchEth(string memory name, string memory symbol, bytes32 salt)
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId)
    {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            salt: salt
        });
        vm.prank(deployer);
        return factory.launch(params);
    }

    function _launchAapl(string memory name, string memory symbol, bytes32 salt)
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId)
    {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            salt: salt
        });
        vm.prank(deployer);
        return factory.launch(params);
    }

    /// @dev Offchain salt search for CREATE2 token address orientation vs AAPL.
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

    function _approveTraderErc20(address token) internal {
        vm.startPrank(trader);
        IERC20(token).approve(PERMIT2_ADDR, type(uint256).max);
        IAllowanceTransfer(PERMIT2_ADDR).approve(token, UNIVERSAL_ROUTER_ADDR, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _swapExactIn(address scoopToken, address quote, uint256 amountIn, bool quoteForScoop)
        internal
        returns (uint256 amountOut)
    {
        PoolKey memory key = _poolKey(scoopToken, quote);
        bool zeroForOne =
            quoteForScoop ? (Currency.unwrap(key.currency0) == quote) : (Currency.unwrap(key.currency0) == scoopToken);

        address tokenIn = quoteForScoop ? quote : scoopToken;
        address tokenOut = quoteForScoop ? scoopToken : quote;
        uint256 beforeOut = IERC20(tokenOut).balanceOf(trader);

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        Currency settle = zeroForOne ? key.currency0 : key.currency1;
        Currency take = zeroForOne ? key.currency1 : key.currency0;
        inputs[0] = _encodeSwap(key, zeroForOne, uint128(amountIn), 1, settle, take);

        // For ERC20 input, UR pulls via Permit2; for ETH would need value — AAPL path only here.
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER_ADDR).execute(commands, inputs, block.timestamp + 60);
        amountOut = IERC20(tokenOut).balanceOf(trader) - beforeOut;
        tokenIn;
    }

    function _poolKey(address token, address quote) internal pure returns (PoolKey memory key) {
        Currency a = Currency.wrap(quote);
        Currency b = Currency.wrap(token);
        if (a < b) {
            key = PoolKey({currency0: a, currency1: b, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(0))});
        } else {
            key = PoolKey({currency0: b, currency1: a, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(0))});
        }
    }

    function _encodeSwap(
        PoolKey memory key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        Currency settle,
        Currency take
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
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(settle, uint256(amountIn));
        params[2] = abi.encode(take, uint256(minOut));
        return abi.encode(actions, params);
    }
}

/// @dev Minimal ERC20Metadata stub with arbitrary decimals for factory validation tests.
contract WeirdDecimalsToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}
