// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";

/// @dev Test-only recipient that rejects native ETH.
contract RejectETHDest {
    receive() external payable {
        revert("no eth");
    }
}

/**
 * @notice Local integration: ScoopFeeDistributor → ScoopCreatorRewards credit → claim.
 */
contract FeeDistributorCreatorRewardsTest is Test {
    uint16 constant CREATOR_REWARDS_BPS = 7000;
    uint16 constant DEPLOYER_BPS = 400;
    uint16 constant BUYBACK_BPS = 2000;
    uint16 constant OPERATIONS_BPS = 600;

    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopFeeDistributor distributor;
    ScoopTestToken token;

    address authority;
    uint256 authorityKey;
    address registrar;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address walletCreator;
    address relayer;
    address attacker;

    bytes32 walletCreatorId;
    bytes32 xCreatorId;
    uint256 constant X_USER = 424242;

    function setUp() public {
        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        registrar = makeAddr("sourceRegistrar");
        deployerRecipient = makeAddr("scoopDeployerReward");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        walletCreator = makeAddr("walletCreator");
        relayer = makeAddr("relayer");
        attacker = makeAddr("attacker");

        registry = new ScoopCreatorRegistry(authority);
        rewards = new ScoopCreatorRewards(address(registry), registrar);

        distributor = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );

        walletCreatorId = registry.walletCreatorId(walletCreator);
        xCreatorId = registry.xCreatorId(X_USER);

        token = new ScoopTestToken("Scoop Test", "SCOOPT", address(this), 1_000_000_000 ether);
    }

    function _registerWalletSource() internal {
        vm.prank(registrar);
        rewards.registerSource(address(distributor), walletCreatorId);
    }

    function _registerXSource() internal {
        vm.prank(registrar);
        rewards.registerSource(address(distributor), xCreatorId);
    }

    function _claimX(address wallet) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(X_USER, wallet, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, digest);
        registry.claimXIdentity(X_USER, wallet, deadline, abi.encodePacked(r, s, v));
    }

    // ──────────────────────────────────────────────
    // ETH distribution
    // ──────────────────────────────────────────────

    function test_distributeETH_creditsCreatorRewardsAndDirectLegs() public {
        _registerWalletSource();
        vm.deal(address(distributor), 1 ether);

        uint256 creatorBefore = walletCreator.balance;

        distributor.distributeETH();

        assertEq(rewards.claimableETH(walletCreatorId), 0.7 ether);
        assertEq(address(rewards).balance, 0.7 ether);
        assertEq(deployerRecipient.balance, 0.04 ether);
        assertEq(buybackVault.balance, 0.2 ether);
        assertEq(operations.balance, 0.06 ether);
        assertEq(address(distributor).balance, 0);
        assertEq(walletCreator.balance, creatorBefore);
    }

    function test_distributeETH_thenWalletClaim() public {
        _registerWalletSource();
        vm.deal(address(distributor), 1 ether);
        distributor.distributeETH();

        uint256 beforeBal = walletCreator.balance;
        vm.prank(relayer);
        rewards.claimETH(walletCreatorId, walletCreator);

        assertEq(walletCreator.balance, beforeBal + 0.7 ether);
        assertEq(relayer.balance, 0);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
        assertEq(address(rewards).balance, 0);
    }

    function test_permissionlessDistributeDoesNotAffectAttribution() public {
        _registerWalletSource();
        vm.deal(address(distributor), 1 ether);

        vm.prank(attacker);
        distributor.distributeETH();

        assertEq(rewards.sourceCreatorId(address(distributor)), walletCreatorId);
        assertEq(rewards.claimableETH(walletCreatorId), 0.7 ether);
        assertEq(rewards.claimableETH(registry.walletCreatorId(attacker)), 0);
    }

    // ──────────────────────────────────────────────
    // ERC20 distribution
    // ──────────────────────────────────────────────

    function test_distributeToken_creditsCreatorRewardsAndDirectLegs() public {
        _registerWalletSource();
        token.transfer(address(distributor), 100 ether);

        uint256 creatorTokBefore = token.balanceOf(walletCreator);

        distributor.distributeToken(address(token));

        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 70 ether);
        assertEq(token.balanceOf(address(rewards)), 70 ether);
        assertEq(token.balanceOf(deployerRecipient), 4 ether);
        assertEq(token.balanceOf(buybackVault), 20 ether);
        assertEq(token.balanceOf(operations), 6 ether);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(walletCreator), creatorTokBefore);
        assertEq(token.allowance(address(distributor), address(rewards)), 0);
    }

    function test_distributeToken_thenWalletClaim() public {
        _registerWalletSource();
        token.transfer(address(distributor), 100 ether);
        distributor.distributeToken(address(token));

        rewards.claimToken(walletCreatorId, address(token), walletCreator);
        assertEq(token.balanceOf(walletCreator), 70 ether);
        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 0);
    }

    // ──────────────────────────────────────────────
    // X lifecycle
    // ──────────────────────────────────────────────

    function test_xUnclaimedAccruesThenClaimAfterVerification() public {
        _registerXSource();
        vm.deal(address(distributor), 1 ether);
        token.transfer(address(distributor), 100 ether);

        distributor.distributeETH();
        distributor.distributeToken(address(token));

        assertEq(rewards.claimableETH(xCreatorId), 0.7 ether);
        assertEq(rewards.claimableToken(xCreatorId, address(token)), 70 ether);
        assertFalse(registry.isXClaimed(X_USER));

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(xCreatorId, walletCreator);

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimToken(xCreatorId, address(token), walletCreator);

        _claimX(walletCreator);

        uint256 ethBefore = walletCreator.balance;
        uint256 tokBefore = token.balanceOf(walletCreator);

        vm.prank(relayer);
        rewards.claimETH(xCreatorId, address(0));
        vm.prank(relayer);
        rewards.claimToken(xCreatorId, address(token), attacker);

        assertEq(walletCreator.balance, ethBefore + 0.7 ether);
        assertEq(token.balanceOf(walletCreator), tokBefore + 70 ether);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(relayer.balance, 0);
    }

    // ──────────────────────────────────────────────
    // Source registration security
    // ──────────────────────────────────────────────

    function test_unregisteredDistributorCannotCreditOnDistribute() public {
        vm.deal(address(distributor), 1 ether);
        vm.expectRevert(ScoopCreatorRewards.UnregisteredSource.selector);
        distributor.distributeETH();
        assertEq(address(distributor).balance, 1 ether);
    }

    function test_registeredDistributorCreditsOnlyAssignedCreatorId() public {
        _registerWalletSource();
        vm.deal(address(distributor), 1 ether);
        distributor.distributeETH();
        assertEq(rewards.claimableETH(walletCreatorId), 0.7 ether);
        assertEq(rewards.claimableETH(xCreatorId), 0);
    }

    function test_distributorCannotRedirectCreatorRewards() public {
        _registerWalletSource();
        assertEq(rewards.sourceCreatorId(address(distributor)), walletCreatorId);

        // No API on distributor to set creatorId; re-registration blocked.
        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        rewards.registerSource(address(distributor), xCreatorId);

        vm.deal(address(distributor), 1 ether);
        distributor.distributeETH();
        assertEq(rewards.claimableETH(walletCreatorId), 0.7 ether);
        assertEq(rewards.claimableETH(xCreatorId), 0);
    }

    function test_registrarCannotReassignSource() public {
        _registerWalletSource();
        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        rewards.registerSource(address(distributor), xCreatorId);
    }

    function test_deployerCannotAlterCreatorAttribution() public {
        _registerWalletSource();
        vm.prank(deployerRecipient);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        rewards.registerSource(address(distributor), xCreatorId);
        assertEq(rewards.sourceCreatorId(address(distributor)), walletCreatorId);
    }

    // ──────────────────────────────────────────────
    // Failure atomicity
    // ──────────────────────────────────────────────

    function test_ethDistributeRevertsAtomicallyIfDeployerRejects() public {
        RejectETHDest rejector = new RejectETHDest();
        ScoopFeeDistributor hostile = new ScoopFeeDistributor(
            address(rewards),
            address(rejector),
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );

        vm.prank(registrar);
        rewards.registerSource(address(hostile), walletCreatorId);

        vm.deal(address(hostile), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopFeeDistributor.NativeTransferFailed.selector, address(rejector), uint256(0.04 ether)
            )
        );
        hostile.distributeETH();

        assertEq(address(hostile).balance, 1 ether);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
        assertEq(address(rewards).balance, 0);
        assertEq(buybackVault.balance, 0);
        assertEq(operations.balance, 0);
    }

    function test_tokenDistributeRevertsAtomicallyIfUnregistered() public {
        token.transfer(address(distributor), 100 ether);
        vm.expectRevert(ScoopCreatorRewards.UnregisteredSource.selector);
        distributor.distributeToken(address(token));
        assertEq(token.balanceOf(address(distributor)), 100 ether);
        assertEq(token.balanceOf(deployerRecipient), 0);
        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 0);
    }

    receive() external payable {}
}
