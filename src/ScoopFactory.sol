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
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {ScoopToken} from "./ScoopToken.sol";
import {ScoopTokenDeployer} from "./ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "./ScoopLaunchDeployer.sol";
import {ScoopCreatorRewards} from "./ScoopCreatorRewards.sol";

/**
 * @title ScoopFactory
 * @notice Permissionless atomic launch orchestrator for SCOOP Protocol V1 (ETH / ScoopToken).
 * @dev A single `launch` call deploys token + fee distributor + locker, registers the
 *      distributor as a CreatorRewards source for the supplied `creatorId`, initializes a
 *      Uniswap v4 pool, commits 100% token supply as one-sided liquidity, and permanently
 *      locks the LP NFT.
 *
 *      Deployer attribution is always `msg.sender` (4% fee leg). Creator attribution is the
 *      pre-derived `creatorId` permanently bound via ScoopCreatorRewards source registration.
 *
 *      Effective salts incorporate `msg.sender` so independent deployers cannot grief each other
 *      with the same user-supplied salt. Child domains separate token vs launch CREATE2 salts.
 *
 *      This factory is intended to be the immutable `sourceRegistrar` on ScoopCreatorRewards.
 *      Deploy via ScoopFactoryDeployer so CreatorRewards is constructed with this address.
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

    error ZeroAddress();
    error ZeroCreatorId();
    error InvalidSourceRegistrar();
    error UnexpectedCurrencyOrder();
    error FactoryRetainedLpNft(uint256 tokenId);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
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

    constructor(
        address poolManager_,
        address positionManager_,
        address permit2_,
        address tokenDeployer_,
        address launchDeployer_,
        address creatorRewards_,
        address buybackVault_,
        address operations_
    ) {
        if (
            poolManager_ == address(0) || positionManager_ == address(0) || permit2_ == address(0)
                || tokenDeployer_ == address(0) || launchDeployer_ == address(0) || creatorRewards_ == address(0)
                || buybackVault_ == address(0) || operations_ == address(0)
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
        tokenDeployer = ScoopTokenDeployer(tokenDeployer_);
        launchDeployer = ScoopLaunchDeployer(launchDeployer_);
        creatorRewards = ScoopCreatorRewards(creatorRewards_);
        buybackVault = buybackVault_;
        operations = operations_;
    }

    /// @notice Atomically launch an ETH / ScoopToken market.
    function launch(LaunchParams calldata params)
        external
        nonReentrant
        returns (address token, address feeDistributor, address liquidityLocker, uint256 lpTokenId, PoolId poolId)
    {
        if (params.creatorId == bytes32(0)) revert ZeroCreatorId();

        (token, feeDistributor, liquidityLocker) = _deployLaunchContracts(params);
        creatorRewards.registerSource(feeDistributor, params.creatorId);
        (lpTokenId, poolId) = _initPoolAndLockLiquidity(token, liquidityLocker);
        _finalizeLaunch(params, token, feeDistributor, liquidityLocker, lpTokenId, poolId);
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

    function _finalizeLaunch(
        LaunchParams calldata params,
        address token,
        address feeDistributor,
        address liquidityLocker,
        uint256 lpTokenId,
        PoolId poolId
    ) internal {
        launches[token] = Launch({
            token: token,
            deployer: msg.sender,
            creatorId: params.creatorId,
            feeDistributor: feeDistributor,
            liquidityLocker: liquidityLocker,
            poolId: poolId,
            lpTokenId: lpTokenId,
            createdAt: uint64(block.timestamp)
        });

        emit TokenLaunched(
            token,
            msg.sender,
            params.creatorId,
            feeDistributor,
            liquidityLocker,
            poolId,
            lpTokenId,
            params.name,
            params.symbol
        );
    }

    function isScoopToken(address token) external view returns (bool) {
        return launches[token].token != address(0);
    }

    function getLaunch(address token) external view returns (Launch memory) {
        return launches[token];
    }

    /// @dev Opening sqrt price. Isolated for later production valuation replacement.
    function _initialSqrtPriceX96() internal pure returns (uint160) {
        // Tick 0 / 1:1 raw units — proven V1 ETH-only test market opening.
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
        // amount0Max = 0 ETH principal; amount1Max = full supply; NFT recipient = locker.
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liquidity), uint128(0), uint128(supply), liquidityLocker, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        IERC20(token).forceApprove(address(permit2), 0);
    }
}
