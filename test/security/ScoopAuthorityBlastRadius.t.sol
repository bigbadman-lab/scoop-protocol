// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopSecurityLocalBase} from "./ScoopSecurityLocalBase.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/**
 * @notice Documents/tests authority blast radius for registry / oracle / verification.
 *
 * Expected HIGH blast radius: compromised `verificationAuthority` can bind any unclaimed
 * X identity to an attacker wallet, unlocking accrued creator rewards for that X id.
 *
 * Authorities CANNOT: move already-claimed X bindings, change sourceCreatorId, redirect
 * wallet-creator payouts, change FeeDistributor destinations, or upgrade contracts.
 */
contract ScoopAuthorityBlastRadiusTest is ScoopSecurityLocalBase {
    function test_registryAuthority_canRegisterAndDisableQuotes() public {
        address asset = address(0xA11CE);
        vm.prank(registryAuthority);
        quoteRegistry.registerQuote(asset, ScoopQuoteRegistry.QuoteType.Scoop);
        assertTrue(quoteRegistry.isEnabled(asset));

        vm.prank(registryAuthority);
        quoteRegistry.setQuoteEnabled(asset, false);
        assertFalse(quoteRegistry.isEnabled(asset));
    }

    function test_registryAuthority_cannotChangeQuoteType() public {
        address asset = address(0xB0B);
        vm.startPrank(registryAuthority);
        quoteRegistry.registerQuote(asset, ScoopQuoteRegistry.QuoteType.Stock);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, asset));
        quoteRegistry.registerQuote(asset, ScoopQuoteRegistry.QuoteType.Pons);
        vm.stopPrank();
    }

    function test_oracleAuthority_canConfigureDisableAndSetMaxAge() public {
        MockAggregatorV3 feed = new MockAggregatorV3(8);
        feed.setRound(1, 2e8, 900, 1000, 1);
        address q = address(0xC0FFEE);

        vm.prank(oracleAuthority);
        priceOracle.configureFeed(q, address(feed), 3600);
        assertEq(priceOracle.getPriceUsd(q), 2e18);

        vm.prank(oracleAuthority);
        priceOracle.setMaxAge(q, 7200);
        assertEq(priceOracle.getFeedConfig(q).maxAge, 7200);

        vm.prank(oracleAuthority);
        priceOracle.setFeedEnabled(q, false);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedDisabled.selector, q));
        priceOracle.getPriceUsd(q);
    }

    function test_oracleAuthority_cannotReplaceFeedIdentity() public {
        MockAggregatorV3 other = new MockAggregatorV3(8);
        vm.prank(oracleAuthority);
        vm.expectRevert(abi.encodeWithSelector(ScoopPriceOracle.PriceFeedAlreadyConfigured.selector, address(0)));
        priceOracle.configureFeed(address(0), address(other), 3600);
    }

    function test_verificationAuthority_compromised_canBindUnclaimedX_toAttacker() public {
        // Accrue rewards to unclaimed X before claim.
        _registerSource(sourceA, xCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 5 ether}();
        assertEq(rewards.claimableETH(xCreatorId), 5 ether);
        assertFalse(registry.isXClaimed(X_USER));

        // Compromised verificationAuthority signs attacker wallet.
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signClaimX(X_USER, attacker, deadline);
        registry.claimXIdentity(X_USER, attacker, deadline, sig);

        assertEq(registry.xResolvedWallet(X_USER), attacker);

        uint256 beforeBal = attacker.balance;
        rewards.claimETH(xCreatorId, address(0));
        assertEq(attacker.balance, beforeBal + 5 ether);
        assertEq(rewards.claimableETH(xCreatorId), 0);
        // Documented HIGH blast radius for unclaimed X rewards.
        assertTrue(true, "HIGH: compromised verificationAuthority steals unclaimed X rewards");
    }

    function test_verificationAuthority_cannotRebindAlreadyClaimedX() public {
        _claimX(X_USER, walletCreator);
        uint256 deadline = block.timestamp + 2 days;
        bytes memory sig = _signClaimX(X_USER, attacker, deadline);
        vm.expectRevert(ScoopCreatorRegistry.IdentityAlreadyClaimed.selector);
        registry.claimXIdentity(X_USER, attacker, deadline, sig);
        assertEq(registry.xResolvedWallet(X_USER), walletCreator);
    }

    function test_authorities_cannotMutateSourceCreatorIdOrRewardsAccounting() public {
        _registerSource(sourceA, walletCreatorId);
        assertEq(rewards.sourceCreatorId(sourceA), walletCreatorId);

        (bool okReg,) = address(rewards).call(abi.encodeWithSignature("setSourceRegistrar(address)", attacker));
        assertFalse(okReg);

        vm.prank(registryAuthority);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        rewards.registerSource(makeAddr("src2"), walletCreatorId);

        vm.prank(oracleAuthority);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        rewards.registerSource(makeAddr("src3"), walletCreatorId);

        vm.prank(verificationAuthority);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        rewards.registerSource(makeAddr("src4"), walletCreatorId);

        // Write-once: even registrar cannot rebind.
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        rewards.registerSource(sourceA, xCreatorId);
        assertEq(rewards.sourceCreatorId(sourceA), walletCreatorId);
    }

    function test_verificationAuthority_cannotRedirectWalletCreatorPayout() public {
        _registerSource(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        // No claimX path applies; wallet creator is intrinsic. Authority signature irrelevant.
        vm.prank(relayer);
        rewards.claimETH(walletCreatorId, walletCreator);
        assertEq(walletCreator.balance, 1 ether);
        assertEq(attacker.balance, 0);
    }

    function test_strangers_cannotActAsAnyAuthority() public {
        vm.prank(attacker);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        quoteRegistry.registerQuote(address(0x99), ScoopQuoteRegistry.QuoteType.Scoop);

        vm.prank(attacker);
        vm.expectRevert(ScoopPriceOracle.Unauthorized.selector);
        priceOracle.setMaxAge(address(0), 1);

        // verificationAuthority is not a tx-gated role for claim; signature is the gate.
        uint256 deadline = block.timestamp + 1 days;
        (, uint256 attackerKey) = makeAddrAndKey("attackerKey");
        bytes32 digest = registry.hashClaimXIdentity(X_USER, attacker, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerKey, digest);
        vm.expectRevert(ScoopCreatorRegistry.InvalidSignature.selector);
        registry.claimXIdentity(X_USER, attacker, deadline, abi.encodePacked(r, s, v));
    }
}
