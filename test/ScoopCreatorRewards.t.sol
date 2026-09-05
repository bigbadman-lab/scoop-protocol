// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";

/// @dev Test-only recipient that rejects native ETH.
contract RejectETH {
    receive() external payable {
        revert("no eth");
    }
}

/// @dev Transfers less than requested (10% fee) to exercise balance-delta accounting.
contract FeeOnTransferToken is ERC20 {
    constructor(address mintTo) ERC20("Fee Token", "FEE") {
        _mint(mintTo, 1_000_000 ether);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 10;
        uint256 send = amount - fee;
        _transfer(msg.sender, address(0xdead), fee);
        _transfer(msg.sender, to, send);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = amount / 10;
        uint256 send = amount - fee;
        _transfer(from, address(0xdead), fee);
        _transfer(from, to, send);
        return true;
    }
}

contract ScoopCreatorRewardsTest is Test {
    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopTestToken token;

    address authority;
    uint256 authorityKey;
    address registrar;
    address sourceA;
    address sourceB;
    address walletCreator;
    address otherWallet;
    address relayer;
    address attacker;

    uint256 constant X_USER = 123456789;

    bytes32 walletCreatorId;
    bytes32 xCreatorId;

    event SourceRegistered(address indexed source, bytes32 indexed creatorId);
    event ETHCredited(bytes32 indexed creatorId, address indexed source, uint256 amount);
    event TokenCredited(bytes32 indexed creatorId, address indexed source, address indexed token, uint256 amount);
    event ETHClaimed(bytes32 indexed creatorId, address indexed wallet, uint256 amount);
    event TokenClaimed(bytes32 indexed creatorId, address indexed wallet, address indexed token, uint256 amount);

    function setUp() public {
        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        registrar = makeAddr("sourceRegistrar");
        sourceA = makeAddr("sourceA");
        sourceB = makeAddr("sourceB");
        walletCreator = makeAddr("walletCreator");
        otherWallet = makeAddr("otherWallet");
        relayer = makeAddr("relayer");
        attacker = makeAddr("attacker");

        registry = new ScoopCreatorRegistry(authority);
        rewards = new ScoopCreatorRewards(address(registry), registrar);
        token = new ScoopTestToken("Scoop Test", "SCOOPT", address(this), 1_000_000_000 ether);

        walletCreatorId = registry.walletCreatorId(walletCreator);
        xCreatorId = registry.xCreatorId(X_USER);

        vm.deal(sourceA, 100 ether);
        vm.deal(sourceB, 100 ether);
        token.transfer(sourceA, 1_000_000 ether);
        token.transfer(sourceB, 1_000_000 ether);
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    function test_constructorStoresCreatorRegistry() public view {
        assertEq(rewards.creatorRegistry(), address(registry));
    }

    function test_constructorStoresSourceRegistrar() public view {
        assertEq(rewards.sourceRegistrar(), registrar);
    }

    function test_constructorRejectsZeroCreatorRegistry() public {
        vm.expectRevert(ScoopCreatorRewards.ZeroCreatorRegistry.selector);
        new ScoopCreatorRewards(address(0), registrar);
    }

    function test_constructorRejectsZeroSourceRegistrar() public {
        vm.expectRevert(ScoopCreatorRewards.ZeroSourceRegistrar.selector);
        new ScoopCreatorRewards(address(registry), address(0));
    }

    // ──────────────────────────────────────────────
    // Source registration
    // ──────────────────────────────────────────────

    function test_registrarCanRegisterSource() public {
        vm.expectEmit(true, true, false, true, address(rewards));
        emit SourceRegistered(sourceA, walletCreatorId);

        vm.prank(registrar);
        rewards.registerSource(sourceA, walletCreatorId);

        assertEq(rewards.sourceCreatorId(sourceA), walletCreatorId);
    }

    function test_nonRegistrarCannotRegisterSource() public {
        vm.prank(attacker);
        vm.expectRevert(ScoopCreatorRewards.UnauthorizedRegistrar.selector);
        rewards.registerSource(sourceA, walletCreatorId);
    }

    function test_zeroSourceRejected() public {
        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.ZeroSource.selector);
        rewards.registerSource(address(0), walletCreatorId);
    }

    function test_zeroCreatorIdRejected() public {
        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.ZeroCreatorId.selector);
        rewards.registerSource(sourceA, bytes32(0));
    }

    function test_duplicateSourceRegistrationRejected() public {
        _register(sourceA, walletCreatorId);

        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        rewards.registerSource(sourceA, walletCreatorId);
    }

    function test_registeredSourceCannotBeReassigned() public {
        _register(sourceA, walletCreatorId);

        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        rewards.registerSource(sourceA, xCreatorId);

        assertEq(rewards.sourceCreatorId(sourceA), walletCreatorId);
    }

    function test_multipleSourcesCanMapToSameCreatorId() public {
        _register(sourceA, xCreatorId);
        _register(sourceB, xCreatorId);
        assertEq(rewards.sourceCreatorId(sourceA), xCreatorId);
        assertEq(rewards.sourceCreatorId(sourceB), xCreatorId);
    }

    // ──────────────────────────────────────────────
    // ETH credit
    // ──────────────────────────────────────────────

    function test_registeredSourceCanCreditETH() public {
        _register(sourceA, walletCreatorId);

        vm.expectEmit(true, true, false, true, address(rewards));
        emit ETHCredited(walletCreatorId, sourceA, 1 ether);

        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        assertEq(rewards.claimableETH(walletCreatorId), 1 ether);
        assertEq(address(rewards).balance, 1 ether);
    }

    function test_ethCreditIncrementsCorrectCreatorId() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 0.5 ether}();
        assertEq(rewards.claimableETH(walletCreatorId), 0.5 ether);
        assertEq(rewards.claimableETH(xCreatorId), 0);
    }

    function test_unregisteredSourceCannotCreditETH() public {
        vm.prank(sourceA);
        vm.expectRevert(ScoopCreatorRewards.UnregisteredSource.selector);
        rewards.creditETH{value: 1 ether}();
    }

    function test_zeroETHCreditReverts() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        vm.expectRevert(ScoopCreatorRewards.ZeroAmount.selector);
        rewards.creditETH{value: 0}();
    }

    function test_sourceCannotChooseAnotherCreatorId() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();
        // Credit always lands on registered creator, never attacker-chosen id.
        assertEq(rewards.claimableETH(walletCreatorId), 1 ether);
        assertEq(rewards.claimableETH(xCreatorId), 0);
        assertEq(rewards.claimableETH(registry.walletCreatorId(attacker)), 0);
    }

    function test_multipleETHCreditsAccumulate() public {
        _register(sourceA, walletCreatorId);
        vm.startPrank(sourceA);
        rewards.creditETH{value: 1 ether}();
        rewards.creditETH{value: 2 ether}();
        vm.stopPrank();
        assertEq(rewards.claimableETH(walletCreatorId), 3 ether);
    }

    function test_multipleSourcesAggregateETHForSameCreator() public {
        _register(sourceA, xCreatorId);
        _register(sourceB, xCreatorId);

        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();
        vm.prank(sourceB);
        rewards.creditETH{value: 3 ether}();

        assertEq(rewards.claimableETH(xCreatorId), 4 ether);
    }

    // ──────────────────────────────────────────────
    // Token credit
    // ──────────────────────────────────────────────

    function test_registeredSourceCanCreditERC20() public {
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, 100 ether);

        vm.expectEmit(true, true, true, true, address(rewards));
        emit TokenCredited(walletCreatorId, sourceA, address(token), 100 ether);

        vm.prank(sourceA);
        rewards.creditToken(address(token), 100 ether);

        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 100 ether);
        assertEq(token.balanceOf(address(rewards)), 100 ether);
    }

    function test_tokenCreditIncrementsCorrectCreatorIdToken() public {
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, 50 ether);
        vm.prank(sourceA);
        rewards.creditToken(address(token), 50 ether);
        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 50 ether);
        assertEq(rewards.claimableToken(xCreatorId, address(token)), 0);
    }

    function test_unregisteredSourceCannotCreditToken() public {
        _approveToken(sourceA, 10 ether);
        vm.prank(sourceA);
        vm.expectRevert(ScoopCreatorRewards.UnregisteredSource.selector);
        rewards.creditToken(address(token), 10 ether);
    }

    function test_zeroTokenAddressReverts() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        vm.expectRevert(ScoopCreatorRewards.ZeroToken.selector);
        rewards.creditToken(address(0), 1 ether);
    }

    function test_zeroTokenAmountReverts() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        vm.expectRevert(ScoopCreatorRewards.ZeroAmount.selector);
        rewards.creditToken(address(token), 0);
    }

    function test_multipleTokenCreditsAccumulate() public {
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, 30 ether);
        vm.startPrank(sourceA);
        rewards.creditToken(address(token), 10 ether);
        rewards.creditToken(address(token), 20 ether);
        vm.stopPrank();
        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 30 ether);
    }

    function test_multipleSourcesAggregateTokensForSameCreator() public {
        _register(sourceA, xCreatorId);
        _register(sourceB, xCreatorId);
        _approveToken(sourceA, 10 ether);
        _approveToken(sourceB, 15 ether);

        vm.prank(sourceA);
        rewards.creditToken(address(token), 10 ether);
        vm.prank(sourceB);
        rewards.creditToken(address(token), 15 ether);

        assertEq(rewards.claimableToken(xCreatorId, address(token)), 25 ether);
    }

    function test_tokenAccountingUsesActualReceivedAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken(sourceA);
        _register(sourceA, walletCreatorId);

        vm.startPrank(sourceA);
        feeToken.approve(address(rewards), 100 ether);
        rewards.creditToken(address(feeToken), 100 ether);
        vm.stopPrank();

        // 10% fee on transfer → 90 credited.
        assertEq(rewards.claimableToken(walletCreatorId, address(feeToken)), 90 ether);
        assertEq(feeToken.balanceOf(address(rewards)), 90 ether);
    }

    // ──────────────────────────────────────────────
    // Wallet creator claim
    // ──────────────────────────────────────────────

    function test_walletCreatorCanHaveRewardsCredited() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();
        assertEq(rewards.claimableETH(walletCreatorId), 1 ether);
    }

    function test_walletCreatorETHClaimPaysIntrinsicWallet() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        uint256 beforeBal = walletCreator.balance;
        rewards.claimETH(walletCreatorId, walletCreator);
        assertEq(walletCreator.balance, beforeBal + 1 ether);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
    }

    function test_walletCreatorTokenClaimPaysIntrinsicWallet() public {
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, 40 ether);
        vm.prank(sourceA);
        rewards.creditToken(address(token), 40 ether);

        rewards.claimToken(walletCreatorId, address(token), walletCreator);
        assertEq(token.balanceOf(walletCreator), 40 ether);
        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 0);
    }

    function test_thirdPartyCanTriggerWalletCreatorClaim() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        uint256 relayerBefore = relayer.balance;
        uint256 creatorBefore = walletCreator.balance;

        vm.prank(relayer);
        rewards.claimETH(walletCreatorId, walletCreator);

        assertEq(relayer.balance, relayerBefore);
        assertEq(walletCreator.balance, creatorBefore + 1 ether);
    }

    function test_thirdPartyCallerReceivesNothingOnTokenClaim() public {
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, 10 ether);
        vm.prank(sourceA);
        rewards.creditToken(address(token), 10 ether);

        uint256 relayerBefore = token.balanceOf(relayer);
        vm.prank(relayer);
        rewards.claimToken(walletCreatorId, address(token), walletCreator);

        assertEq(token.balanceOf(relayer), relayerBefore);
        assertEq(token.balanceOf(walletCreator), 10 ether);
    }

    function test_ethAccountingZeroAfterClaim() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 2 ether}();
        rewards.claimETH(walletCreatorId, walletCreator);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
        assertEq(address(rewards).balance, 0);
    }

    function test_tokenAccountingZeroAfterClaim() public {
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, 7 ether);
        vm.prank(sourceA);
        rewards.creditToken(address(token), 7 ether);
        rewards.claimToken(walletCreatorId, address(token), walletCreator);
        assertEq(rewards.claimableToken(walletCreatorId, address(token)), 0);
    }

    function test_zeroClaimableBalanceReverts() public {
        vm.expectRevert(ScoopCreatorRewards.ZeroClaimableBalance.selector);
        rewards.claimETH(walletCreatorId, walletCreator);

        vm.expectRevert(ScoopCreatorRewards.ZeroClaimableBalance.selector);
        rewards.claimToken(walletCreatorId, address(token), walletCreator);
    }

    // ──────────────────────────────────────────────
    // X creator lifecycle
    // ──────────────────────────────────────────────

    function test_unclaimedXCanAccrueETH() public {
        _register(sourceA, xCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();
        assertEq(rewards.claimableETH(xCreatorId), 1 ether);
    }

    function test_unclaimedXCanAccrueERC20() public {
        _register(sourceA, xCreatorId);
        _approveToken(sourceA, 11 ether);
        vm.prank(sourceA);
        rewards.creditToken(address(token), 11 ether);
        assertEq(rewards.claimableToken(xCreatorId, address(token)), 11 ether);
    }

    function test_unclaimedXBalancesAreVisible() public {
        _register(sourceA, xCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 0.25 ether}();
        assertEq(rewards.claimableETH(xCreatorId), 0.25 ether);
        assertFalse(registry.isXClaimed(X_USER));
    }

    function test_unclaimedXCannotClaimETH() public {
        _register(sourceA, xCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(xCreatorId, otherWallet);
    }

    function test_unclaimedXCannotClaimToken() public {
        _register(sourceA, xCreatorId);
        _approveToken(sourceA, 5 ether);
        vm.prank(sourceA);
        rewards.creditToken(address(token), 5 ether);

        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimToken(xCreatorId, address(token), otherWallet);
    }

    function test_xVerificationThenClaimPreviouslyAccruedWithoutMigration() public {
        _register(sourceA, xCreatorId);
        _register(sourceB, xCreatorId);

        vm.prank(sourceA);
        rewards.creditETH{value: 2 ether}();
        _approveToken(sourceB, 30 ether);
        vm.prank(sourceB);
        rewards.creditToken(address(token), 30 ether);

        assertEq(rewards.claimableETH(xCreatorId), 2 ether);
        assertEq(rewards.claimableToken(xCreatorId, address(token)), 30 ether);

        // Complete X verification in registry — no rewards migration.
        _claimX(X_USER, walletCreator);
        assertEq(registry.xResolvedWallet(X_USER), walletCreator);

        uint256 ethBefore = walletCreator.balance;
        uint256 tokBefore = token.balanceOf(walletCreator);

        vm.prank(relayer);
        rewards.claimETH(xCreatorId, address(0)); // candidate ignored once X bound
        vm.prank(relayer);
        rewards.claimToken(xCreatorId, address(token), attacker); // candidate ignored

        assertEq(walletCreator.balance, ethBefore + 2 ether);
        assertEq(token.balanceOf(walletCreator), tokBefore + 30 ether);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(relayer.balance, 0);
        assertEq(rewards.claimableETH(xCreatorId), 0);
        assertEq(rewards.claimableToken(xCreatorId, address(token)), 0);
    }

    // ──────────────────────────────────────────────
    // Security
    // ──────────────────────────────────────────────

    function test_maliciousCallerCannotClaimAnotherCreatorsFundsToThemselves() public {
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        // Attacker supplies their own address as candidate — walletCreatorId mismatch → unresolved
        // if they also swap creatorId... using wallet creator's id with attacker candidate fails.
        vm.prank(attacker);
        vm.expectRevert(ScoopCreatorRewards.CreatorUnresolved.selector);
        rewards.claimETH(walletCreatorId, attacker);

        // Funds still claimable by the real wallet.
        assertEq(rewards.claimableETH(walletCreatorId), 1 ether);
        rewards.claimETH(walletCreatorId, walletCreator);
        assertEq(walletCreator.balance, 1 ether);
    }

    function test_sourceCannotChangeCreatorAttribution() public {
        _register(sourceA, walletCreatorId);
        vm.prank(registrar);
        vm.expectRevert(ScoopCreatorRewards.SourceAlreadyRegistered.selector);
        rewards.registerSource(sourceA, xCreatorId);
        assertEq(rewards.sourceCreatorId(sourceA), walletCreatorId);
    }

    function test_failedETHPayoutRevertsAtomicallyAndPreservesAccounting() public {
        RejectETH rejector = new RejectETH();
        bytes32 rejectorId = registry.walletCreatorId(address(rejector));
        _register(sourceA, rejectorId);

        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopCreatorRewards.NativeTransferFailed.selector, address(rejector), uint256(1 ether)
            )
        );
        rewards.claimETH(rejectorId, address(rejector));

        assertEq(rewards.claimableETH(rejectorId), 1 ether);
        assertEq(address(rewards).balance, 1 ether);
    }

    function test_noOwnerAdminRescueSurface() public {
        (bool ownerOk,) = address(rewards).call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = address(rewards).call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        (bool rescueEthOk,) = address(rewards).call(abi.encodeWithSignature("rescueETH(address)", attacker));
        (bool rescueTokOk,) =
            address(rewards).call(abi.encodeWithSignature("rescueToken(address,address)", address(token), attacker));
        (bool setRegOk,) = address(rewards).call(abi.encodeWithSignature("setSourceRegistrar(address)", attacker));
        (bool setRegistryOk,) = address(rewards).call(abi.encodeWithSignature("setCreatorRegistry(address)", attacker));
        (bool unregOk,) = address(rewards).call(abi.encodeWithSignature("unregisterSource(address)", sourceA));

        assertFalse(ownerOk);
        assertFalse(adminOk);
        assertFalse(rescueEthOk);
        assertFalse(rescueTokOk);
        assertFalse(setRegOk);
        assertFalse(setRegistryOk);
        assertFalse(unregOk);
    }

    function test_plainETHTransferReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(rewards).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_resolvePayoutWallet_registryHelper() public view {
        assertEq(registry.resolvePayoutWallet(walletCreatorId, walletCreator), walletCreator);
        assertEq(registry.resolvePayoutWallet(walletCreatorId, otherWallet), address(0));
        assertEq(registry.resolvePayoutWallet(xCreatorId, otherWallet), address(0));
    }

    // ──────────────────────────────────────────────
    // Fuzz
    // ──────────────────────────────────────────────

    function testFuzz_repeatedETHCreditsSum(uint256 a, uint256 b) public {
        a = bound(a, 1, 20 ether);
        b = bound(b, 1, 20 ether);
        _register(sourceA, walletCreatorId);

        vm.startPrank(sourceA);
        rewards.creditETH{value: a}();
        rewards.creditETH{value: b}();
        vm.stopPrank();

        assertEq(rewards.claimableETH(walletCreatorId), a + b);
    }

    function testFuzz_repeatedERC20CreditsSum(uint256 a, uint256 b) public {
        a = bound(a, 1, 100_000 ether);
        b = bound(b, 1, 100_000 ether);
        _register(sourceA, walletCreatorId);
        _approveToken(sourceA, a + b);

        vm.startPrank(sourceA);
        rewards.creditToken(address(token), a);
        rewards.creditToken(address(token), b);
        vm.stopPrank();

        assertEq(rewards.claimableToken(walletCreatorId, address(token)), a + b);
    }

    function testFuzz_claimPaysExactlyAccruedETH(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        _register(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: amount}();

        uint256 beforeBal = walletCreator.balance;
        rewards.claimETH(walletCreatorId, walletCreator);
        assertEq(walletCreator.balance - beforeBal, amount);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
    }

    function testFuzz_multiSourceAggregation(uint256 a, uint256 b) public {
        a = bound(a, 1, 20 ether);
        b = bound(b, 1, 20 ether);
        _register(sourceA, xCreatorId);
        _register(sourceB, xCreatorId);

        vm.prank(sourceA);
        rewards.creditETH{value: a}();
        vm.prank(sourceB);
        rewards.creditETH{value: b}();

        assertEq(rewards.claimableETH(xCreatorId), a + b);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _register(address source, bytes32 creatorId) internal {
        vm.prank(registrar);
        rewards.registerSource(source, creatorId);
    }

    function _approveToken(address source, uint256 amount) internal {
        vm.prank(source);
        token.approve(address(rewards), amount);
    }

    function _claimX(uint256 xUserId, address wallet) internal {
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(xUserId, wallet, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(authorityKey, digest);
        registry.claimXIdentity(xUserId, wallet, deadline, abi.encodePacked(r, s, v));
    }

    receive() external payable {}
}
