// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {IV4Router} from "v4-periphery/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {ScoopToken} from "./ScoopToken.sol";
import {ScoopTokenDeployer} from "./ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "./ScoopLaunchDeployer.sol";
import {ScoopCreatorRewards} from "./ScoopCreatorRewards.sol";
import {ScoopQuoteRegistry} from "./ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "./ScoopPriceOracle.sol";
import {ScoopLaunchMath} from "./libraries/ScoopLaunchMath.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title ScoopFactory
 * @notice Permissionless atomic launch orchestrator for SCOOP Protocol V1.
 * @dev Multi-quote launches against approved ScoopQuoteRegistry assets, priced via ScoopPriceOracle
 *      and ScoopLaunchMath to a fixed ~$5,000 opening FDV. LP is always one-sided launched-token
 *      principal (zero quote principal). `launchAndBuy` remains ETH-only (`quoteAsset == address(0)`).
 *
 *      Deployer attribution is always `msg.sender` (4% fee leg). Creator attribution is the
 *      pre-derived `creatorId` permanently bound via ScoopCreatorRewards source registration.
 *
 *      This factory is the immutable `sourceRegistrar` on ScoopCreatorRewards (via ScoopFactoryDeployer).
 */
contract ScoopFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    uint24 public constant LP_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    uint16 public constant CREATOR_REWARDS_BPS = 7000;
    uint16 public constant DEPLOYER_BPS = 400;
    uint16 public constant BUYBACK_BPS = 2000;
    uint16 public constant OPERATIONS_BPS = 600;

    bytes32 public constant TOKEN_DOMAIN = keccak256("SCOOP_TOKEN");
    bytes32 public constant LAUNCH_DOMAIN = keccak256("SCOOP_LAUNCH");

    /// @dev Universal Router Commands.V4_SWAP
    uint8 internal constant CMD_V4_SWAP = 0x10;

    error ZeroAddress();
    error ZeroCreatorId();
    error InvalidSourceRegistrar();
    error FactoryRetainedLpNft(uint256 tokenId);
    error ZeroInitialBuy();
    error InsufficientTokensOut(uint256 actual, uint256 minimum);
    error NativeRefundFailed();
    error QuoteNotRegistered(address quoteAsset);
    error QuoteNotEnabled(address quoteAsset);
    error UnsupportedQuoteDecimals(uint8 decimals);
    error InitialBuyOnlySupportedForNativeQuote();
    error QuotePrincipalNotZero(address quoteAsset, uint256 balance);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    IUniversalRouter public immutable universalRouter;
    ScoopTokenDeployer public immutable tokenDeployer;
    ScoopLaunchDeployer public immutable launchDeployer;
    ScoopCreatorRewards public immutable creatorRewards;
    ScoopQuoteRegistry public immutable quoteRegistry;
    ScoopPriceOracle public immutable priceOracle;
    address public immutable buybackVault;
    address public immutable operations;

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 creatorId;
        address quoteAsset;
        bytes32 salt;
    }

    struct Launch {
        address token;
        address deployer;
        bytes32 creatorId;
        address quoteAsset;
        address feeDistributor;
        address liquidityLocker;
        PoolId poolId;
        uint256 lpTokenId;
        uint160 openingSqrtPriceX96;
        int24 openingTick;
        int24 tickLower;
        int24 tickUpper;
        uint64 createdAt;
    }

    struct LaunchResult {
        address token;
        address feeDistributor;
        address liquidityLocker;
        uint256 lpTokenId;
        PoolId poolId;
        address quoteAsset;
        uint160 openingSqrtPriceX96;
        int24 openingTick;
        int24 tickLower;
        int24 tickUpper;
    }

    mapping(address token => Launch) public launches;

    event TokenLaunched(
        address indexed token,
        address indexed deployer,
        bytes32 indexed creatorId,
        address quoteAsset,
        address feeDistributor,
        address liquidityLocker,
        PoolId poolId,
        uint256 lpTokenId,
        uint160 openingSqrtPriceX96,
        int24 openingTick,
        int24 tickLower,
        int24 tickUpper,
        string name,
        string symbol
    );

    event InitialBuyExecuted(address indexed token, address indexed deployer, uint256 ethIn, uint256 tokensOut);

    constructor(
        address poolManager_,
        address positionManager_,
        address permit2_,
        address universalRouter_,
        address tokenDeployer_,
        address launchDeployer_,
        address creatorRewards_,
        address quoteRegistry_,
        address priceOracle_,
        address buybackVault_,
        address operations_
    ) {
        if (
            poolManager_ == address(0) || positionManager_ == address(0) || permit2_ == address(0)
                || universalRouter_ == address(0) || tokenDeployer_ == address(0) || launchDeployer_ == address(0)
                || creatorRewards_ == address(0) || quoteRegistry_ == address(0) || priceOracle_ == address(0)
                || buybackVault_ == address(0) || operations_ == address(0)
        ) {
            revert ZeroAddress();
        }

        if (ScoopCreatorRewards(creatorRewards_).sourceRegistrar() != address(this)) {
            revert InvalidSourceRegistrar();
        }

        poolManager = IPoolManager(poolManager_);
        positionManager = IPositionManager(positionManager_);
        permit2 = IAllowanceTransfer(permit2_);
        universalRouter = IUniversalRouter(universalRouter_);
        tokenDeployer = ScoopTokenDeployer(tokenDeployer_);
        launchDeployer = ScoopLaunchDeployer(launchDeployer_);
        creatorRewards = ScoopCreatorRewards(creatorRewards_);
        quoteRegistry = ScoopQuoteRegistry(quoteRegistry_);
        priceOracle = ScoopPriceOracle(priceOracle_);
        buybackVault = buybackVault_;
        operations = operations_;
    }

    /// @notice Atomically launch a quote/ScoopToken market with no initial purchase.
    function launch(LaunchParams calldata params)
        external
        nonReentrant
        returns (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId, PoolId poolId)
    {
        LaunchResult memory result = _launch(params);
        return (result.token, result.feeDistributor, result.liquidityLocker, result.lpTokenId, result.poolId);
    }

    /**
     * @notice Atomically launch then buy launched tokens with `msg.value` ETH.
     * @dev Native ETH quote only. ERC20 quotes must use `launch` then trade separately.
     */
    function launchAndBuy(LaunchParams calldata params, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (
            address token,
            address feeDistributor,
            address liquidityLocker,
            uint256 lpTokenId,
            PoolId poolId,
            uint256 tokensBought
        )
    {
        if (params.quoteAsset != address(0)) revert InitialBuyOnlySupportedForNativeQuote();
        if (msg.value == 0) revert ZeroInitialBuy();

        LaunchResult memory result = _launch(params);
        tokensBought = _executeInitialBuy(result.token, result.quoteAsset, msg.value, minTokensOut);

        emit InitialBuyExecuted(result.token, msg.sender, msg.value, tokensBought);

        return
            (result.token, result.feeDistributor, result.liquidityLocker, result.lpTokenId, result.poolId, tokensBought);
    }

    function _launch(LaunchParams calldata params) internal returns (LaunchResult memory result) {
        if (params.creatorId == bytes32(0)) revert ZeroCreatorId();
        _requireApprovedQuote(params.quoteAsset);

        (result.token, result.feeDistributor, result.liquidityLocker) = _deployLaunchContracts(params);
        result.quoteAsset = params.quoteAsset;

        creatorRewards.registerSource(result.feeDistributor, params.creatorId);

        uint8 quoteDecimals = _quoteDecimals(params.quoteAsset);
        uint256 quotePriceUsd = priceOracle.getPriceUsd(params.quoteAsset);

        ScoopLaunchMath.LaunchPricing memory pricing =
            ScoopLaunchMath.calculateLaunchPricing(result.token, params.quoteAsset, quoteDecimals, quotePriceUsd);

        result.openingSqrtPriceX96 = pricing.sqrtPriceX96;
        result.openingTick = pricing.openingTick;
        result.tickLower = pricing.tickLower;
        result.tickUpper = pricing.tickUpper;

        (result.lpTokenId, result.poolId) = _initPoolAndLockLiquidity(result, pricing);
        _finalizeLaunch(params, result);
    }

    function _requireApprovedQuote(address quoteAsset) internal view {
        if (!quoteRegistry.isRegistered(quoteAsset)) revert QuoteNotRegistered(quoteAsset);
        if (!quoteRegistry.isEnabled(quoteAsset)) revert QuoteNotEnabled(quoteAsset);
    }

    function _quoteDecimals(address quoteAsset) internal view returns (uint8 decimals_) {
        if (quoteAsset == address(0)) return 18;
        decimals_ = IERC20Metadata(quoteAsset).decimals();
        if (decimals_ > 18) revert UnsupportedQuoteDecimals(decimals_);
    }

    function _deployLaunchContracts(LaunchParams calldata params)
        internal
        returns (address token, address feeDistributor, address liquidityLocker)
    {
        bytes32 launchSalt = keccak256(abi.encode(msg.sender, params.salt));
        bytes32 tokenSalt = keccak256(abi.encode(launchSalt, TOKEN_DOMAIN));
        bytes32 launchDomainSalt = keccak256(abi.encode(launchSalt, LAUNCH_DOMAIN));

        token = tokenDeployer.deployToken(params.name, params.symbol, address(this), tokenSalt);

        (feeDistributor, liquidityLocker) = launchDeployer.deployLaunch(
            address(creatorRewards),
            msg.sender,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            launchDomainSalt
        );
    }

    function _initPoolAndLockLiquidity(LaunchResult memory result, ScoopLaunchMath.LaunchPricing memory pricing)
        internal
        returns (uint256 lpTokenId, PoolId poolId)
    {
        PoolKey memory key = _poolKey(result.token, result.quoteAsset);
        poolManager.initialize(key, pricing.sqrtPriceX96);
        lpTokenId = _mintOneSidedLiquidity(key, result.token, result.liquidityLocker, pricing);
        poolId = key.toId();

        if (IERC721(address(positionManager)).ownerOf(lpTokenId) != result.liquidityLocker) {
            revert FactoryRetainedLpNft(lpTokenId);
        }

        uint256 remaining = IERC20(result.token).balanceOf(address(this));
        if (remaining != 0) {
            IERC20(result.token).safeTransfer(address(0x000000000000000000000000000000000000dEaD), remaining);
        }

        // Factory must not retain quote principal from the launch path.
        if (result.quoteAsset != address(0)) {
            uint256 quoteBal = IERC20(result.quoteAsset).balanceOf(address(this));
            if (quoteBal != 0) revert QuotePrincipalNotZero(result.quoteAsset, quoteBal);
        }
    }

    function _finalizeLaunch(LaunchParams calldata params, LaunchResult memory result) internal {
        launches[result.token] = Launch({
            token: result.token,
            deployer: msg.sender,
            creatorId: params.creatorId,
            quoteAsset: result.quoteAsset,
            feeDistributor: result.feeDistributor,
            liquidityLocker: result.liquidityLocker,
            poolId: result.poolId,
            lpTokenId: result.lpTokenId,
            openingSqrtPriceX96: result.openingSqrtPriceX96,
            openingTick: result.openingTick,
            tickLower: result.tickLower,
            tickUpper: result.tickUpper,
            createdAt: uint64(block.timestamp)
        });

        _emitTokenLaunched(params.creatorId, params.name, params.symbol, result);
    }

    function _emitTokenLaunched(
        bytes32 creatorId,
        string calldata name,
        string calldata symbol,
        LaunchResult memory result
    ) internal {
        emit TokenLaunched(
            result.token,
            msg.sender,
            creatorId,
            result.quoteAsset,
            result.feeDistributor,
            result.liquidityLocker,
            result.poolId,
            result.lpTokenId,
            result.openingSqrtPriceX96,
            result.openingTick,
            result.tickLower,
            result.tickUpper,
            name,
            symbol
        );
    }

    /// @dev Exact-input ETH→token buy on the just-created pool; tokens forwarded to msg.sender.
    function _executeInitialBuy(address token, address quoteAsset, uint256 ethIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensBought)
    {
        address buyer = msg.sender;
        uint256 buyerBefore = IERC20(token).balanceOf(buyer);

        PoolKey memory key = _poolKey(token, quoteAsset);
        // Native ETH is always currency0 vs any ScoopToken.
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, true, uint128(ethIn), uint128(minTokensOut));

        universalRouter.execute{value: ethIn}(commands, inputs, block.timestamp + 60);

        uint256 factoryBal = IERC20(token).balanceOf(address(this));
        if (factoryBal != 0) {
            IERC20(token).safeTransfer(buyer, factoryBal);
        }

        tokensBought = IERC20(token).balanceOf(buyer) - buyerBefore;
        if (tokensBought < minTokensOut) revert InsufficientTokensOut(tokensBought, minTokensOut);

        uint256 leftoverEth = address(this).balance;
        if (leftoverEth != 0) {
            (bool ok,) = buyer.call{value: leftoverEth}("");
            if (!ok) revert NativeRefundFailed();
        }
    }

    function _encodeV4ExactInSingle(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
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
        Currency settleCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency takeCurrency = zeroForOne ? key.currency1 : key.currency0;
        params[1] = abi.encode(settleCurrency, uint256(amountIn));
        params[2] = abi.encode(takeCurrency, uint256(amountOutMinimum));
        return abi.encode(actions, params);
    }

    function isScoopToken(address token) external view returns (bool) {
        return launches[token].token != address(0);
    }

    function getLaunch(address token) external view returns (Launch memory) {
        return launches[token];
    }

    /// @dev Sort quote + launched token into Uniswap v4 PoolKey currency order.
    function _poolKey(address token, address quoteAsset) internal pure returns (PoolKey memory key) {
        Currency quote = Currency.wrap(quoteAsset);
        Currency scoop = Currency.wrap(token);
        Currency currency0;
        Currency currency1;
        if (quote < scoop) {
            currency0 = quote;
            currency1 = scoop;
        } else {
            currency0 = scoop;
            currency1 = quote;
        }

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _mintOneSidedLiquidity(
        PoolKey memory key,
        address token,
        address liquidityLocker,
        ScoopLaunchMath.LaunchPricing memory pricing
    ) internal returns (uint256 tokenId) {
        uint256 supply = ScoopToken(token).MAX_SUPPLY();

        IERC20(token).forceApprove(address(permit2), supply);
        permit2.approve(token, address(positionManager), uint160(supply), type(uint48).max);

        tokenId = positionManager.nextTokenId();

        (uint128 liquidity, uint128 amount0Max, uint128 amount1Max) = _liquidityParams(pricing, supply);

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            pricing.tickLower,
            pricing.tickUpper,
            uint256(liquidity),
            amount0Max,
            amount1Max,
            liquidityLocker,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        IERC20(token).forceApprove(address(permit2), 0);
    }

    function _liquidityParams(ScoopLaunchMath.LaunchPricing memory pricing, uint256 supply)
        internal
        pure
        returns (uint128 liquidity, uint128 amount0Max, uint128 amount1Max)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(pricing.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(pricing.tickUpper);
        if (pricing.launchedIsCurrency1) {
            liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, supply);
            amount1Max = uint128(supply);
        } else {
            liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, supply);
            amount0Max = uint128(supply);
        }
    }
}
