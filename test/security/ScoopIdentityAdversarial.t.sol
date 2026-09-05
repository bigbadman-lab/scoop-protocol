// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";

import {ScoopSecurityLocalBase} from "./ScoopSecurityLocalBase.sol";

/**
 * @notice Adversarial X-identity claim and wallet-creator payout resolution.
 */
contract ScoopIdentityAdversarialTest is ScoopSecurityLocalBase {
    // ──────────────────────────────────────────────
    // X claim adversarial
    // ──────────────────────────────────────────────

    function test_wrongSigner_reverts() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrongSigner");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(X_USER, walletCreator, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        registry.claimXIdentity(X_USER, walletCreator, deadline, abi.encodePacked(r, s, v));
    }

    function test_expiredAuthorization_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signClaimX(X_USER, walletCreator, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(ScoopCreatorRegistry.ExpiredAuthorization.selector);
        registry.claimXIdentity(X_USER, walletCreator, deadline, sig);
    }

    function test_wrongWallet_inSignature_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        // Signature binds otherWallet, but claim attempts walletCreator.
        bytes memory sig = _signClaimX(X_USER, otherWallet, deadline);

        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        registry.claimXIdentity(X_USER, walletCreator, deadline, sig);
    }

    function test_wrongXUserId_inSignature_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 otherX = X_USER + 1;
        bytes memory sig = _signClaimX(otherX, walletCreator, deadline);

        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        registry.claimXIdentity(X_USER, walletCreator, deadline, sig);
    }

    function test_replayAfterClaim_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaimX(X_USER, walletCreator, deadline);
        registry.claimXIdentity(X_USER, walletCreator, deadline, sig);

        vm.expectRevert(ScoopCreatorRegistry.IdentityAlreadyClaimed.selector);
        registry.claimXIdentity(X_USER, walletCreator, deadline, sig);
    }

    function test_zeroWallet_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaimX(X_USER, address(0), deadline);

        vm.expectRevert(ScoopCreatorRegistry.ZeroWallet.selector);
        registry.claimXIdentity(X_USER, address(0), deadline, sig);
    }

    function test_zeroXUserId_reverts() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaimX(0, walletCreator, deadline);

        vm.expectRevert(ScoopCreatorRegistry.ZeroXUserId.selector);
        registry.claimXIdentity(0, walletCreator, deadline, sig);
    }

    function test_rebindToDifferentWallet_fails() public {
        _claimX(X_USER, walletCreator);

        uint256 deadline = block.timestamp + 2 days;
        bytes memory sig = _signClaimX(X_USER, otherWallet, deadline);

        vm.expectRevert(ScoopCreatorRegistry.IdentityAlreadyClaimed.selector);
        registry.claimXIdentity(X_USER, otherWallet, deadline, sig);

        assertEq(registry.resolvedWallet(xCreatorId), walletCreator);
        assertEq(registry.xResolvedWallet(X_USER), walletCreator);
    }

    function test_relayerCanSubmitClaim() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaimX(X_USER, walletCreator, deadline);

        vm.prank(relayer);
        registry.claimXIdentity(X_USER, walletCreator, deadline, sig);

        assertTrue(registry.isXClaimed(X_USER));
        assertEq(registry.resolvedWallet(xCreatorId), walletCreator);
    }

    function test_socialMetadataIrrelevant_toXClaim() public {
        // Registry has no social/handle surface — only xUserId + wallet + authority signature.
        // Token twitter/telegram metadata cannot influence claim validity.
        (bool ok,) = address(registry).call(abi.encodeWithSignature("setTwitter(uint256,string)", X_USER, "hacker"));
        assertFalse(ok);

        _claimX(X_USER, walletCreator);
        assertEq(registry.resolvedWallet(xCreatorId), walletCreator);
    }

    // ──────────────────────────────────────────────
    // Wallet creator payout
    // ──────────────────────────────────────────────

    function test_wrongCandidate_cannotClaimWalletCreatorRewards() public {
        _registerSource(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(walletCreatorId, attacker);

        assertEq(rewards.claimableETH(walletCreatorId), 1 ether);
        assertEq(attacker.balance, 0);
    }

    function test_relayerTriggersClaim_payoutGoesToResolvedWallet() public {
        _registerSource(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        uint256 beforeBal = walletCreator.balance;
        vm.prank(relayer);
        rewards.claimETH(walletCreatorId, walletCreator);

        assertEq(walletCreator.balance, beforeBal + 1 ether);
        assertEq(relayer.balance, 0);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
    }

    function test_xClaim_candidateIgnored_payoutToBoundWallet() public {
        _registerSource(sourceA, xCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 2 ether}();

        _claimX(X_USER, walletCreator);

        uint256 beforeBal = walletCreator.balance;
        // Relayer passes attacker as candidate — ignored for claimed X.
        vm.prank(relayer);
        rewards.claimETH(xCreatorId, attacker);

        assertEq(walletCreator.balance, beforeBal + 2 ether);
        assertEq(attacker.balance, 0);
        assertEq(relayer.balance, 0);
    }
}
