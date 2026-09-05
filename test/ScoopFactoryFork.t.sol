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
import {ScoopToken} from "../src/ScoopToken.sol";
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
 * @notice Robinhood fork: full ScoopFactory launch + trade + fee + claim lifecycle.
 */
contract ScoopFactoryForkTest is Test {
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
    address trader;
    address relayer;

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
        trader = makeAddr("trader");
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
        assertEq(address(factory.creatorRewards()), address(rewards));
        assertEq(address(factory.quoteRegistry()), address(quoteRegistry));
        assertEq(address(factory.priceOracle()), address(priceOracle));

        vm.deal(deployer, 1 ether);
        vm.deal(trader, 10 ether);
    }

    function test_factoryLaunch_walletCreator_endToEnd() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Scoop Launch",
            symbol: "LAUNCH",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(1))
        });

        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId, PoolId poolId) =
            factory.launch(params);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("launch() gas baseline", gasUsed);

        ScoopToken scoop = ScoopToken(token);
        assertEq(scoop.name(), "Scoop Launch");
        assertEq(scoop.symbol(), "LAUNCH");
        assertEq(scoop.totalSupply(), scoop.MAX_SUPPLY());
        assertEq(scoop.balanceOf(walletCreator), 0);
        assertEq(scoop.balanceOf(deployer), 0);
        assertEq(scoop.balanceOf(address(factory)), 0);

        assertTrue(factory.isScoopToken(token));
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        assertEq(rec.token, token);
        assertEq(rec.deployer, deployer);
        assertEq(rec.creatorId, creatorId);
        assertEq(rec.feeDistributor, feeDistributor);
        assertEq(rec.liquidityLocker, liquidityLocker);
        assertEq(PoolId.unwrap(rec.poolId), PoolId.unwrap(poolId));
        assertEq(rec.lpTokenId, lpTokenId);

        ScoopFeeDistributor distributor = ScoopFeeDistributor(payable(feeDistributor));
        assertEq(distributor.creatorRewards(), address(rewards));
        assertEq(distributor.deployer(), deployer);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.creatorRewardsBps(), 7000);
        assertEq(distributor.deployerBps(), 400);
        assertEq(distributor.buybackBps(), 2000);
        assertEq(distributor.operationsBps(), 600);
        assertEq(rewards.sourceCreatorId(feeDistributor), creatorId);

        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(lpTokenId), liquidityLocker);
        assertGt(IPositionManager(POSITION_MANAGER_ADDR).getPositionLiquidity(lpTokenId), 0);

        // Currency0 is native ETH.
        (PoolKey memory key,) = IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpTokenId);
        assertTrue(key.currency0 == CurrencyLibrary.ADDRESS_ZERO);
        assertEq(Currency.unwrap(key.currency1), token);

        uint256 bought = _buy(token, 0.02 ether);
        assertGt(bought, 0);
        console2.log("post-launch buy scoopOut", bought);

        _approveTraderToken(token);
        uint256 ethBack = _sell(token, bought / 2);
        assertGt(ethBack, 0);
        console2.log("post-launch sell ethOut", ethBack);
    }

    function test_walletCreator_feeDistributeAndClaim() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        vm.prank(deployer);
        (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId,) = factory.launch(
            ScoopFactory.LaunchParams({
                name: "W",
                symbol: "W",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(2))
            })
        );

        uint256 deployerEthBefore = deployer.balance;
        _generateFees(token);
        ScoopLiquidityLocker(liquidityLocker).collectFees(lpTokenId);

        uint256 ethFees = feeDistributor.balance;
        uint256 tokFees = IERC20(token).balanceOf(feeDistributor);
        assertGt(ethFees, 0);
        assertGt(tokFees, 0);

        ScoopFeeDistributor(payable(feeDistributor)).distributeETH();
        ScoopFeeDistributor(payable(feeDistributor)).distributeToken(token);

        _assertV1Split(creatorId, token, ethFees, tokFees, deployerEthBefore);

        vm.prank(relayer);
        rewards.claimETH(creatorId, walletCreator);
        vm.prank(relayer);
        rewards.claimToken(creatorId, token, walletCreator);

        assertEq(walletCreator.balance, (ethFees * 7000) / 10_000);
        assertEq(IERC20(token).balanceOf(walletCreator), (tokFees * 7000) / 10_000);
        assertEq(relayer.balance, 0);
        assertEq(IERC20(token).balanceOf(relayer), 0);
        assertEq(deployer.balance - deployerEthBefore, (ethFees * 400) / 10_000);
    }

    function _assertV1Split(
        bytes32 creatorId,
        address token,
        uint256 ethFees,
        uint256 tokFees,
        uint256 deployerEthBefore
    ) internal view {
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
        assertEq(walletCreator.balance, 0);
        assertEq(IERC20(token).balanceOf(walletCreator), 0);

        console2.log("70/4/20/6 ETH creator", cEth);
        console2.log("70/4/20/6 ETH deployer", dEth);
        console2.log("70/4/20/6 ETH buyback", bEth);
        console2.log("70/4/20/6 ETH operations", oEth);
    }

    function test_xCreator_unclaimedThenVerifiedClaim() public {
        uint256 xUser = 555001;
        bytes32 creatorId = registry.xCreatorId(xUser);

        vm.prank(deployer);
        (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId,) = factory.launch(
            ScoopFactory.LaunchParams({
                name: "XTok",
                symbol: "X",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: bytes32(uint256(3))
            })
        );

        assertEq(rewards.sourceCreatorId(feeDistributor), creatorId);
        assertFalse(registry.isXClaimed(xUser));

        _generateFees(token);

        ScoopLiquidityLocker(liquidityLocker).collectFees(lpTokenId);
        uint256 ethFees = feeDistributor.balance;
        assertGt(ethFees, 0);
        ScoopFeeDistributor(payable(feeDistributor)).distributeETH();

        uint256 credited = rewards.claimableETH(creatorId);
        assertEq(credited, (ethFees * 7000) / 10_000);

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(creatorId, walletCreator);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(xUser, walletCreator, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, digest);
        registry.claimXIdentity(xUser, walletCreator, deadline, abi.encodePacked(r, s, v));

        uint256 beforeBal = walletCreator.balance;
        vm.prank(relayer);
        rewards.claimETH(creatorId, address(0));
        assertEq(walletCreator.balance, beforeBal + credited);
    }

    function test_deployerAttribution_msgSenderAndSaltIsolation() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        bytes32 userSalt = bytes32(uint256(42));

        address deployerB = makeAddr("launchDeployerB");
        vm.deal(deployerB, 1 ether);

        vm.prank(deployer);
        (address tokenA,,,,) = factory.launch(
            ScoopFactory.LaunchParams({
                name: "A",
                symbol: "A",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: userSalt
            })
        );

        vm.prank(deployerB);
        (address tokenB, address distributorB,,,) = factory.launch(
            ScoopFactory.LaunchParams({
                name: "B",
                symbol: "B",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
                salt: userSalt
            })
        );

        assertTrue(tokenA != tokenB);
        assertEq(ScoopFeeDistributor(payable(factory.getLaunch(tokenA).feeDistributor)).deployer(), deployer);
        assertEq(ScoopFeeDistributor(payable(distributorB)).deployer(), deployerB);
    }

    function test_duplicateSaltSameDeployerReverts() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Dup",
            symbol: "DUP",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(9))
        });

        vm.prank(deployer);
        factory.launch(params);

        vm.prank(deployer);
        vm.expectRevert();
        factory.launch(params);
    }

    function test_zeroCreatorIdRevertsAtomically() public {
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Z",
            symbol: "Z",
            creatorId: bytes32(0),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(8))
        });

        vm.prank(deployer);
        vm.expectRevert(ScoopFactory.ZeroCreatorId.selector);
        factory.launch(params);
    }

    function test_launchEmitsTokenLaunched() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Evt",
            symbol: "EVT",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(11))
        });

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,) = factory.launch(params);

        bytes32 topic0 = keccak256(
            "TokenLaunched(address,address,bytes32,address,address,address,bytes32,uint256,uint160,int24,int24,int24,string,string)"
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics.length >= 4 && entries[i].topics[0] == topic0) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), token);
                assertEq(address(uint160(uint256(entries[i].topics[2]))), deployer);
                assertEq(entries[i].topics[3], creatorId);
                found = true;
                break;
            }
        }
        assertTrue(found);
    }

    function test_noOwnerAdminSurface() public {
        (bool ownerOk,) = address(factory).call(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(factory).call(abi.encodeWithSignature("pause()"));
        (bool setBuybackOk,) = address(factory).call(abi.encodeWithSignature("setBuybackVault(address)", trader));
        (bool rescueOk,) = address(factory).call(abi.encodeWithSignature("rescueETH(address)", trader));
        assertFalse(ownerOk);
        assertFalse(pauseOk);
        assertFalse(setBuybackOk);
        assertFalse(rescueOk);
    }

    function test_sourceRegistrarIsFactory() public view {
        assertEq(rewards.sourceRegistrar(), address(factory));
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _poolKey(address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 10_000,
            tickSpacing: 200,
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
