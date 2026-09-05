// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ScoopCreatorRegistry} from "./ScoopCreatorRegistry.sol";
import {IScoopCreatorRewards} from "./interfaces/IScoopCreatorRewards.sol";

/**
 * @title ScoopCreatorRewards
 * @notice Escrow and claim accounting for the 70% creator-rewards LP fee allocation.
 * @dev Rewards are keyed by immutable `bytes32 creatorId` from ScoopCreatorRegistry —
 *      never by X handles. Registered fee distribution sources (per-launch ScoopFeeDistributor)
 *      have permanent creator attribution set only by the immutable `sourceRegistrar`
 *      (ScoopFactory).
 *
 *      Crediting: only a registered source may call `creditETH` / `creditToken`.
 *      The credited creatorId is derived solely from `sourceCreatorId[msg.sender]`,
 *      so a source cannot choose or redirect attribution at payment time.
 *
 *      Claiming: permissionless to trigger, never redirectable. Payout destination
 *      comes from ScoopCreatorRegistry via `resolvePayoutWallet`. Unclaimed X
 *      identities accrue indefinitely and remain unclaimable until verified; after
 *      verification, existing balances become claimable with no migration.
 *
 *      This contract does not perform identity verification, OAuth, or buybacks.
 *      Plain ETH transfers are rejected (no `receive`) because they cannot be attributed.
 */
contract ScoopCreatorRewards is ReentrancyGuard, IScoopCreatorRewards {
    using SafeERC20 for IERC20;

    error ZeroCreatorRegistry();
    error ZeroSourceRegistrar();
    error UnauthorizedRegistrar();
    error ZeroSource();
    error ZeroCreatorId();
    error SourceAlreadyRegistered();
    error UnregisteredSource();
    error ZeroAmount();
    error ZeroToken();
    error CreatorUnresolved();
    error ZeroClaimableBalance();
    error NativeTransferFailed(address recipient, uint256 amount);

    address public immutable creatorRegistry;
    address public immutable sourceRegistrar;

    /// @notice Permanent source → creatorId attribution. Write-once.
    mapping(address source => bytes32 creatorId) public sourceCreatorId;

    mapping(bytes32 creatorId => uint256 amount) internal _ethRewards;
    mapping(bytes32 creatorId => mapping(address token => uint256 amount)) internal _tokenRewards;

    event SourceRegistered(address indexed source, bytes32 indexed creatorId);
    event ETHCredited(bytes32 indexed creatorId, address indexed source, uint256 amount);
    event TokenCredited(bytes32 indexed creatorId, address indexed source, address indexed token, uint256 amount);
    event ETHClaimed(bytes32 indexed creatorId, address indexed wallet, uint256 amount);
    event TokenClaimed(bytes32 indexed creatorId, address indexed wallet, address indexed token, uint256 amount);

    constructor(address creatorRegistry_, address sourceRegistrar_) {
        if (creatorRegistry_ == address(0)) revert ZeroCreatorRegistry();
        if (sourceRegistrar_ == address(0)) revert ZeroSourceRegistrar();
        creatorRegistry = creatorRegistry_;
        sourceRegistrar = sourceRegistrar_;
    }

    /// @notice Permanently register a reward source to a creator identity. Registrar-only.
    function registerSource(address source, bytes32 creatorId) external {
        if (msg.sender != sourceRegistrar) revert UnauthorizedRegistrar();
        if (source == address(0)) revert ZeroSource();
        if (creatorId == bytes32(0)) revert ZeroCreatorId();
        if (sourceCreatorId[source] != bytes32(0)) revert SourceAlreadyRegistered();

        sourceCreatorId[source] = creatorId;
        emit SourceRegistered(source, creatorId);
    }

    /// @notice Credit ETH rewards to the creator permanently attributed to `msg.sender`.
    function creditETH() external payable nonReentrant {
        bytes32 creatorId = sourceCreatorId[msg.sender];
        if (creatorId == bytes32(0)) revert UnregisteredSource();
        if (msg.value == 0) revert ZeroAmount();

        _ethRewards[creatorId] += msg.value;
        emit ETHCredited(creatorId, msg.sender, msg.value);
    }

    /// @notice Credit ERC-20 rewards using actual received amount (balance delta).
    function creditToken(address token, uint256 amount) external nonReentrant {
        bytes32 creatorId = sourceCreatorId[msg.sender];
        if (creatorId == bytes32(0)) revert UnregisteredSource();
        if (token == address(0)) revert ZeroToken();
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 creditedAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (creditedAmount == 0) revert ZeroAmount();

        _tokenRewards[creatorId][token] += creditedAmount;
        emit TokenCredited(creatorId, msg.sender, token, creditedAmount);
    }

    function claimableETH(bytes32 creatorId) external view returns (uint256) {
        return _ethRewards[creatorId];
    }

    function claimableToken(bytes32 creatorId, address token) external view returns (uint256) {
        return _tokenRewards[creatorId][token];
    }

    /**
     * @notice Claim all ETH accrued to `creatorId` to the registry-resolved wallet.
     * @param candidateWallet Hint for intrinsic wallet identities; ignored when an
     *        X identity is already bound in the registry.
     */
    function claimETH(bytes32 creatorId, address candidateWallet) external nonReentrant {
        address wallet = ScoopCreatorRegistry(creatorRegistry).resolvePayoutWallet(creatorId, candidateWallet);
        if (wallet == address(0)) revert CreatorUnresolved();

        uint256 amount = _ethRewards[creatorId];
        if (amount == 0) revert ZeroClaimableBalance();

        _ethRewards[creatorId] = 0;

        (bool success,) = wallet.call{value: amount}("");
        if (!success) revert NativeTransferFailed(wallet, amount);

        emit ETHClaimed(creatorId, wallet, amount);
    }

    /**
     * @notice Claim all `token` accrued to `creatorId` to the registry-resolved wallet.
     * @param candidateWallet Hint for intrinsic wallet identities; ignored when an
     *        X identity is already bound in the registry.
     */
    function claimToken(bytes32 creatorId, address token, address candidateWallet) external nonReentrant {
        if (token == address(0)) revert ZeroToken();

        address wallet = ScoopCreatorRegistry(creatorRegistry).resolvePayoutWallet(creatorId, candidateWallet);
        if (wallet == address(0)) revert CreatorUnresolved();

        uint256 amount = _tokenRewards[creatorId][token];
        if (amount == 0) revert ZeroClaimableBalance();

        _tokenRewards[creatorId][token] = 0;
        IERC20(token).safeTransfer(wallet, amount);

        emit TokenClaimed(creatorId, wallet, token, amount);
    }
}
