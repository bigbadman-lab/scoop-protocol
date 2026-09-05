// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title ScoopFactory
 * @notice Permissionless atomic launch orchestrator for SCOOP Protocol V1 (ETH / ScoopToken).
 * @dev `launch` creates a market with no initial purchase. `launchAndBuy` creates the same market
 *      then executes a real Uniswap v4 exact-input ETH→token buy for `msg.sender` (the deployer)
 *      through Universal Router — subject to the standard 1% LP fee. No free allocation.
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

    /// @dev One-sided amount1 range when currency0 = native ETH and currency1 = ScoopToken.
    int24 public constant TICK_LOWER = -400;
    int24 public constant TICK_UPPER = -200;

    bytes32 public constant TOKEN_DOMAIN = keccak256("SCOOP_TOKEN");
    bytes32 public constant LAUNCH_DOMAIN = keccak256("SCOOP_LAUNCH");

    /// @dev Universal Router Commands.V4_SWAP
    uint8 internal constant CMD_V4_SWAP = 0x10;

    error ZeroAddress();
    error ZeroCreatorId();
    error InvalidSourceRegistrar();
    error UnexpectedCurrencyOrder();
    error FactoryRetainedLpNft(uint256 tokenId);
    error ZeroInitialBuy();
    error InsufficientTokensOut(uint256 actual, uint256 minimum);
    error NativeRefundFailed();

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    IUniversalRouter public immutable universalRouter;
    ScoopTokenDeployer public immutable tokenDeployer;
    ScoopLaunchDeployer public immutable launchDeployer;
    ScoopCreatorRewards public immutable creatorRewards;
    address public immutable buybackVault;
    address public immutable operations;

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 creatorId;
        bytes32 salt;
    }

    struct Launch {
        address token;
        address deployer;
        bytes32 creatorId;
        address feeDistributor;
        address liquidityLocker;
        PoolId poolId;
        uint256 lpTokenId;
        uint64 createdAt;
    }

    struct LaunchResult {
        address token;
        address feeDistributor;
        address liquidityLocker;
        uint256 lpTokenId;
        PoolId poolId;
    }

    mapping(address token => Launch) public launches;

    event TokenLaunched(
        address indexed token,
        address indexed deployer,
        bytes32 indexed creatorId,
        address feeDistributor,
        address liquidityLocker,
        PoolId poolId,
        uint256 lpTokenId,
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
        address buybackVault_,
        address operations_
    ) {
        if (
            poolManager_ == address(0) || positionManager_ == address(0) || permit2_ == address(0)
                || universalRouter_ == address(0) || tokenDeployer_ == address(0) || launchDeployer_ == address(0)
                || creatorRewards_ == address(0) || buybackVault_ == address(0) || operations_ == address(0)
        ) {
            revert ZeroAddress();
        }

        // Factory must be the immutable CreatorRewards sourceRegistrar.
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
        buybackVault = buybackVault_;
        operations = operations_;
    }

    /// @notice Atomically launch an ETH / ScoopToken market with no initial purchase.
    function launch(LaunchParams calldata params)
        external
        nonReentrant
        returns (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId, PoolId poolId)
    {
        LaunchResult memory result = _launch(params);
        return (result.token, result.feeDistributor, result.liquidityLocker, result.lpTokenId, result.poolId);
    }

    /**
     * @notice Atomically launch a market then buy launched tokens with `msg.value` ETH.
     * @dev Real Uniswap v4 exact-input buy through Universal Router (1% LP fee applies).
     *      Purchased tokens are delivered to `msg.sender`. No free allocation.
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
        if (msg.value == 0) revert ZeroInitialBuy();

        LaunchResult memory result = _launch(params);
        tokensBought = _executeInitialBuy(result.token, msg.value, minTokensOut);

        emit InitialBuyExecuted(result.token, msg.sender, msg.value, tokensBought);

        return
            (result.token, result.feeDistributor, result.liquidityLocker, result.lpTokenId, result.poolId, tokensBought);
    }

    function _launch(LaunchParams calldata params) internal returns (LaunchResult memory result) {
        if (params.creatorId == bytes32(0)) revert ZeroCreatorId();

        (result.token, result.feeDistributor, result.liquidityLocker) = _deployLaunchContracts(params);
        creatorRewards.registerSource(result.feeDistributor, params.creatorId);
        (result.lpTokenId, result.poolId) = _initPoolAndLockLiquidity(result.token, result.liquidityLocker);
        _finalizeLaunch(params, result);
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

    function _initPoolAndLockLiquidity(address token, address liquidityLocker)
        internal
        returns (uint256 lpTokenId, PoolId poolId)
    {
        PoolKey memory key = _poolKey(token);
        poolManager.initialize(key, _initialSqrtPriceX96());
        lpTokenId = _mintOneSidedLiquidity(key, token, liquidityLocker);
        poolId = key.toId();

        if (IERC721(address(positionManager)).ownerOf(lpTokenId) != liquidityLocker) {
            revert FactoryRetainedLpNft(lpTokenId);
        }

        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) {
            IERC20(token).safeTransfer(address(0x000000000000000000000000000000000000dEaD), remaining);
        }
    }

    function _finalizeLaunch(LaunchParams calldata params, LaunchResult memory result) internal {
        launches[result.token] = Launch({
            token: result.token,
            deployer: msg.sender,
            creatorId: params.creatorId,
            feeDistributor: result.feeDistributor,
            liquidityLocker: result.liquidityLocker,
            poolId: result.poolId,
            lpTokenId: result.lpTokenId,
            createdAt: uint64(block.timestamp)
        });

        emit TokenLaunched(
            result.token,
            msg.sender,
            params.creatorId,
            result.feeDistributor,
            result.liquidityLocker,
            result.poolId,
            result.lpTokenId,
            params.name,
            params.symbol
        );
    }

    /// @dev Exact-input ETH→token buy on the just-created pool; tokens forwarded to msg.sender.
    function _executeInitialBuy(address token, uint256 ethIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensBought)
    {
        address buyer = msg.sender;
        uint256 buyerBefore = IERC20(token).balanceOf(buyer);

        PoolKey memory key = _poolKey(token);
        bytes memory commands = abi.encodePacked(CMD_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _encodeV4ExactInSingle(key, uint128(ethIn), uint128(minTokensOut));

        universalRouter.execute{value: ethIn}(commands, inputs, block.timestamp + 60);

        // Universal Router TAKE_ALL credits the execute caller (this factory).
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

    function _encodeV4ExactInSingle(PoolKey memory key, uint128 amountIn, uint128 amountOutMinimum)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(key.currency0, uint256(amountIn));
        params[2] = abi.encode(key.currency1, uint256(amountOutMinimum));
        return abi.encode(actions, params);
    }

    function isScoopToken(address token) external view returns (bool) {
        return launches[token].token != address(0);
    }

    function getLaunch(address token) external view returns (Launch memory) {
        return launches[token];
    }

    /// @dev Opening sqrt price. Isolated for later production valuation replacement.
    function _initialSqrtPriceX96() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(0);
    }

    /// @dev Native ETH is address(0) and always sorts as currency0 vs any ScoopToken.
    function _poolKey(address token) internal pure returns (PoolKey memory key) {
        Currency eth = CurrencyLibrary.ADDRESS_ZERO;
        Currency scoop = Currency.wrap(token);
        if (!(eth < scoop)) revert UnexpectedCurrencyOrder();

        key = PoolKey({
            currency0: eth, currency1: scoop, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))
        });
    }

    function _mintOneSidedLiquidity(PoolKey memory key, address token, address liquidityLocker)
        internal
        returns (uint256 tokenId)
    {
        uint256 supply = ScoopToken(token).MAX_SUPPLY();

        IERC20(token).forceApprove(address(permit2), supply);
        permit2.approve(token, address(positionManager), uint160(supply), type(uint48).max);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, supply);

        tokenId = positionManager.nextTokenId();

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liquidity), uint128(0), uint128(supply), liquidityLocker, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        IERC20(token).forceApprove(address(permit2), 0);
    }
}
