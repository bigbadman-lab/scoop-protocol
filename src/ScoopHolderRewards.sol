// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IScoopHolderRewards} from "./interfaces/IScoopHolderRewards.sol";

/**
 * @title ScoopHolderRewards
 * @notice Per-launch vault for holder-directed trading-fee rewards.
 * @dev Funds arrive only via `depositETH` / `depositToken` from the immutable fee distributor
 *      (bound once by LaunchDeployer after CREATE2 deploy — breaks the mutual-address cycle).
 *
 *      Hourly entitlement rounds are published by an immutable `rootPublisher` as Merkle roots.
 *      Anyone may `pushBatch` or `claim` with a valid proof; payouts always go to the leaf account.
 *
 *      Leaf (OpenZeppelin double-hash, commutative tree):
 *      `keccak256(bytes.concat(keccak256(abi.encode(chainid, vault, roundId, asset, account, amount))))`
 *      where `asset == address(0)` denotes native ETH.
 *
 *      No owner, no rescue, no arbitrary withdraw. Accidental plain ETH/ERC20 transfers do not
 *      increase logical `uncommitted` balances.
 */
contract ScoopHolderRewards is IScoopHolderRewards, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error UnauthorizedDistributor();
    error UnauthorizedPublisher();
    error UnauthorizedInitializer();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAmount();
    error ZeroRoot();
    error RoundAlreadyPublished();
    error InsufficientUncommitted();
    error InvalidProof();
    error AlreadyPaid();
    error NativeTransferFailed(address account, uint256 amount);
    error OnlySelf();
    error EmptyBatch();

    struct Round {
        bytes32 merkleRoot;
        uint256 totalCommitted;
        bool published;
    }

    struct Payout {
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    /// @notice Native ETH asset key in accounting maps.
    address public constant NATIVE_ASSET = address(0);

    address public immutable rootPublisher;
    /// @dev ScoopLaunchDeployer that may call `initializeFeeDistributor` once.
    address public immutable launchDeployer;

    address public feeDistributor;

    mapping(address asset => uint256) internal _uncommitted;
    mapping(address asset => uint256) internal _outstandingCommitted;
    mapping(address asset => uint256) internal _totalDeposited;
    mapping(address asset => uint256) internal _totalPaid;

    mapping(uint64 roundId => mapping(address asset => Round)) internal _rounds;
    mapping(uint64 roundId => mapping(address asset => mapping(address account => bool))) internal _paid;

    event FeeDistributorInitialized(address indexed feeDistributor_);
    event HolderRewardDeposited(address indexed asset, uint256 amount);
    event HolderRewardRoundPublished(
        uint64 indexed roundId, address indexed asset, bytes32 merkleRoot, uint256 totalCommitted
    );
    event HolderRewardPushed(uint64 indexed roundId, address indexed asset, address indexed account, uint256 amount);
    event HolderRewardClaimed(uint64 indexed roundId, address indexed asset, address indexed account, uint256 amount);
    event HolderRewardPushFailed(
        uint64 indexed roundId, address indexed asset, address indexed account, uint256 amount, bytes reason
    );

    constructor(address rootPublisher_, address launchDeployer_) {
        if (rootPublisher_ == address(0) || launchDeployer_ == address(0)) revert ZeroAddress();
        rootPublisher = rootPublisher_;
        launchDeployer = launchDeployer_;
    }

    /// @notice Bind the launch fee distributor. LaunchDeployer-only, once.
    function initializeFeeDistributor(address feeDistributor_) external {
        if (msg.sender != launchDeployer) revert UnauthorizedInitializer();
        if (feeDistributor != address(0)) revert AlreadyInitialized();
        if (feeDistributor_ == address(0)) revert ZeroAddress();
        feeDistributor = feeDistributor_;
        emit FeeDistributorInitialized(feeDistributor_);
    }

    /// @notice Reject plain ETH; deposits must use `depositETH`.
    receive() external payable {
        revert UnauthorizedDistributor();
    }

    /// @inheritdoc IScoopHolderRewards
    function depositETH() external payable nonReentrant {
        _requireDistributor();
        if (msg.value == 0) revert ZeroAmount();
        _uncommitted[NATIVE_ASSET] += msg.value;
        _totalDeposited[NATIVE_ASSET] += msg.value;
        emit HolderRewardDeposited(NATIVE_ASSET, msg.value);
    }

    /// @inheritdoc IScoopHolderRewards
    function depositToken(address token, uint256 amount) external nonReentrant {
        _requireDistributor();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroAmount();

        _uncommitted[token] += received;
        _totalDeposited[token] += received;
        emit HolderRewardDeposited(token, received);
    }

    function publishRound(uint64 roundId, address asset, bytes32 merkleRoot, uint256 totalCommitted)
        external
        nonReentrant
    {
        if (msg.sender != rootPublisher) revert UnauthorizedPublisher();
        if (merkleRoot == bytes32(0)) revert ZeroRoot();
        if (totalCommitted == 0) revert ZeroAmount();

        Round storage r = _rounds[roundId][asset];
        if (r.published) revert RoundAlreadyPublished();
        if (totalCommitted > _uncommitted[asset]) revert InsufficientUncommitted();

        _uncommitted[asset] -= totalCommitted;
        _outstandingCommitted[asset] += totalCommitted;
        r.merkleRoot = merkleRoot;
        r.totalCommitted = totalCommitted;
        r.published = true;

        emit HolderRewardRoundPublished(roundId, asset, merkleRoot, totalCommitted);
    }

    function claim(uint64 roundId, address asset, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        _payoutOrRevert(roundId, asset, account, amount, proof, true);
    }

    /// @notice Permissionless proof-constrained batch push. Failed recipients stay unpaid/claimable.
    function pushBatch(uint64 roundId, address asset, Payout[] calldata payouts) external nonReentrant {
        if (payouts.length == 0) revert EmptyBatch();
        for (uint256 i; i < payouts.length; ++i) {
            Payout calldata p = payouts[i];
            (bool ok, bytes memory reason) = _tryPayout(roundId, asset, p.account, p.amount, p.proof);
            if (ok) {
                emit HolderRewardPushed(roundId, asset, p.account, p.amount);
            } else {
                emit HolderRewardPushFailed(roundId, asset, p.account, p.amount, reason);
            }
        }
    }

    function uncommitted(address asset) external view returns (uint256) {
        return _uncommitted[asset];
    }

    function outstandingCommitted(address asset) external view returns (uint256) {
        return _outstandingCommitted[asset];
    }

    function totalDeposited(address asset) external view returns (uint256) {
        return _totalDeposited[asset];
    }

    function totalPaid(address asset) external view returns (uint256) {
        return _totalPaid[asset];
    }

    function round(uint64 roundId, address asset)
        external
        view
        returns (bytes32 merkleRoot, uint256 totalCommitted, bool published)
    {
        Round storage r = _rounds[roundId][asset];
        return (r.merkleRoot, r.totalCommitted, r.published);
    }

    function isPaid(uint64 roundId, address asset, address account) external view returns (bool) {
        return _paid[roundId][asset][account];
    }

    /// @notice Canonical double-hashed leaf for OpenZeppelin commutative Merkle trees.
    function leafHash(uint64 roundId, address asset, address account, uint256 amount) public view returns (bytes32) {
        return
            keccak256(
                bytes.concat(keccak256(abi.encode(block.chainid, address(this), roundId, asset, account, amount)))
            );
    }

    function _requireDistributor() internal view {
        address d = feeDistributor;
        if (d == address(0)) revert NotInitialized();
        if (msg.sender != d) revert UnauthorizedDistributor();
    }

    function _payoutOrRevert(
        uint64 roundId,
        address asset,
        address account,
        uint256 amount,
        bytes32[] calldata proof,
        bool emitClaim
    ) internal {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_paid[roundId][asset][account]) revert AlreadyPaid();

        Round storage r = _rounds[roundId][asset];
        if (!r.published) revert InvalidProof();

        bytes32 leaf = leafHash(roundId, asset, account, amount);
        if (!MerkleProof.verifyCalldata(proof, r.merkleRoot, leaf)) revert InvalidProof();

        _paid[roundId][asset][account] = true;
        _outstandingCommitted[asset] -= amount;
        _totalPaid[asset] += amount;

        _transfer(asset, account, amount);

        if (emitClaim) {
            emit HolderRewardClaimed(roundId, asset, account, amount);
        }
    }

    /// @dev Best-effort payout for pushBatch: undoes accounting if transfer fails.
    function _tryPayout(uint64 roundId, address asset, address account, uint256 amount, bytes32[] calldata proof)
        internal
        returns (bool ok, bytes memory reason)
    {
        if (account == address(0) || amount == 0) {
            return (false, bytes("invalid"));
        }
        if (_paid[roundId][asset][account]) {
            return (false, bytes("already paid"));
        }

        Round storage r = _rounds[roundId][asset];
        if (!r.published) {
            return (false, bytes("unpublished"));
        }

        bytes32 leaf = leafHash(roundId, asset, account, amount);
        if (!MerkleProof.verifyCalldata(proof, r.merkleRoot, leaf)) {
            return (false, bytes("invalid proof"));
        }

        _paid[roundId][asset][account] = true;
        _outstandingCommitted[asset] -= amount;
        _totalPaid[asset] += amount;

        (bool sent, bytes memory err) = _tryTransfer(asset, account, amount);
        if (!sent) {
            _paid[roundId][asset][account] = false;
            _outstandingCommitted[asset] += amount;
            _totalPaid[asset] -= amount;
            return (false, err.length == 0 ? bytes("transfer failed") : err);
        }
        return (true, bytes(""));
    }

    function _transfer(address asset, address account, uint256 amount) internal {
        if (asset == NATIVE_ASSET) {
            (bool success,) = account.call{value: amount}("");
            if (!success) revert NativeTransferFailed(account, amount);
        } else {
            IERC20(asset).safeTransfer(account, amount);
        }
    }

    function _tryTransfer(address asset, address account, uint256 amount) internal returns (bool ok, bytes memory err) {
        if (asset == NATIVE_ASSET) {
            (ok, err) = account.call{value: amount}("");
            return (ok, err);
        }
        try this.safeTransferExternal(asset, account, amount) {
            return (true, bytes(""));
        } catch (bytes memory reason) {
            return (false, reason);
        }
    }

    /// @dev External wrapper so ERC20 transfer failures can be caught in `_tryTransfer`.
    function safeTransferExternal(address token, address to, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20(token).safeTransfer(to, amount);
    }
}
