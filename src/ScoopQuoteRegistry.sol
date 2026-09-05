// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ScoopQuoteRegistry
 * @notice Canonical policy/metadata registry of quote assets SCOOP is permitted to support.
 * @dev Handles ONLY asset identity/classification and approval (enabled) status.
 *
 *      This registry does NOT:
 *      - price assets or imply price correctness
 *      - execute swaps, create pools, or launch tokens
 *      - custody ETH/ERC20 or call oracles
 *      - prove Stock/Pons issuance authenticity (those are protocol policy classifications)
 *
 *      Native ETH is represented by `address(0)`, matching Uniswap v4 `Currency.wrap(address(0))`.
 *      Zero address is therefore a valid quote asset identifier and must not be rejected generically.
 *
 *      `registryAuthority` is immutable. Only that address may register quotes or change enabled
 *      status. There is no ownership transfer, authority setter, upgrade path, or arbitrary call.
 *      The authority may later be a multisig/governance contract without changing this registry.
 *
 *      Registration permanently fixes `QuoteType` for an asset. Enabled status may change over time
 *      (disable for safety, re-enable if appropriate). Historical registration is never deleted.
 *
 *      Downstream contracts (e.g. future ScoopFactory / pricing primitives) should separately handle
 *      pricing and execution, typically gating on `isEnabled(asset)`.
 *
 *      V1 does not require `asset.code.length > 0` on registration: classification is
 *      authority-controlled, and deterministic/future token addresses may be registered before deploy.
 */
contract ScoopQuoteRegistry {
    /// @notice Quote asset categories supported by SCOOP policy.
    enum QuoteType {
        Native,
        Scoop,
        Stock,
        Pons
    }

    /// @notice Minimal on-chain quote policy record.
    struct QuoteAsset {
        QuoteType quoteType;
        bool enabled;
    }

    error ZeroRegistryAuthority();
    error Unauthorized();
    error QuoteAlreadyRegistered(address asset);
    error QuoteNotRegistered(address asset);
    error InvalidNativeQuote(address asset);
    error InvalidNonNativeQuote();
    error QuoteStatusUnchanged(address asset, bool enabled);
    error IndexOutOfBounds(uint256 index, uint256 count);

    /// @notice Sole address permitted to mutate registry policy. Immutable.
    address public immutable registryAuthority;

    mapping(address asset => QuoteAsset) private _quoteAssets;
    mapping(address asset => bool) private _registered;
    address[] private _registeredAssets;

    event QuoteRegistered(address indexed asset, QuoteType indexed quoteType);
    event QuoteStatusChanged(address indexed asset, bool enabled);

    constructor(address registryAuthority_) {
        if (registryAuthority_ == address(0)) revert ZeroRegistryAuthority();
        registryAuthority = registryAuthority_;
    }

    modifier onlyAuthority() {
        if (msg.sender != registryAuthority) revert Unauthorized();
        _;
    }

    /**
     * @notice Permanently register a quote asset with a fixed classification.
     * @dev Write-once for identity/type. Starts enabled. Does not validate token bytecode.
     */
    function registerQuote(address asset, QuoteType quoteType) external onlyAuthority {
        if (_registered[asset]) revert QuoteAlreadyRegistered(asset);

        if (quoteType == QuoteType.Native) {
            if (asset != address(0)) revert InvalidNativeQuote(asset);
        } else if (asset == address(0)) {
            revert InvalidNonNativeQuote();
        }

        _registered[asset] = true;
        _quoteAssets[asset] = QuoteAsset({quoteType: quoteType, enabled: true});
        _registeredAssets.push(asset);

        emit QuoteRegistered(asset, quoteType);
    }

    /**
     * @notice Enable or disable an already-registered quote asset.
     * @dev Does not change QuoteType or registered status. Reverts if status is unchanged.
     */
    function setQuoteEnabled(address asset, bool enabled) external onlyAuthority {
        if (!_registered[asset]) revert QuoteNotRegistered(asset);
        if (_quoteAssets[asset].enabled == enabled) revert QuoteStatusUnchanged(asset, enabled);

        _quoteAssets[asset].enabled = enabled;
        emit QuoteStatusChanged(asset, enabled);
    }

    /// @notice Whether `asset` has been permanently registered.
    function isRegistered(address asset) external view returns (bool) {
        return _registered[asset];
    }

    /// @notice Whether `asset` is currently approved for use as a SCOOP quote.
    /// @dev Unregistered assets return false.
    function isEnabled(address asset) external view returns (bool) {
        return _registered[asset] && _quoteAssets[asset].enabled;
    }

    /// @notice Permanent classification for a registered quote asset.
    function quoteType(address asset) external view returns (QuoteType) {
        if (!_registered[asset]) revert QuoteNotRegistered(asset);
        return _quoteAssets[asset].quoteType;
    }

    /// @notice Full policy record for a registered quote asset.
    function getQuote(address asset) external view returns (QuoteAsset memory) {
        if (!_registered[asset]) revert QuoteNotRegistered(asset);
        return _quoteAssets[asset];
    }

    /// @notice Number of historically registered quote assets (including disabled).
    function registeredQuoteCount() external view returns (uint256) {
        return _registeredAssets.length;
    }

    /// @notice Registered asset at insertion-order index.
    function registeredQuoteAt(uint256 index) external view returns (address) {
        uint256 count = _registeredAssets.length;
        if (index >= count) revert IndexOutOfBounds(index, count);
        return _registeredAssets[index];
    }
}
