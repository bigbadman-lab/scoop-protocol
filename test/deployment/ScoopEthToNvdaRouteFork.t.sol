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

/// @notice Phase 6C.4 fork proof: post-launch ETH -> NVDA -> TOKEN in one Universal Router tx.
contract ScoopEthToNvdaRouteForkTest is Test {
    ScoopFactory constant FACTORY = ScoopFactory(0x15E874Bc667435ddbF2a67c0362701DC23C90833);
    ScoopQuoteRegistry constant QUOTE_REGISTRY = ScoopQuoteRegistry(0x7e34424D65e5042Ac82cd036Fa63F3E841349eCD);
    ScoopPriceOracle constant PRICE_ORACLE = ScoopPriceOracle(0xc818e890AE8dBE0CcD1Bf9169Adb19D578867f12);
    ScoopCreatorRegistry constant CREATOR_REGISTRY = ScoopCreatorRegistry(0x608e117EdA28b65cDa473756a990B8246EAe62D2);
    address constant AUTHORITY = 0x54dCe3F53bbe3fBa3d1035E045a8a4de850eDcE7;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    

    uint48 constant STOCK_MAX_AGE = 345_600;
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
                assertEq(IERC20Metadata(WETH).symbol(), "WETH");
        assertEq(IERC20Metadata(NVDA).symbol(), "NVDA");
        assertEq(IERC20Metadata(NVDA).decimals(), 18);
        assertEq(address(FACTORY.universalRouter()), UNIVERSAL_ROUTER);
        assertEq(address(FACTORY.permit2()), PERMIT2);
    }

    function test_fork_launchTimeDevBuyRequiresNvda() public {
        _configureNvdaOnFork();
        ScoopFactory.LaunchParams memory params = _params("NeedNvda", "NUG", bytes32(uint256(801)));
        uint256 fee = FACTORY.LAUNCH_FEE();
        vm.startPrank(creator);
        IERC20(NVDA).approve(address(FACTORY), 0.1e18);
        vm.expectRevert();
        FACTORY.launchAndBuy{value: fee}(params, 0.1e18, 1);
        vm.stopPrank();
        assertEq(IERC20(NVDA).balanceOf(creator), 0);
    }

    function test_fork_ethOnlyBuyerSingleTxBuysTest() public {
        _configureNvdaOnFork();
        _launchTestNvdaWithCreatorBuy();

        assertGt(ethBuyer.balance, 0);
        assertEq(IERC20(NVDA).balanceOf(ethBuyer), 0);
        assertEq(IERC20(testToken).balanceOf(ethBuyer), 0);

        uint256 ethIn = 0.02 ether;
        uint256 nvdaQuoted = _quoteWethToNvda(ethIn);
        assertGt(nvdaQuoted, 0, "ETH->NVDA quote failed");
        console2.log("quoted NVDA for 0.02 ETH", nvdaQuoted);

        uint256 factoryEthBefore = address(FACTORY).balance;
        uint256 factoryNvdaBefore = IERC20(NVDA).balanceOf(address(FACTORY));

        vm.prank(ethBuyer);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: ethIn}(
            abi.encodePacked(CMD_WRAP_ETH, CMD_V3_SWAP_EXACT_IN, CMD_V4_SWAP, CMD_SWEEP),
            _routeInputs(ethIn, nvdaQuoted),
            block.timestamp + 60
        );

        uint256 testBal = IERC20(testToken).balanceOf(ethBuyer);
        uint256 nvdaBal = IERC20(NVDA).balanceOf(ethBuyer);
        uint256 wethBal = IERC20(WETH).balanceOf(ethBuyer);
        console2.log("buyer TEST", testBal);
        console2.log("buyer NVDA residual", nvdaBal);
        console2.log("buyer WETH residual", wethBal);

        assertGt(testBal, 0, "buyer received no TEST");
        assertLe(nvdaBal, 1e12, "unexpected NVDA residual");
        assertEq(wethBal, 0, "unexpected WETH residual");

        ScoopFactory.Launch memory rec = FACTORY.getLaunch(testToken);
        assertEq(rec.quoteAsset, NVDA);
        assertEq(PoolId.unwrap(rec.poolId), PoolId.unwrap(testPoolId));
        assertEq(address(FACTORY).balance, factoryEthBefore);
        assertEq(IERC20(NVDA).balanceOf(address(FACTORY)), factoryNvdaBefore);
        assertEq(IERC20(testToken).balanceOf(address(FACTORY)), 0);
    }

    function _configureNvdaOnFork() internal {
        vm.startPrank(AUTHORITY);
        if (!PRICE_ORACLE.isConfigured(NVDA)) {
            PRICE_ORACLE.configureFeed(NVDA, NVDA_USD_FEED, STOCK_MAX_AGE);
        }
        if (!QUOTE_REGISTRY.isRegistered(NVDA)) {
            QUOTE_REGISTRY.registerQuote(NVDA, ScoopQuoteRegistry.QuoteType.Stock);
        }
        vm.stopPrank();
        assertTrue(QUOTE_REGISTRY.isEnabled(NVDA));
        assertTrue(PRICE_ORACLE.isEnabled(NVDA));
    }

    function _launchTestNvdaWithCreatorBuy() internal {
        uint256 quoteIn = 0.1e18;
        deal(NVDA, creator, quoteIn);
        ScoopFactory.LaunchParams memory params = _params("RouteTest", "RTEST", bytes32(uint256(802)));
        uint256 fee = FACTORY.LAUNCH_FEE();
        vm.startPrank(creator);
        IERC20(NVDA).approve(address(FACTORY), quoteIn);
        (address token,,,,, uint256 bought) = FACTORY.launchAndBuy{value: fee}(params, quoteIn, 1);
        vm.stopPrank();
        assertGt(bought, 0);
        testToken = token;
        ScoopFactory.Launch memory rec = FACTORY.getLaunch(token);
        assertEq(rec.quoteAsset, NVDA);
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
            quoteAsset: NVDA,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
    }

    function _quoteWethToNvda(uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,,,) = IQuoterV2(V3_QUOTER)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: WETH, tokenOut: NVDA, amountIn: amountIn, fee: V3_FEE, sqrtPriceLimitX96: 0
                })
            );
    }

    function _routeInputs(uint256 ethIn, uint256 quotedNvda) internal view returns (bytes[] memory inputs) {
        inputs = new bytes[](4);
        inputs[0] = abi.encode(ActionConstants.ADDRESS_THIS, ethIn);

        // Robinhood UR V3: payerIsUser=false requires amountIn=CONTRACT_BALANCE (proven by V3Probe).
        uint256 minNvda = quotedNvda * 99 / 100;
        bytes memory v3Path = abi.encodePacked(WETH, V3_FEE, NVDA);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, ActionConstants.CONTRACT_BALANCE, minNvda, v3Path, false);

        PoolKey memory key = _poolKey(testToken, NVDA);
        bool zeroForOne = Currency.unwrap(key.currency0) == NVDA;
        inputs[2] = _encodeV4ExactInFromRouter(key, zeroForOne, 1);
        inputs[3] = abi.encode(NVDA, ethBuyer, uint256(0));
    }

    /// @dev Settle router-held NVDA, swap OPEN_DELTA, take TEST to msg.sender.
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
