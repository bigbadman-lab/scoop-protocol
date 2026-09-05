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

/**
 * @notice Milestone 4I.2: fork assertions for ScoopFactory max-range one-sided LP
 *         (TICK_SPACING=10, min/max usable band, $5k FDV, zero quote principal).
 */
contract ScoopFactoryMaxRangeLiquidityForkTest is Test {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

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
    int24 constant OLD_WIDTH = 200;

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

        vm.deal(deployer, 50 ether);
        vm.deal(trader, 100 ether);
    }

    // ──────────────────────────────────────────────
    // 1. Geometry
    // ──────────────────────────────────────────────

    function test_eth_maxRangeLaunchGeometry() public {
        (address token,, address locker, uint256 lpId, PoolId poolId) = _launchEth("MaxGeo", "MG", bytes32(uint256(1)));

        assertEq(factory.TICK_SPACING(), 10);
        assertEq(factory.LP_FEE(), 10_000);

        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        (PoolKey memory key, PositionInfo info) = IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);

        assertEq(key.tickSpacing, 10);
        assertEq(key.fee, 10_000);
        assertTrue(key.currency0 == CurrencyLibrary.ADDRESS_ZERO);
        assertEq(Currency.unwrap(key.currency1), token);

        // Single LP NFT / one position at launch.
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), locker);
        assertEq(IERC721(POSITION_MANAGER_ADDR).balanceOf(locker), 1);
        assertEq(info.tickLower(), rec.tickLower);
        assertEq(info.tickUpper(), rec.tickUpper);

        int24 minU = TickMath.minUsableTick(10);
        int24 expectedUpper = ScoopLaunchMath.floorToSpacing(rec.openingTick, 10);
        assertEq(rec.tickLower, minU);
        assertEq(rec.tickUpper, expectedUpper);
        assertTrue(rec.tickUpper <= rec.openingTick);

        int24 width = rec.tickUpper - rec.tickLower;
        assertGt(int256(width), int256(10));
        assertTrue(width != OLD_WIDTH);

        uint128 liq = IPositionManager(POSITION_MANAGER_ADDR).getPositionLiquidity(lpId);
        assertGt(liq, 0);
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(rec.tickLower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(rec.tickUpper);
        uint128 expectedLiq = LiquidityAmounts.getLiquidityForAmount1(sqrtL, sqrtU, ScoopToken(token).MAX_SUPPLY());
        assertEq(liq, expectedLiq);

        uint256 ethUsd = priceOracle.getPriceUsd(address(0));
        (, uint256 fdv) = _reconstructFdv(rec, 18, ethUsd);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);

        assertEq(address(factory).balance, 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        // Post-mint residual (if any) is burned to address(dead); locker/factory hold none.
        assertEq(IERC20(token).balanceOf(locker), 0);
        uint256 tokenDust = IERC20(token).balanceOf(address(0x000000000000000000000000000000000000dEaD));
        assertEq(ScoopToken(token).totalSupply(), ScoopToken(token).MAX_SUPPLY());

        (uint160 liveSqrt, int24 liveTick,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
        assertEq(liveSqrt, rec.openingSqrtPriceX96);

        console2.log("ETH max-range sqrt", rec.openingSqrtPriceX96);
        console2.logInt(rec.openingTick);
        console2.logInt(rec.tickLower);
        console2.logInt(rec.tickUpper);
        console2.logInt(width);
        console2.log("liquidity", liq);
        console2.log("token dust (dead)", tokenDust);
        console2.logInt(liveTick);
        console2.log("FDV", fdv);
    }

    // ──────────────────────────────────────────────
    // 2. Normal buys + sell
    // ──────────────────────────────────────────────

    function test_eth_normalBuysAndSell() public {
        (address token,,,, PoolId poolId) = _launchEth("Norm", "NRM", bytes32(uint256(2)));
        ScoopFactory.Launch memory rec = factory.getLaunch(token);

        uint256[5] memory sizes = [uint256(0.001 ether), 0.01 ether, 0.05 ether, 0.1 ether, 1 ether];
        int24 prevTick = rec.openingTick;

        for (uint256 i; i < sizes.length; ++i) {
            (, int24 tickBefore,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
            uint256 bought = _buyEth(token, sizes[i]);
            assertGt(bought, 0, "tokens out");

            (, int24 tickAfter,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
            // currency1 sell → zeroForOne → tick moves down
            assertLe(tickAfter, tickBefore);
            assertGe(tickAfter, rec.tickLower);
            assertLe(tickAfter, prevTick);
            prevTick = tickAfter;

            console2.log("buy ETH in", sizes[i]);
            console2.log("tokens out", bought);
            console2.logInt(tickAfter);
        }

        uint256 traderBal = IERC20(token).balanceOf(trader);
        uint256 sellAmt = traderBal / 10;
        assertGt(sellAmt, 0);
        _approveTraderToken(token);
        uint256 ethBack = _sellEth(token, sellAmt);
        assertGt(ethBack, 0);
        console2.log("sell ethOut", ethBack);
    }

    // ──────────────────────────────────────────────
    // 3. Large buys — inventory vs range
    // ──────────────────────────────────────────────

    function test_eth_largeBuys_1_5_20() public {
        // Fresh launch per size so each ladder rung starts at opening inventory.
        uint256[3] memory sizes = [uint256(1 ether), 5 ether, 20 ether];

        for (uint256 i; i < sizes.length; ++i) {
            bytes32 salt = bytes32(uint256(10 + i));
            (address token,,,, PoolId poolId) = _launchEth("Lg", "LG", salt);
            ScoopFactory.Launch memory rec = factory.getLaunch(token);

            (, int24 tickBefore,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);
            uint256 factoryEthBefore = address(factory).balance;
            uint256 bought = _buyEth(token, sizes[i]);
            (, int24 tickAfter,,) = IPoolManager(POOL_MANAGER_ADDR).getSlot0(poolId);

            int24 distToLower = tickAfter - rec.tickLower;
            uint256 supply = ScoopToken(token).MAX_SUPPLY();
            uint256 pct1e4 = bought * 10_000 / supply;

            console2.log("--- large buy ---");
            console2.log("quoteIn", sizes[i]);
            console2.log("tokensOut", bought);
            console2.logInt(tickBefore);
            console2.logInt(tickAfter);
            console2.logInt(distToLower);
            console2.log("inventory bps of 1B", pct1e4);
            console2.log("factory ETH", address(factory).balance);

            assertEq(address(factory).balance, factoryEthBefore);
            assertEq(address(factory).balance, 0);
            // Range-boundary exhaustion would pin at / below tickLower with free-fall risk.
            // Inventory may drain first; that is distinct from leaving the LP band.
            assertGe(tickAfter, rec.tickLower, "not range-boundary exhausted");
            if (bought >= supply - 1e18) {
                console2.log("note: inventory-limited (near-full supply sold)");
            } else {
                console2.log("note: inventory remaining inside max-range band");
            }
            assertGt(bought, 0);
        }
    }

    // ──────────────────────────────────────────────
    // 4. Oversized exact-input — no factory strand
    // ──────────────────────────────────────────────

    function test_eth_oversizedExactInput_noFactoryStrand() public {
        (address token,,,,) = _launchEth("Ovr", "OVR", bytes32(uint256(20)));
        assertEq(address(factory).balance, 0);

        uint256 bought = _buyEth(token, 20 ether);
        assertGt(bought, 0);
        assertEq(address(factory).balance, 0, "factory must not retain ETH after oversized UR buy");
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
    }

    // ──────────────────────────────────────────────
    // 5. AAPL both orientations
    // ──────────────────────────────────────────────

    function test_aapl_bothOrientations_maxRange() public {
        // currency1: token > AAPL → lower=min, upper=floor(opening)
        {
            bytes32 salt = _findSalt("AaplC1m", "AC1M", true);
            (address token,, address locker, uint256 lpId,) = _launchAapl("AaplC1m", "AC1M", salt);
            assertTrue(token > AAPL_TOKEN);

            ScoopFactory.Launch memory rec = factory.getLaunch(token);
            assertEq(rec.tickLower, TickMath.minUsableTick(10));
            assertEq(rec.tickUpper, ScoopLaunchMath.floorToSpacing(rec.openingTick, 10));
            assertTrue(rec.tickUpper <= rec.openingTick);
            assertGt(int256(rec.tickUpper - rec.tickLower), int256(10));

            (PoolKey memory key, PositionInfo info) =
                IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);
            assertEq(Currency.unwrap(key.currency0), AAPL_TOKEN);
            assertEq(Currency.unwrap(key.currency1), token);
            assertEq(key.tickSpacing, 10);
            assertEq(info.tickLower(), rec.tickLower);
            assertEq(info.tickUpper(), rec.tickUpper);
            assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), locker);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);

            (, uint256 fdv) = _reconstructFdv(rec, 18, priceOracle.getPriceUsd(AAPL_TOKEN));
            assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
            console2.log("AAPL c1 width", uint256(int256(rec.tickUpper - rec.tickLower)));
            console2.log("AAPL c1 FDV", fdv);
        }

        // currency0: token < AAPL → lower=ceil(opening+1), upper=max
        {
            bytes32 salt = _findSalt("AaplC0m", "AC0M", false);
            (address token,, address locker, uint256 lpId,) = _launchAapl("AaplC0m", "AC0M", salt);
            assertTrue(token < AAPL_TOKEN);

            ScoopFactory.Launch memory rec = factory.getLaunch(token);
            assertEq(rec.tickLower, ScoopLaunchMath.ceilToSpacing(rec.openingTick + 1, 10));
            assertEq(rec.tickUpper, TickMath.maxUsableTick(10));
            assertTrue(rec.tickLower > rec.openingTick);
            assertGt(int256(rec.tickUpper - rec.tickLower), int256(10));

            (PoolKey memory key, PositionInfo info) =
                IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);
            assertEq(Currency.unwrap(key.currency0), token);
            assertEq(Currency.unwrap(key.currency1), AAPL_TOKEN);
            assertEq(key.tickSpacing, 10);
            assertEq(info.tickLower(), rec.tickLower);
            assertEq(info.tickUpper(), rec.tickUpper);
            assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpId), locker);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);

            (, uint256 fdv) = _reconstructFdv(rec, 18, priceOracle.getPriceUsd(AAPL_TOKEN));
            assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);
            console2.log("AAPL c0 width", uint256(int256(rec.tickUpper - rec.tickLower)));
            console2.log("AAPL c0 FDV", fdv);
        }
    }

    // ──────────────────────────────────────────────
    // 6. launchAndBuy
    // ──────────────────────────────────────────────

    function test_launchAndBuy_nativeAndAapl() public {
        {
            ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
                name: "BuyEth",
                symbol: "BE",
                creatorId: registry.walletCreatorId(walletCreator),
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(30))
            });
            vm.prank(deployer);
            (address token,,,,, uint256 bought) =
                factory.launchAndBuy{value: 0.0005 ether + (0.01 ether)}(params, 0.01 ether, 1);
            assertGt(bought, 0);
            assertEq(IERC20(token).balanceOf(deployer), bought);
            assertEq(address(factory).balance, 0);

            ScoopFactory.Launch memory rec = factory.getLaunch(token);
            assertEq(rec.tickLower, TickMath.minUsableTick(10));
            assertGt(int256(rec.tickUpper - rec.tickLower), int256(OLD_WIDTH));
        }

        {
            bytes32 salt = _findSalt("BuyAapl", "BA", true);
            ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
                name: "BuyAapl",
                symbol: "BA",
                creatorId: registry.walletCreatorId(walletCreator),
                quoteAsset: AAPL_TOKEN,
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: salt
            });
            uint256 aaplIn = 0.1e18;
            deal(AAPL_TOKEN, deployer, aaplIn);
            vm.prank(deployer);
            IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

            vm.prank(deployer);
            (address token,,,,, uint256 bought) = factory.launchAndBuy{value: 0.0005 ether}(params, aaplIn, 1);
            assertGt(bought, 0);
            assertEq(IERC20(token).balanceOf(deployer), bought);
            assertEq(IERC20(AAPL_TOKEN).balanceOf(address(factory)), 0);
        }
    }

    // ──────────────────────────────────────────────
    // 7. Fee split + creator claim
    // ──────────────────────────────────────────────

    function test_feeSplit_andCreatorClaim() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId,) = factory.launch{
            value: 0.0005 ether
        }(
            ScoopFactory.LaunchParams({
                name: "Fee",
                symbol: "FEE",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(40))
            })
        );

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

        console2.log("70/4/20/6 ETH creator", cEth);
        console2.log("70/4/20/6 ETH deployer", dEth);
        console2.log("70/4/20/6 ETH buyback", bEth);
        console2.log("70/4/20/6 ETH operations", oEth);

        vm.prank(relayer);
        rewards.claimETH(creatorId, walletCreator);
        vm.prank(relayer);
        rewards.claimToken(creatorId, token, walletCreator);

        assertEq(walletCreator.balance, cEth);
        assertEq(IERC20(token).balanceOf(walletCreator), cTok);
        assertEq(relayer.balance, 0);
        assertEq(IERC20(token).balanceOf(relayer), 0);
    }

    // ──────────────────────────────────────────────
    // 8. Security / no custom geometry surface
    // ──────────────────────────────────────────────

    function test_securitySurface_noCustomGeometry() public {
        (bool ownerOk,) = address(factory).call(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(factory).call(abi.encodeWithSignature("pause()"));
        (bool setBuybackOk,) = address(factory).call(abi.encodeWithSignature("setBuybackVault(address)", trader));
        (bool rescueOk,) = address(factory).call(abi.encodeWithSignature("rescueETH(address)", trader));
        (bool setTickOk,) = address(factory).call(abi.encodeWithSignature("setTickSpacing(int24)", int24(60)));
        (bool setFeeOk,) = address(factory).call(abi.encodeWithSignature("setLpFee(uint24)", uint24(3000)));
        assertFalse(ownerOk);
        assertFalse(pauseOk);
        assertFalse(setBuybackOk);
        assertFalse(rescueOk);
        assertFalse(setTickOk);
        assertFalse(setFeeOk);

        assertEq(factory.TICK_SPACING(), 10);
        assertEq(factory.LP_FEE(), 10_000);

        // Compile-time proof: LaunchParams has no tick/sqrt fields — only name/symbol/creator/quote/metadata/salt.
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Sec",
            symbol: "SEC",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(50))
        });
        assertEq(params.quoteAsset, address(0));
        // Geometry is derived solely by ScoopLaunchMath inside launch().
        vm.prank(deployer);
        (address token,,,,) = factory.launch{value: 0.0005 ether}(params);
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        assertEq(rec.tickLower, TickMath.minUsableTick(factory.TICK_SPACING()));
        assertEq(rec.tickUpper, ScoopLaunchMath.floorToSpacing(rec.openingTick, factory.TICK_SPACING()));
    }

    // ──────────────────────────────────────────────
    // 9. Old vs new width
    // ──────────────────────────────────────────────

    function test_oldVsNew_widthComparison() public view {
        // Representative opening near $5k FDV ETH c1 (order-of-magnitude; exact tick is oracle-dependent).
        int24 opening = 200_130;
        int24 oldWidth = OLD_WIDTH;
        (int24 newLower, int24 newUpper) = ScoopLaunchMath.oneSidedLpTicks(opening, true);
        int24 newWidth = newUpper - newLower;

        assertEq(oldWidth, 200);
        assertEq(newLower, TickMath.minUsableTick(10));
        assertEq(newUpper, ScoopLaunchMath.floorToSpacing(opening, 10));
        assertGt(int256(newWidth), int256(oldWidth));
        assertGt(int256(newWidth), int256(100_000));

        console2.logInt(oldWidth);
        console2.logInt(newWidth);
        console2.logInt(newLower);
        console2.logInt(newUpper);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _launchEth(string memory name, string memory symbol, bytes32 salt)
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId)
    {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        return factory.launch{value: 0.0005 ether}(params);
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
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        return factory.launch{value: 0.0005 ether}(params);
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
