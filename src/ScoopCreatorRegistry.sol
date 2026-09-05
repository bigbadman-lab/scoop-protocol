// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ScoopCreatorRegistry
 * @notice Deterministic creator identity registry for SCOOP Protocol V1.
 * @dev Resolves creator identities to payout wallets. Holds no funds and never
 *      custodies ETH or tokens.
 *
 *      Wallet identities are intrinsic: `creatorId = keccak256(abi.encode(Wallet, wallet))`
 *      and the payout wallet is always that same address. No registration transaction
 *      is required, and a wallet creator ID cannot be rebound.
 *
 *      X identities use the persistent numeric X user ID as the canonical protocol
 *      identity (not the mutable handle). Handles are presentation metadata only and
 *      are not stored here. An X creator ID starts unclaimed (`resolvedWallet == 0`)
 *      and is permanently bound to a payout wallet after a signed authorization from
 *      the immutable `verificationAuthority` (off-chain X ownership verification).
 *
 *      Unclaimed X identities are not an endorsement of any account; they only encode
 *      a fee destination assignment pending verification.
 *
 *      V1 binding is permanent: no transfer, revoke, admin override, or rebinding.
 */
contract ScoopCreatorRegistry is EIP712 {
    /// @notice Creator identity domains supported in V1.
    enum CreatorType {
        Wallet,
        X
    }

    /// @dev EIP-712 typehash for X claim authorizations.
    ///      Replay protection: domain-bound (chainId + this contract) plus one-time
    ///      X identity binding. No mutable nonce store is required because an X
    ///      creator ID can only be claimed once.
    bytes32 public constant CLAIM_X_IDENTITY_TYPEHASH =
        keccak256("ClaimXIdentity(uint256 xUserId,address wallet,uint256 deadline)");

    error ZeroVerificationAuthority();
    error ZeroWallet();
    error ZeroXUserId();
    error ExpiredAuthorization();
    error InvalidSignature();
    error IdentityAlreadyClaimed();

    /// @notice Trusted SCOOP verification authority for signed X claims. Immutable.
    address public immutable verificationAuthority;

    /// @dev Permanent X creatorId → payout wallet bindings. Unset means unclaimed.
    mapping(bytes32 creatorId => address wallet) private _xPayoutWallets;

    event XIdentityClaimed(bytes32 indexed creatorId, uint256 indexed xUserId, address indexed wallet);

    constructor(address verificationAuthority_) EIP712("ScoopCreatorRegistry", "1") {
        if (verificationAuthority_ == address(0)) revert ZeroVerificationAuthority();
        verificationAuthority = verificationAuthority_;
    }

    /// @notice Deterministic creator ID for a wallet identity.
    function walletCreatorId(address wallet) public pure returns (bytes32) {
        return keccak256(abi.encode(CreatorType.Wallet, wallet));
    }

    /// @notice Deterministic creator ID for an X identity (persistent numeric user ID).
    function xCreatorId(uint256 xUserId) public pure returns (bytes32) {
        return keccak256(abi.encode(CreatorType.X, xUserId));
    }

    /**
     * @notice Intrinsic payout wallet for a wallet creator identity.
     * @dev Future ScoopCreatorRewards should treat `walletCreatorId(wallet)` as
     *      always resolving to `wallet` with no registry lookup required.
     */
    function resolveWalletCreator(address wallet) external pure returns (address) {
        if (wallet == address(0)) revert ZeroWallet();
        return wallet;
    }

    /// @notice Resolved payout wallet for a creator ID.
    /// @dev For X identities: address(0) until claimed, then the bound wallet.
    ///      Wallet creator IDs are not stored; use `resolveWalletCreator` /
    ///      `resolvePayoutWallet` instead (hashes are not reversible).
    function resolvedWallet(bytes32 creatorId) external view returns (address) {
        return _xPayoutWallets[creatorId];
    }

    /**
     * @notice Resolve payout wallet for any creatorId.
     * @param creatorId Canonical creator identity.
     * @param candidateWallet Required hint for intrinsic wallet identities
     *        (`walletCreatorId(candidateWallet) == creatorId`). For claimed X
     *        identities the permanent binding is returned and the candidate is
     *        ignored so claims cannot be redirected.
     * @return wallet Payout destination, or address(0) if unresolved.
     */
    function resolvePayoutWallet(bytes32 creatorId, address candidateWallet) external view returns (address wallet) {
        wallet = _xPayoutWallets[creatorId];
        if (wallet != address(0)) return wallet;

        if (candidateWallet != address(0) && walletCreatorId(candidateWallet) == creatorId) {
            return candidateWallet;
        }
        return address(0);
    }

    /// @notice Convenience resolver for an X user ID.
    function xResolvedWallet(uint256 xUserId) external view returns (address) {
        return _xPayoutWallets[xCreatorId(xUserId)];
    }

    /// @notice Whether the given X user ID has been permanently claimed.
    function isXClaimed(uint256 xUserId) external view returns (bool) {
        return _xPayoutWallets[xCreatorId(xUserId)] != address(0);
    }

    /// @notice Whether a creator ID has a stored X payout binding.
    function isClaimed(bytes32 creatorId) external view returns (bool) {
        return _xPayoutWallets[creatorId] != address(0);
    }

    /// @notice EIP-712 digest for an X claim authorization (for off-chain signing).
    function hashClaimXIdentity(uint256 xUserId, address wallet, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CLAIM_X_IDENTITY_TYPEHASH, xUserId, wallet, deadline)));
    }

    /**
     * @notice Permanently bind an X creator identity to `wallet` using a signed
     *         authorization from `verificationAuthority`.
     * @dev Permissionless submission: `msg.sender` need not be `wallet`. The
     *      signature is the permission. Binding cannot be changed afterward.
     */
    function claimXIdentity(uint256 xUserId, address wallet, uint256 deadline, bytes calldata signature) external {
        if (xUserId == 0) revert ZeroXUserId();
        if (wallet == address(0)) revert ZeroWallet();
        if (block.timestamp > deadline) revert ExpiredAuthorization();

        bytes32 creatorId = xCreatorId(xUserId);
        if (_xPayoutWallets[creatorId] != address(0)) revert IdentityAlreadyClaimed();

        bytes32 digest = hashClaimXIdentity(xUserId, wallet, deadline);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != verificationAuthority) revert InvalidSignature();

        _xPayoutWallets[creatorId] = wallet;

        emit XIdentityClaimed(creatorId, xUserId, wallet);
    }
}
