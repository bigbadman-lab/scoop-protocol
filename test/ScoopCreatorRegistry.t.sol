// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";

contract ScoopCreatorRegistryTest is Test {
    ScoopCreatorRegistry registry;

    address authority;
    uint256 authorityKey;

    address walletA;
    address walletB;
    address relayer;

    uint256 constant X_USER_A = 123456789;
    uint256 constant X_USER_B = 987654321;

    event XIdentityClaimed(bytes32 indexed creatorId, uint256 indexed xUserId, address indexed wallet);

    function setUp() public {
        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        walletA = makeAddr("walletA");
        walletB = makeAddr("walletB");
        relayer = makeAddr("relayer");

        registry = new ScoopCreatorRegistry(authority);
    }

    // ──────────────────────────────────────────────
    // Identity derivation
    // ──────────────────────────────────────────────

    function test_walletCreatorId_deterministic() public view {
        bytes32 id = registry.walletCreatorId(walletA);
        assertEq(id, keccak256(abi.encode(ScoopCreatorRegistry.CreatorType.Wallet, walletA)));
    }

    function test_walletCreatorId_sameWalletSameId() public view {
        assertEq(registry.walletCreatorId(walletA), registry.walletCreatorId(walletA));
    }

    function test_walletCreatorId_differentWalletsDifferentIds() public view {
        assertTrue(registry.walletCreatorId(walletA) != registry.walletCreatorId(walletB));
    }

    function test_xCreatorId_deterministic() public view {
        bytes32 id = registry.xCreatorId(X_USER_A);
        assertEq(id, keccak256(abi.encode(ScoopCreatorRegistry.CreatorType.X, X_USER_A)));
    }

    function test_xCreatorId_sameUserSameId() public view {
        assertEq(registry.xCreatorId(X_USER_A), registry.xCreatorId(X_USER_A));
    }

    function test_xCreatorId_differentUsersDifferentIds() public view {
        assertTrue(registry.xCreatorId(X_USER_A) != registry.xCreatorId(X_USER_B));
    }

    function test_walletAndXDomainsDoNotCollideForIdenticalLookingValues() public view {
        // Encode the same numeric bit-pattern under both types; domains must differ.
        uint256 mirrored = uint256(uint160(walletA));
        bytes32 walletId = registry.walletCreatorId(walletA);
        bytes32 xId = registry.xCreatorId(mirrored);
        assertTrue(walletId != xId);
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructorStoresVerificationAuthority() public view {
        assertEq(registry.verificationAuthority(), authority);
    }

    function test_constructorRejectsZeroVerificationAuthority() public {
        vm.expectRevert(ScoopCreatorRegistry.ZeroVerificationAuthority.selector);
        new ScoopCreatorRegistry(address(0));
    }

    // ──────────────────────────────────────────────
    // Unclaimed X
    // ──────────────────────────────────────────────

    function test_unclaimedXResolvesToZero() public view {
        assertEq(registry.xResolvedWallet(X_USER_A), address(0));
        assertEq(registry.resolvedWallet(registry.xCreatorId(X_USER_A)), address(0));
    }

    function test_isXClaimedFalseBeforeClaim() public view {
        assertFalse(registry.isXClaimed(X_USER_A));
        assertFalse(registry.isClaimed(registry.xCreatorId(X_USER_A)));
    }

    // ──────────────────────────────────────────────
    // Valid claim
    // ──────────────────────────────────────────────

    function test_validSignatureClaimsXIdentity() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);

        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);

        assertEq(registry.xResolvedWallet(X_USER_A), walletA);
        assertEq(registry.resolvedWallet(registry.xCreatorId(X_USER_A)), walletA);
        assertTrue(registry.isXClaimed(X_USER_A));
        assertTrue(registry.isClaimed(registry.xCreatorId(X_USER_A)));
    }

    function test_claimedXResolvesToExpectedWallet() public {
        _claim(X_USER_A, walletA);
        assertEq(registry.xResolvedWallet(X_USER_A), walletA);
    }

    function test_isXClaimedTrueAfterClaim() public {
        _claim(X_USER_A, walletA);
        assertTrue(registry.isXClaimed(X_USER_A));
    }

    function test_claimEmitsXIdentityClaimed() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);
        bytes32 creatorId = registry.xCreatorId(X_USER_A);

        vm.expectEmit(true, true, true, true, address(registry));
        emit XIdentityClaimed(creatorId, X_USER_A, walletA);

        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);
    }

    // ──────────────────────────────────────────────
    // Invalid claims
    // ──────────────────────────────────────────────

    function test_zeroXUserIdReverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaim(0, walletA, deadline);

        vm.expectRevert(ScoopCreatorRegistry.ZeroXUserId.selector);
        registry.claimXIdentity(0, walletA, deadline, sig);
    }

    function test_zeroWalletReverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaim(X_USER_A, address(0), deadline);

        vm.expectRevert(ScoopCreatorRegistry.ZeroWallet.selector);
        registry.claimXIdentity(X_USER_A, address(0), deadline, sig);
    }

    function test_expiredAuthorizationReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);

        vm.warp(deadline + 1);

        vm.expectRevert(ScoopCreatorRegistry.ExpiredAuthorization.selector);
        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);
    }

    function test_wrongSignerReverts() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrongSigner");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(X_USER_A, walletA, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);
    }

    function test_malformedSignatureReverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory bad = hex"deadbeef";

        vm.expectRevert(); // ECDSA length / recover error
        registry.claimXIdentity(X_USER_A, walletA, deadline, bad);
    }

    function test_alreadyClaimedCannotBeClaimedAgain() public {
        _claim(X_USER_A, walletA);

        uint256 deadline = block.timestamp + 2 days;
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);

        vm.expectRevert(ScoopCreatorRegistry.IdentityAlreadyClaimed.selector);
        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);
    }

    function test_alreadyClaimedCannotRedirectToDifferentWallet() public {
        _claim(X_USER_A, walletA);

        uint256 deadline = block.timestamp + 2 days;
        bytes memory sig = _signClaim(X_USER_A, walletB, deadline);

        vm.expectRevert(ScoopCreatorRegistry.IdentityAlreadyClaimed.selector);
        registry.claimXIdentity(X_USER_A, walletB, deadline, sig);

        assertEq(registry.xResolvedWallet(X_USER_A), walletA);
    }

    // ──────────────────────────────────────────────
    // Signature domain
    // ──────────────────────────────────────────────

    function test_authorizationCannotBeReusedAgainstAnotherRegistry() public {
        ScoopCreatorRegistry other = new ScoopCreatorRegistry(authority);

        uint256 deadline = block.timestamp + 1 days;
        // Signature bound to `registry`, not `other`.
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);

        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        other.claimXIdentity(X_USER_A, walletA, deadline, sig);

        // Original registry still accepts it.
        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);
        assertEq(registry.xResolvedWallet(X_USER_A), walletA);
        assertEq(other.xResolvedWallet(X_USER_A), address(0));
    }

    function test_authorizationBoundToChainDomainSeparator() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);

        // Change chain id so the registry domain separator no longer matches the signature.
        vm.chainId(block.chainid + 1);

        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);
    }

    // ──────────────────────────────────────────────
    // Permissionless submission
    // ──────────────────────────────────────────────

    function test_thirdPartyMaySubmitValidSignedClaim() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaim(X_USER_A, walletA, deadline);

        vm.prank(relayer);
        registry.claimXIdentity(X_USER_A, walletA, deadline, sig);

        assertEq(registry.xResolvedWallet(X_USER_A), walletA);
        assertTrue(registry.xResolvedWallet(X_USER_A) != relayer);
    }

    // ──────────────────────────────────────────────
    // Wallet creator behaviour
    // ──────────────────────────────────────────────

    function test_walletCreatorIdRequiresNoRegistration() public view {
        bytes32 id = registry.walletCreatorId(walletA);
        assertEq(id, keccak256(abi.encode(ScoopCreatorRegistry.CreatorType.Wallet, walletA)));
        assertEq(registry.resolveWalletCreator(walletA), walletA);
    }

    function test_walletIdentityRequiresNoVerifierSignature() public view {
        // Intrinsic resolution — no claim / signature path exists for wallets.
        assertEq(registry.resolveWalletCreator(walletB), walletB);
    }

    function test_noMethodToRedirectWalletIdentity() public {
        (bool setOk,) = address(registry).call(abi.encodeWithSignature("setWallet(address,address)", walletA, walletB));
        (bool rebindOk,) =
            address(registry).call(abi.encodeWithSignature("rebindWalletCreator(bytes32,address)", bytes32(0), walletB));
        (bool changeOk,) =
            address(registry).call(abi.encodeWithSignature("changeWallet(bytes32,address)", bytes32(0), walletB));
        (bool transferOk,) = address(registry)
            .call(abi.encodeWithSignature("transferCreatorIdentity(bytes32,address)", bytes32(0), walletB));
        (bool ownerOk,) = address(registry).call(abi.encodeWithSignature("owner()"));

        assertFalse(setOk);
        assertFalse(rebindOk);
        assertFalse(changeOk);
        assertFalse(transferOk);
        assertFalse(ownerOk);

        // Wallet creator ID still encodes the original wallet only.
        assertEq(registry.resolveWalletCreator(walletA), walletA);
        assertTrue(registry.walletCreatorId(walletA) != registry.walletCreatorId(walletB));
    }

    function test_resolveWalletCreatorRejectsZero() public {
        vm.expectRevert(ScoopCreatorRegistry.ZeroWallet.selector);
        registry.resolveWalletCreator(address(0));
    }

    // ──────────────────────────────────────────────
    // Fuzz
    // ──────────────────────────────────────────────

    function testFuzz_walletCreatorIdDeterministic(address wallet) public view {
        assertEq(registry.walletCreatorId(wallet), registry.walletCreatorId(wallet));
        assertEq(
            registry.walletCreatorId(wallet), keccak256(abi.encode(ScoopCreatorRegistry.CreatorType.Wallet, wallet))
        );
    }

    function testFuzz_xCreatorIdDeterministic(uint256 xUserId) public view {
        assertEq(registry.xCreatorId(xUserId), registry.xCreatorId(xUserId));
        assertEq(registry.xCreatorId(xUserId), keccak256(abi.encode(ScoopCreatorRegistry.CreatorType.X, xUserId)));
    }

    function testFuzz_validSignedClaim(uint256 xUserId, address wallet, uint256 deadlineOffset) public {
        vm.assume(xUserId != 0);
        vm.assume(wallet != address(0));
        // Avoid colliding with previously claimed ids within this fuzz run by using unique ids —
        // each fuzz call gets a fresh setUp, so no cross-run collision.
        deadlineOffset = bound(deadlineOffset, 1, 365 days);
        uint256 deadline = block.timestamp + deadlineOffset;

        bytes memory sig = _signClaim(xUserId, wallet, deadline);
        registry.claimXIdentity(xUserId, wallet, deadline, sig);

        assertEq(registry.xResolvedWallet(xUserId), wallet);
        assertTrue(registry.isXClaimed(xUserId));
        assertEq(registry.resolvedWallet(registry.xCreatorId(xUserId)), wallet);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _signClaim(uint256 xUserId, address wallet, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = registry.hashClaimXIdentity(xUserId, wallet, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _claim(uint256 xUserId, address wallet) internal {
        uint256 deadline = block.timestamp + 1 days;
        registry.claimXIdentity(xUserId, wallet, deadline, _signClaim(xUserId, wallet, deadline));
    }
}
