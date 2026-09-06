// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {Actions} from "v4-periphery/libraries/Actions.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {ActionConstants} from "v4-periphery/libraries/ActionConstants.sol";

import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @notice Phase 6C.1B fork proof: post-launch ETH -> USDG -> TOKEN in one Universal Router tx.
contract ScoopEthToUsdGRouteForkTest is Test {
    ScoopFactory constant FACTORY = ScoopFactory(0x15E874Bc667435ddbF2a67c0362701DC23C90833);
    ScoopQuoteRegistry constant QUOTE_REGISTRY = ScoopQuoteRegistry(0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD);
    ScoopPriceOracle constant PRICE_ORACLE = ScoopPriceOracle(0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12);
    ScoopCreatorRegistry constant CREATOR_REGISTRY = ScoopCreatorRegistry(0x608e117EdA28b65cDa473756a990B8246EAe62D2);
    address constant AUTHORITY = 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7;

    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address constant WETH_USDG_V3_500 = 0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a;

    uint48 constant USDG_MAX_AGE = 86_400;
    uint24 constant V3_FEE = 500;
    uint8 constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 constant CMD_SWEEP = 0x04;
    uint8 constant CMD_WRAP_ETH = 0x0b;
    uint8 constant CMD_V4_SWAP = 0x10;

    address internal creator;
    address internal ethBuyer;
    address internal testToken;
    PoolId internal testPoolId;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        require(block.chainid == 4663, "wrong chain");
        creator = makeAddr("routeCreator_FORK_ONLY");
        ethBuyer = makeAddr("ethOnlyBuyer_FORK_ONLY");
        vm.deal(creator, 5 ether);
        vm.deal(ethBuyer, 2 ether);
    }

    function test_live_routingInfrastructure() public view {
        assertGt(UNIVERSAL_ROUTER.code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertGt(WETH.code.length, 0);
        assertGt(WETH_USDG_V3_500.code.length, 0);
        assertEq(IERC20Metadata(WETH).symbol(), "WETH");
        assertEq(IERC20Metadata(USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(USDG).decimals(), 6);
        assertEq(address(FACTORY.universalRouter()), UNIVERSAL_ROUTER);
        assertEq(address(FACTORY.permit2()), PERMIT2);
    }

    function test_fork_launchTimeDevBuyRequiresUsdG() public {
        _configureUsdGOnFork();
        ScoopFactory.LaunchParams memory params = _params("NeedUsdG", "NUG", bytes32(uint256(801)));
        uint256 fee = FACTORY.LAUNCH_FEE();
        vm.startPrank(creator);
        IERC20(USDG).approve(address(FACTORY), 5e6);
        vm.expectRevert();
        FACTORY.launchAndBuy{value: fee}(params, 5e6, 1);
        vm.stopPrank();
        assertEq(IERC20(USDG).balanceOf(creator), 0);
    }

    function test_fork_ethOnlyBuyerSingleTxBuysTest() public {
        _configureUsdGOnFork();
        _launchTestUsdGWithCreatorBuy();

        assertGt(ethBuyer.balance, 0);
        assertEq(IERC20(USDG).balanceOf(ethBuyer), 0);
        assertEq(IERC20(testToken).balanceOf(ethBuyer), 0);

        uint256 ethIn = 0.02 ether;
        uint256 usdgQuoted = _quoteWethToUsdG(ethIn);
        assertGt(usdgQuoted, 0, "ETH->USDG quote failed");
        console2.log("quoted USDG for 0.02 ETH", usdgQuoted);

        uint256 factoryEthBefore = address(FACTORY).balance;
        uint256 factoryUsdGBefore = IERC20(USDG).balanceOf(address(FACTORY));

        vm.prank(ethBuyer);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: ethIn}(
            abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_IN, CMD_V4_SWAP, CMD_SWEEP),
            _routeInputs(ethIn, usdgQuoted),
            block.timestamp + 60
        );

        uint256 testBal = IERC20(testToken).balanceOf(ethBuyer);
        uint256 usdgBal = IERC20(USDG).balanceOf(ethBuyer);
        uint256 wethBal = IERC20(WETH).balanceOf(ethBuyer);
        console2.log("buyer TEST", testBal);
        console2.log("buyer USDG residual", usdgBal);
        console2.log("buyer WETH residual", wethBal);

        assertGt(testBal, 0, "buyer received no TEST");
        assertLe(usdgBal, 1e4, "unexpected USDG residual");
        assertEq(wethBal, 0, "unexpected WETH residual");

        ScoopFactory.Launch memory rec = FACTORY.getLaunch(testToken);
        assertEq(rec.quoteAsset, USDG);
        assertEq(PoolId.unwrap(rec.poolId), PoolId.unwrap(testPoolId));
        assertEq(address(FACTORY).balance, factoryEthBefore);
        assertEq(IERC20(USDG).balanceOf(address(FACTORY)), factoryUsdGBefore);
        assertEq(IERC20(testToken).balanceOf(address(FACTORY)), 0);
    }

    function _configureUsdGOnFork() internal {
        vm.startPrank(AUTHORITY);
        if (!PRICE_ORACLE.isConfigured(USDG)) {
            PRICE_ORACLE.configureFeed(USDG, USDG_USD_FEED, USDG_MAX_AGE);
        }
        if (!QUOTE_REGISTRY.isRegistered(USDG)) {
            QUOTE_REGISTRY.registerQuote(USDG, ScoopQuoteRegistry.QuoteType.Scoop);
        }
        vm.stopPrank();
        assertTrue(QUOTE_REGISTRY.isEnabled(USDG));
        assertTrue(PRICE_ORACLE.isEnabled(USDG));
    }

    function _launchTestUsdGWithCreatorBuy() internal {
        uint256 quoteIn = 25e6;
        deal(USDG, creator, quoteIn);
        ScoopFactory.LaunchParams memory params = _params("RouteTest", "RTEST", bytes32(uint256(802)));
        uint256 fee = FACTORY.LAUNCH_FEE();
        vm.startPrank(creator);
        IERC20(USDG).approve(address(FACTORY), quoteIn);
        (address token,,,,, uint256 bought) = FACTORY.launchAndBuy{value: fee}(params, quoteIn, 1);
        vm.stopPrank();
        assertGt(bought, 0);
        testToken = token;
        ScoopFactory.Launch memory rec = FACTORY.getLaunch(token);
        assertEq(rec.quoteAsset, USDG);
        testPoolId = rec.poolId;
        console2.log("TEST token", testToken);
        console2.log("creator bought", bought);
    }

    function _params(string memory name, string memory symbol, bytes32 salt)
        internal
        view
        returns (ScoopFactory.LaunchParams memory)
    {
        return ScoopFactory.LaunchParams({
            name: name,
            symbol: symbol,
            creatorId: CREATOR_REGISTRY.walletCreatorId(creator),
            quoteAsset: USDG,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
    }

    function _quoteWethToUsdG(uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,,,) = IQuoterV2(V3_QUOTER)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: WETH, tokenOut: USDG, amountIn: amountIn, fee: V3_FEE, sqrtPriceLimitX96: 0
                })
            );
    }

    function _routeInputs(uint256 ethIn, uint256 quotedUsdG) internal view returns (bytes[] memory inputs) {
        inputs = new bytes[](4);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, ethIn);

        // Robinhood UR V3: payerIsUser=false requires amountIn=CONTRACT_BALANCE (proven by V3Probe).
        uint256 minUsdG = quotedUsdG * 99 / 100;
        bytes memory v3Path = abi.encodePacked(WETH, V3_FEE, USDG);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE, minUsdG, v3Path, false);

        PoolKey memory key = _poolKey(testToken, USDG);
        bool zeroForOne = Currency.unwrap(key.currency0) == USDG;
        inputs[2] = _encodeV4ExactInFromRouter(key, zeroForOne, 1);
        inputs[3] = abi.encode(USDG, ethBuyer, uint256(0));
    }

    /// @dev Settle router-held USDG, swap OPEN_DELTA, take TEST to msg.sender.
    function _encodeV4ExactInFromRouter(PoolKey memory key, bool zeroForOne, uint128 minOut)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        Currency settleCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency takeCurrency = zeroForOne ? key.currency1 : key.currency0;
        params[0] = abi.encode(settleCurrency, ActionConstants.CONTRACT_BALANCE, false);
        params[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: ActionConstants.OPEN_DELTA,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[2] = abi.encode(takeCurrency, uint256(minOut));
        return abi.encode(actions, params);
    }

    function _poolKey(address token, address quoteAsset) internal pure returns (PoolKey memory key) {
        Currency quote = Currency.wrap(quoteAsset);
        Currency scoop = Currency.wrap(token);
        (Currency currency0, Currency currency1) = quote < scoop ? (quote, scoop) : (scoop, quote);
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 10_000, tickSpacing: 10, hooks: IHooks(address(0))
        });
    }
}
