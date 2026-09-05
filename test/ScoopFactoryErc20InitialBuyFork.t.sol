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
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";

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
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/**
 * @notice Robinhood fork: generalized ERC-20 `launchAndBuy` (AAPL) with both pool orientations.
 */
contract ScoopFactoryErc20InitialBuyForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

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

    event InitialBuyExecuted(
        address indexed token,
        address indexed deployer,
        address indexed quoteAsset,
        uint256 quoteAmountIn,
        uint256 tokensOut
    );

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

        vm.deal(deployer, 10 ether);
    }

    function test_launchAndBuyWithAaplCurrency0() public {
        bytes32 salt = _findSalt("A0Buy", "A0B", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);

        uint256 gasBefore = gasleft();
        (address token,,, uint256 lpId, PoolId poolId, uint256 bought) = _buyAapl("A0Buy", "A0B", salt, aaplIn, 1);
        console2.log("AAPL c0 launchAndBuy gas", gasBefore - gasleft());
        console2.log("AAPL c0 in", aaplIn);
        console2.log("AAPL c0 out", bought);

        assertTrue(token > AAPL_TOKEN);
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), 0);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), factory.getLaunch(token).liquidityLocker);

        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        (, uint256 fdv) = _reconstructFdv(rec, 18, priceOracle.getPriceUsd(AAPL_TOKEN));
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);

        (, int24 tickAfter,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        console2.logInt(rec.openingTick);
        console2.logInt(tickAfter);
        // AAPL is c0 → buy is zeroForOne → tick decreases
        assertTrue(tickAfter < rec.openingTick);
        poolId;
    }

    function test_launchAndBuyWithAaplCurrency1() public {
        bytes32 salt = _findSalt("A1Buy", "A1B", false);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);

        uint256 gasBefore = gasleft();
        (address token,,, uint256 lpId, PoolId poolId, uint256 bought) = _buyAapl("A1Buy", "A1B", salt, aaplIn, 1);
        console2.log("AAPL c1 launchAndBuy gas", gasBefore - gasleft());
        console2.log("AAPL c1 in", aaplIn);
        console2.log("AAPL c1 out", bought);

        assertTrue(token < AAPL_TOKEN);
        assertGt(bought, 0);
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), factory.getLaunch(token).liquidityLocker);

        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        (, int24 tickAfter,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        console2.logInt(rec.openingTick);
        console2.logInt(tickAfter);
        // AAPL is c1 → buy is oneForZero → tick increases
        assertTrue(tickAfter > rec.openingTick);
    }

    function test_aaplInitialBuyUsesExactInput() public {
        bytes32 salt = _findSalt("Exact", "EX", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);
        uint256 factoryBefore = IERC20(AAPL_TOKEN).balanceOf(address(factory));
        uint256 deployerBefore = IERC20(AAPL_TOKEN).balanceOf(deployer);
        assertEq(deployerBefore, aaplIn);
        assertEq(IERC20(AAPL_TOKEN).allowance(deployer, address(factory)), aaplIn);

        (,,,,, uint256 bought) = _buyAapl("Exact", "EX", salt, aaplIn, 1);
        assertGt(bought, 0);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), 0);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), factoryBefore);
    }

    function test_aaplInitialBuyCleansTemporaryApprovals() public {
        bytes32 salt = _findSalt("Appr", "APR", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);

        _buyAapl("Appr", "APR", salt, aaplIn, 1);

        assertEq(IERC20(AAPL_TOKEN).allowance(address(factory), PERMIT2_ADDR), 0);
        (uint160 p2Amt, uint48 p2Exp,) =
            IAllowanceTransfer(PERMIT2_ADDR).allowance(address(factory), AAPL_TOKEN, UNIVERSAL_ROUTER_ADDR);
        assertEq(p2Amt, 0);
        // expiration=1 is in the past → allowance unusable even if amount were nonzero
        assertTrue(p2Exp < block.timestamp);
    }

    function test_aaplInitialBuyRequiresNoQuoteLpPrincipal() public {
        bytes32 salt = _findSalt("NoLpQ", "NLQ", true);
        uint256 aaplIn = 0.05e18;
        _fundAndApprove(aaplIn);
        (address token,,,,, uint256 bought) = _buyAapl("NoLpQ", "NLQ", salt, aaplIn, 1);
        assertGt(bought, 0);
        // Opening FDV recorded at init (pre-buy economics); quote was not LP principal.
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        (, uint256 fdv) = _reconstructFdv(rec, 18, priceOracle.getPriceUsd(AAPL_TOKEN));
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
    }

    function test_aaplInitialBuyReturnsTokensBought() public {
        bytes32 salt = _findSalt("Ret", "RET", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);
        (address token,,,,, uint256 bought) = _buyAapl("Ret", "RET", salt, aaplIn, 1);
        assertEq(bought, IERC20(token).balanceOf(deployer));
        assertGt(bought, 0);
    }

    function test_aaplInitialBuyMovesPrice() public {
        bytes32 salt = _findSalt("Move", "MOV", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);
        (address token,,,, PoolId poolId,) = _buyAapl("Move", "MOV", salt, aaplIn, 1);
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        (uint160 sqrtAfter, int24 tickAfter,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertTrue(sqrtAfter != rec.openingSqrtPriceX96);
        assertTrue(tickAfter != rec.openingTick);
    }

    function test_aaplInitialBuyLeavesNoFactoryCustody() public {
        bytes32 salt = _findSalt("Cust", "CST", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);
        uint256 ethBefore = address(factory).balance;
        (address token,,,,,) = _buyAapl("Cust", "CST", salt, aaplIn, 1);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, ethBefore);
    }

    function test_aaplInitialBuyPreservesPreexistingFactoryQuoteBalance() public {
        uint256 seeded = 7e18;
        deal(AAPL_TOKEN, address(factory), seeded);

        bytes32 salt = _findSalt("Seed", "SED", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);

        _buyAapl("Seed", "SED", salt, aaplIn, 1);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), seeded);
    }

    function test_aaplInitialBuyMinOutRevertsAtomically() public {
        bytes32 salt = _findSalt("Slip", "SLP", true);
        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Slip",
            symbol: "SLP",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        uint256 aaplBefore = IERC20(AAPL_TOKEN).balanceOf(deployer);
        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, type(uint128).max);

        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), aaplBefore);
        assertFalse(factory.isScoopToken(address(0)));
    }

    function test_aaplInitialBuyInsufficientApprovalRevertsAtomically() public {
        bytes32 salt = _findSalt("NoAp", "NAP", true);
        uint256 aaplIn = 0.1e18;
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
        factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, 1);

        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), aaplBefore);
    }

    function test_aaplInitialBuyInsufficientBalanceRevertsAtomically() public {
        bytes32 salt = _findSalt("NoBal", "NBL", true);
        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn / 2);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "NoBal",
            symbol: "NBL",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        uint256 aaplBefore = IERC20(AAPL_TOKEN).balanceOf(deployer);
        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, 1);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), aaplBefore);
    }

    function test_aaplInitialBuyUnregisteredQuoteRevertsBeforePull() public {
        MockAggregatorV3 fake = new MockAggregatorV3(18);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Unreg",
            symbol: "UNR",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(fake),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(9001))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.QuoteNotRegistered.selector, address(fake)));
        factory.launchAndBuy{value: 0.0005 ether}(params, 1e18, 1);
    }

    function test_aaplInitialBuyDisabledQuoteRevertsBeforePull() public {
        vm.prank(quoteAuthority);
        quoteRegistry.setQuoteEnabled(AAPL_TOKEN, false);

        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);
        uint256 before = IERC20(AAPL_TOKEN).balanceOf(deployer);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Dis",
            symbol: "DIS",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(9002))
        });
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.QuoteNotEnabled.selector, AAPL_TOKEN));
        factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, 1);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), before);
    }

    function test_aaplInitialBuyMissingOracleRevertsBeforePull() public {
        address stock2 = address(new MockAggregatorV3(8));
        vm.prank(quoteAuthority);
        quoteRegistry.registerQuote(stock2, ScoopQuoteRegistry.QuoteType.Stock);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "NoOr",
            symbol: "NOR",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: stock2,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(9003))
        });
        // No pull possible without balance — but policy/oracle fails inside launch before pull
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedNotConfigured.selector, stock2));
        factory.launchAndBuy{value: 0.0005 ether}(params, 1e18, 1);
    }

    function test_aaplInitialBuyStaleOracleRevertsBeforePull() public {
        vm.prank(oracleAuthority);
        priceOracle.setMaxAge(AAPL_TOKEN, 1);

        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);
        uint256 before = IERC20(AAPL_TOKEN).balanceOf(deployer);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Stale",
            symbol: "ST",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(9004))
        });
        vm.prank(deployer);
        vm.expectRevert();
        factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, 1);
        assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), before);
    }

    function test_aaplInitialBuyUnexpectedEthReverts() public {
        bytes32 salt = _findSalt("EthX", "EXX", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "EthX",
            symbol: "EXX",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopFactory.IncorrectLaunchValue.selector, 0.0005 ether, 0.0005 ether + 1 wei)
        );
        factory.launchAndBuy{value: 0.0005 ether + 1 wei}(params, aaplIn, 1);
    }

    function test_multipleAaplInitialBuySizes() public {
        uint256 out01 = _buySize(_findSalt("S01", "S01", true), "S01", "S01", 0.01e18);
        uint256 out10 = _buySize(_findSalt("S10", "S10", true), "S10", "S10", 0.1e18);
        uint256 out50 = _buySize(_findSalt("S50", "S50", true), "S50", "S50", 0.5e18);

        assertGt(out01, 0);
        assertGt(out10, out01);
        assertGt(out50, out10);
        console2.log("AAPL out 0.01", out01);
        console2.log("AAPL out 0.1", out10);
        console2.log("AAPL out 0.5", out50);
    }

    function test_aaplRangeCapacity() public {
        uint256[6] memory sizes = [uint256(0.01e18), 0.1e18, 0.5e18, 1e18, 5e18, 20e18];
        string[6] memory names = ["CapA", "CapB", "CapC", "CapD", "CapE", "CapF"];
        uint256 largestOk;
        for (uint256 i; i < sizes.length; ++i) {
            bytes32 salt = _findSalt(names[i], "CAP", true);
            deal(AAPL_TOKEN, deployer, sizes[i]);
            vm.prank(deployer);
            IERC20(AAPL_TOKEN).approve(address(factory), sizes[i]);
            uint256 before = IERC20(AAPL_TOKEN).balanceOf(deployer);

            ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
                name: names[i],
                symbol: "CAP",
                creatorId: registry.walletCreatorId(walletCreator),
                quoteAsset: AAPL_TOKEN,
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: salt
            });

            vm.prank(deployer);
            try factory.launchAndBuy{value: 0.0005 ether}(params, sizes[i], 1) returns (
                address token, address, address, uint256, PoolId poolId, uint256 bought
            ) {
                (, int24 tick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
                console2.log("AAPL size ok", sizes[i]);
                console2.log("bought", bought);
                console2.logInt(factory.getLaunch(token).openingTick);
                console2.logInt(tick);
                largestOk = sizes[i];
            } catch {
                console2.log("AAPL size FAILED", sizes[i]);
                assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer), before);
                break;
            }
        }
        console2.log("AAPL largest successful initial buy", largestOk);
        assertGt(largestOk, 0);
    }

    function test_initialBuyEventUsesQuoteAsset() public {
        bytes32 salt = _findSalt("Evt", "EVT", true);
        uint256 aaplIn = 0.1e18;
        _fundAndApprove(aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Evt",
            symbol: "EVT",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, 1);

        bytes32 topic0 = keccak256("InitialBuyExecuted(address,address,address,uint256,uint256)");
        bool found;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length >= 4 && entries[i].topics[0] == topic0) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), token);
                assertEq(address(uint160(uint256(entries[i].topics[2]))), deployer);
                assertEq(address(uint160(uint256(entries[i].topics[3]))), AAPL_TOKEN);
                (uint256 qIn, uint256 tokensOut) = abi.decode(entries[i].data, (uint256, uint256));
                assertEq(qIn, aaplIn);
                assertEq(tokensOut, bought);
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_creatorAndDeployerAttributionUnchanged() public {
        bytes32 salt = _findSalt("Attr", "ATR", true);
        uint256 aaplIn = 0.2e18;
        _fundAndApprove(aaplIn);
        (address token, address feeDist, address locker, uint256 lpId,, uint256 bought) =
            _buyAapl("Attr", "ATR", salt, aaplIn, 1);

        assertEq(factory.getLaunch(token).deployer, deployer);
        assertEq(ScoopFeeDistributor(payable(feeDist)).deployer(), deployer);
        assertEq(rewards.sourceCreatorId(feeDist), registry.walletCreatorId(walletCreator));
        assertEq(IERC20(token).balanceOf(deployer), bought);
        assertEq(IERC20(token).balanceOf(walletCreator), 0);

        // Generate fees via another small buy is N/A; collect from initial buy fees
        ScoopLiquidityLocker(locker).collectFees(lpId);
        uint256 aaplFees = IERC20(AAPL_TOKEN).balanceOf(feeDist);
        if (aaplFees > 0) {
            uint256 depBefore = IERC20(AAPL_TOKEN).balanceOf(deployer);
            ScoopFeeDistributor(payable(feeDist)).distributeToken(AAPL_TOKEN);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(deployer) - depBefore, (aaplFees * 400) / 10_000);
            assertEq(
                rewards.claimableToken(registry.walletCreatorId(walletCreator), AAPL_TOKEN), (aaplFees * 7000) / 10_000
            );
        }
    }

    function test_noAdminSurface() public {
        (bool ownerOk,) = address(factory).call(abi.encodeWithSignature("owner()"));
        (bool rescueOk,) =
            address(factory).call(abi.encodeWithSignature("rescueTokens(address,uint256)", AAPL_TOKEN, 1));
        assertFalse(ownerOk);
        assertFalse(rescueOk);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _fundAndApprove(uint256 amount) internal {
        deal(AAPL_TOKEN, deployer, amount);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), amount);
    }

    function _buyAapl(string memory name, string memory symbol, bytes32 salt, uint256 aaplIn, uint256 minOut)
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId, uint256 bought)
    {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        return factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, minOut);
    }

    function _buySize(bytes32 salt, string memory name, string memory symbol, uint256 aaplIn)
        internal
        returns (uint256 bought)
    {
        _fundAndApprove(aaplIn);
        (,,,,, bought) = _buyAapl(name, symbol, salt, aaplIn, 1);
    }

    function _findSalt(string memory name, string memory symbol, bool tokenGreaterThanAapl)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = factory.TOKEN_DOMAIN();
        for (uint256 i = 1; i < 20_000; ++i) {
            // Scope salts by name/symbol so multi-launch tests never reuse fee-distributor CREATE2 salts.
            bytes32 userSalt = keccak256(abi.encode(name, symbol, i));
            bytes32 launchSalt = keccak256(abi.encode(deployer, userSalt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, domain));
            ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
            address predicted = tokenDeployer.predictTokenAddress(
                name,
                symbol,
                address(factory),
                deployer,
                address(factory),
                md.imageUri,
                md.description,
                ScoopLaunchMetadataHelpers.toSocials(md),
                tokenSalt
            );
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
            ? FullMath.mulDiv(
                FullMath.mulDiv(tokenUnits, FixedPoint96.Q96, rec.openingSqrtPriceX96),
                FixedPoint96.Q96,
                rec.openingSqrtPriceX96
            )
            : FullMath.mulDiv(
                FullMath.mulDiv(tokenUnits, rec.openingSqrtPriceX96, FixedPoint96.Q96),
                rec.openingSqrtPriceX96,
                FixedPoint96.Q96
            );
        uint256 quotePerToken1e18 = FullMath.mulDiv(quoteRaw, 1e18, quoteScale);
        tokenUsd = FullMath.mulDiv(quotePerToken1e18, quoteUsd, 1e18);
        fdv = tokenUsd * 1_000_000_000;
    }
}
