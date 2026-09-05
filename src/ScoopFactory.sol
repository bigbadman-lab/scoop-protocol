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
 *      principal (zero quote principal). `launchAndBuy` supports native ETH and approved ERC-20
 *      quotes via exact-input Universal Router swaps (conventional ERC-20 approve UX; no Permit2 sigs).
 *
 *      Presentation metadata (`LaunchMetadata`) is validated and emitted via `ScoopTokenCreated` for
 *      terminal/indexer discovery. It is NOT stored in Factory state and does not affect economics.
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
    error IncorrectNativeValue(uint256 expected, uint256 actual);
    error UnexpectedNativeValue();
    error UnsupportedTransferBehavior();
    error InsufficientTokensOut(uint256 actual, uint256 minimum);
    error NativeRefundFailed();
    error QuoteNotRegistered(address quoteAsset);
    error QuoteNotEnabled(address quoteAsset);
    error UnsupportedQuoteDecimals(uint8 decimals);
    error QuotePrincipalNotZero(address quoteAsset, uint256 delta);
    error EmptyDescription();
    error DescriptionTooLong(uint256 length);
    error ExternalUrlTooLong(uint256 length);
    error EmptyImageUri();
    error ImageUriTooLong(uint256 length);
    error InvalidImageUriPrefix();

    /// @dev Presentation metadata byte bounds (not Unicode grapheme counts).
    uint256 public constant MAX_DESCRIPTION_BYTES = 280;
    uint256 public constant MAX_EXTERNAL_URL_BYTES = 256;
    uint256 public constant MAX_IMAGE_URI_BYTES = 128;

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

    struct LaunchMetadata {
        string description;
        string externalUrl;
        string imageUri;
    }

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 creatorId;
        address quoteAsset;
        LaunchMetadata metadata;
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

    /// @notice Terminal/indexer discovery: associates deployed ScoopToken with presentation metadata.
    /// @dev Emitted only after the launch is fully established. Not stored in Factory state.
    event ScoopTokenCreated(address indexed token, string description, string externalUrl, string imageUri);

    event InitialBuyExecuted(
        address indexed token,
        address indexed deployer,
        address indexed quoteAsset,
        uint256 quoteAmountIn,
        uint256 tokensOut
    );

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
     * @notice Atomically launch then buy launched tokens with quote asset.
     * @dev Native: `quoteAsset == address(0)` and `msg.value == quoteAmountIn`.
     *      ERC-20: `msg.value == 0`; Factory pulls `quoteAmountIn` from `msg.sender` after launch
     *      validation (policy/oracle) succeeds, then swaps via Permit2 → Universal Router.
     *      Fee-on-transfer quotes are rejected (`actualReceived` must equal `quoteAmountIn`).
     */
    function launchAndBuy(LaunchParams calldata params, uint256 quoteAmountIn, uint256 minTokensOut)
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
        if (quoteAmountIn == 0) revert ZeroInitialBuy();
        if (params.quoteAsset == address(0)) {
            if (msg.value != quoteAmountIn) revert IncorrectNativeValue(quoteAmountIn, msg.value);
        } else if (msg.value != 0) {
            revert UnexpectedNativeValue();
        }

        // Launch validates quote policy + oracle before any ERC-20 pull.
        LaunchResult memory result = _launch(params);

        if (params.quoteAsset != address(0)) {
            _pullExactQuote(params.quoteAsset, quoteAmountIn);
        }

        tokensBought = _executeInitialBuy(result.token, result.quoteAsset, quoteAmountIn, minTokensOut);

        emit InitialBuyExecuted(result.token, msg.sender, result.quoteAsset, quoteAmountIn, tokensBought);

        return
            (result.token, result.feeDistributor, result.liquidityLocker, result.lpTokenId, result.poolId, tokensBought);
    }

    function _launch(LaunchParams calldata params) internal returns (LaunchResult memory result) {
        if (params.creatorId == bytes32(0)) revert ZeroCreatorId();
        _validateMetadata(params.metadata);
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

    /// @dev Presentation-only validation. Opaque byte bounds; no URL/CID parsing beyond `ipfs://` prefix.
    function _validateMetadata(LaunchMetadata calldata metadata) internal pure {
        uint256 descLen = bytes(metadata.description).length;
        if (descLen == 0) revert EmptyDescription();
        if (descLen > MAX_DESCRIPTION_BYTES) revert DescriptionTooLong(descLen);

        uint256 urlLen = bytes(metadata.externalUrl).length;
        if (urlLen > MAX_EXTERNAL_URL_BYTES) revert ExternalUrlTooLong(urlLen);

        bytes memory image = bytes(metadata.imageUri);
        uint256 imageLen = image.length;
        if (imageLen == 0) revert EmptyImageUri();
        if (imageLen > MAX_IMAGE_URI_BYTES) revert ImageUriTooLong(imageLen);
        if (!_hasIpfsPrefix(image)) revert InvalidImageUriPrefix();
    }

    function _hasIpfsPrefix(bytes memory imageUri) internal pure returns (bool) {
        // Literal ASCII `ipfs://` (7 bytes). Case-sensitive; `IPFS://` rejected.
        if (imageUri.length < 7) return false;
        return imageUri[0] == 0x69 // i
            && imageUri[1] == 0x70 // p
            && imageUri[2] == 0x66 // f
            && imageUri[3] == 0x73 // s
            && imageUri[4] == 0x3a // :
            && imageUri[5] == 0x2f // /
            && imageUri[6] == 0x2f; // /
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
        // Preserve any pre-existing quote balance; LP must not consume or produce quote principal.
        uint256 quoteBalBefore;
        if (result.quoteAsset != address(0)) {
            quoteBalBefore = IERC20(result.quoteAsset).balanceOf(address(this));
        }

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

        if (result.quoteAsset != address(0)) {
            uint256 quoteBalAfter = IERC20(result.quoteAsset).balanceOf(address(this));
            if (quoteBalAfter != quoteBalBefore) {
                revert QuotePrincipalNotZero(
                    result.quoteAsset,
                    quoteBalAfter > quoteBalBefore ? quoteBalAfter - quoteBalBefore : quoteBalBefore - quoteBalAfter
                );
            }
        }
    }

    /// @dev Exact pull; rejects fee-on-transfer / rebasing shortfalls.
    function _pullExactQuote(address quoteAsset, uint256 quoteAmountIn) internal {
        uint256 before = IERC20(quoteAsset).balanceOf(address(this));
        IERC20(quoteAsset).safeTransferFrom(msg.sender, address(this), quoteAmountIn);
        uint256 received = IERC20(quoteAsset).balanceOf(address(this)) - before;
        if (received != quoteAmountIn) revert UnsupportedTransferBehavior();
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

        // Discovery event first, then protocol TokenLaunched. Same token address is the join key.
        emit ScoopTokenCreated(
            result.token, params.metadata.description, params.metadata.externalUrl, params.metadata.imageUri
        );
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

    /// @dev Exact-input quote→token buy; purchased ScoopToken forwarded to msg.sender.
    function _executeInitialBuy(address token, address quoteAsset, uint256 quoteAmountIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensBought)
    {
        address buyer = msg.sender;
        uint256 buyerBefore = IERC20(token).balanceOf(buyer);
        uint256 quoteBaseline;
        if (quoteAsset != address(0)) {
            // Balance includes the exact amount just pulled for this buy.
            quoteBaseline = IERC20(quoteAsset).balanceOf(address(this)) - quoteAmountIn;
        }

        PoolKey memory key = _poolKey(token, quoteAsset);
        // Economic action is always quote → launched token.
        bool zeroForOne = Currency.unwrap(key.currency0) == quoteAsset;

        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, zeroForOne, uint128(quoteAmountIn), uint128(minTokensOut));

        if (quoteAsset == address(0)) {
            universalRouter.execute{value: quoteAmountIn}(commands, inputs, block.timestamp + 60);
        } else {
            _approveQuoteForRouter(quoteAsset, quoteAmountIn);
            universalRouter.execute(commands, inputs, block.timestamp + 60);
            _clearQuoteApprovals(quoteAsset);
        }

        uint256 factoryBal = IERC20(token).balanceOf(address(this));
        if (factoryBal != 0) {
            IERC20(token).safeTransfer(buyer, factoryBal);
        }

        tokensBought = IERC20(token).balanceOf(buyer) - buyerBefore;
        if (tokensBought < minTokensOut) revert InsufficientTokensOut(tokensBought, minTokensOut);

        if (quoteAsset == address(0)) {
            uint256 leftoverEth = address(this).balance;
            if (leftoverEth != 0) {
                (bool ok,) = buyer.call{value: leftoverEth}("");
                if (!ok) revert NativeRefundFailed();
            }
        } else if (IERC20(quoteAsset).balanceOf(address(this)) != quoteBaseline) {
            // Exact-input must consume the pulled amount; never spend pre-existing Factory quote.
            revert UnsupportedTransferBehavior();
        }
    }

    function _approveQuoteForRouter(address quoteAsset, uint256 quoteAmountIn) internal {
        IERC20(quoteAsset).forceApprove(address(permit2), quoteAmountIn);
        permit2.approve(quoteAsset, address(universalRouter), uint160(quoteAmountIn), uint48(block.timestamp + 60));
    }

    function _clearQuoteApprovals(address quoteAsset) internal {
        IERC20(quoteAsset).forceApprove(address(permit2), 0);
        // Permit2 treats expiration==0 as `block.timestamp` (same-block only). Use amount=0 and an
        // already-expired timestamp so residual Universal Router authority is unusable.
        permit2.approve(quoteAsset, address(universalRouter), 0, 1);
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
