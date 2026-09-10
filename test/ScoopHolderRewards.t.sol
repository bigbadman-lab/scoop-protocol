// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ScoopHolderRewards} from "../src/ScoopHolderRewards.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";
import {ScoopHolderRewardsMerkle} from "./helpers/ScoopHolderRewardsMerkle.sol";

contract RejectETHHolder {
    receive() external payable {
        revert("no eth");
    }
}

contract AcceptETHHolder {
    receive() external payable {}
}

contract ReentrantETHHolder {
    ScoopHolderRewards public vault;
    uint64 public roundId;
    address public asset;
    uint256 public amount;
    bytes32[] public proof;
    bool public attack;

    function setAttack(
        ScoopHolderRewards vault_,
        uint64 roundId_,
        address asset_,
        uint256 amount_,
        bytes32[] memory proof_
    ) external {
        vault = vault_;
        roundId = roundId_;
        asset = asset_;
        amount = amount_;
        delete proof;
        for (uint256 i; i < proof_.length; ++i) {
            proof.push(proof_[i]);
        }
        attack = true;
    }

    receive() external payable {
        if (!attack) return;
        attack = false;
        bytes32[] memory p = proof;
        try vault.claim(roundId, asset, address(this), amount, p) {} catch {}
    }
}

contract ScoopHolderRewardsTest is Test {
    address publisher;
    address launchDeployer;
    address distributor;
    address alice;
    address bob;

    ScoopHolderRewards vault;
    ScoopTestToken token;

    function setUp() public {
        publisher = makeAddr("publisher");
        launchDeployer = makeAddr("launchDeployer");
        distributor = makeAddr("distributor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.prank(launchDeployer);
        // constructor called by anyone; initialize by launchDeployer
        vault = new ScoopHolderRewards(publisher, launchDeployer);
        vm.prank(launchDeployer);
        vault.initializeFeeDistributor(distributor);

        token = new ScoopTestToken("T", "T", address(this), 1_000_000_000 ether);
    }

    function _depositETH(uint256 amount) internal {
        vm.deal(distributor, amount);
        vm.prank(distributor);
        vault.depositETH{value: amount}();
    }

    function _depositToken(uint256 amount) internal {
        token.transfer(distributor, amount);
        vm.startPrank(distributor);
        token.approve(address(vault), amount);
        vault.depositToken(address(token), amount);
        vm.stopPrank();
    }

    function _leaves(uint64 roundId, address asset, ScoopHolderRewardsMerkle.Entitlement[] memory ents)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](ents.length);
        for (uint256 i; i < ents.length; ++i) {
            leaves[i] = ScoopHolderRewardsMerkle.leaf(
                block.chainid, address(vault), roundId, asset, ents[i].account, ents[i].amount
            );
        }
    }

    function test_depositETH_authorized() public {
        _depositETH(10 ether);
        assertEq(vault.uncommitted(address(0)), 10 ether);
        assertEq(vault.totalDeposited(address(0)), 10 ether);
    }

    function test_depositETH_unauthorizedReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ScoopHolderRewards.UnauthorizedDistributor.selector);
        vault.depositETH{value: 1 ether}();
    }

    function test_plainETHReceiveReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
        assertEq(vault.uncommitted(address(0)), 0);
    }

    function test_directERC20TransferDoesNotIncreaseUncommitted() public {
        token.transfer(address(vault), 5 ether);
        assertEq(vault.uncommitted(address(token)), 0);
        assertEq(token.balanceOf(address(vault)), 5 ether);
    }

    function test_depositToken_accumulatesAndIsolatesAssets() public {
        _depositETH(3 ether);
        _depositToken(7 ether);
        assertEq(vault.uncommitted(address(0)), 3 ether);
        assertEq(vault.uncommitted(address(token)), 7 ether);
    }

    function test_publishRound_publisherOnly() public {
        _depositETH(10 ether);
        bytes32 root = bytes32(uint256(1));
        vm.prank(alice);
        vm.expectRevert(ScoopHolderRewards.UnauthorizedPublisher.selector);
        vault.publishRound(1, address(0), root, 1 ether);

        vm.prank(publisher);
        vault.publishRound(1, address(0), root, 4 ether);
        assertEq(vault.uncommitted(address(0)), 6 ether);
        assertEq(vault.outstandingCommitted(address(0)), 4 ether);
        (bytes32 r, uint256 total, bool published) = vault.round(1, address(0));
        assertEq(r, root);
        assertEq(total, 4 ether);
        assertTrue(published);
    }

    function test_publishRound_duplicateReverts() public {
        _depositETH(5 ether);
        vm.startPrank(publisher);
        vault.publishRound(1, address(0), bytes32(uint256(1)), 1 ether);
        vm.expectRevert(ScoopHolderRewards.RoundAlreadyPublished.selector);
        vault.publishRound(1, address(0), bytes32(uint256(2)), 1 ether);
        vm.stopPrank();
    }

    function test_publishRound_sameRoundDifferentAssetOk() public {
        _depositETH(5 ether);
        _depositToken(5 ether);
        vm.startPrank(publisher);
        vault.publishRound(1, address(0), bytes32(uint256(1)), 1 ether);
        vault.publishRound(1, address(token), bytes32(uint256(2)), 1 ether);
        vm.stopPrank();
    }

    function test_publishRound_insufficientUncommittedReverts() public {
        _depositETH(1 ether);
        vm.prank(publisher);
        vm.expectRevert(ScoopHolderRewards.InsufficientUncommitted.selector);
        vault.publishRound(1, address(0), bytes32(uint256(1)), 2 ether);
    }

    function test_claimAndPush_singleLeaf() public {
        _depositETH(10 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](1);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 3 ether);
        bytes32[] memory leaves = _leaves(1, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        bytes32[] memory proof = ScoopHolderRewardsMerkle.proof(leaves, 0);

        vm.prank(publisher);
        vault.publishRound(1, address(0), root, 3 ether);

        uint256 before = alice.balance;
        vm.prank(bob); // relayer
        vault.claim(1, address(0), alice, 3 ether, proof);
        assertEq(alice.balance - before, 3 ether);
        assertTrue(vault.isPaid(1, address(0), alice));
        assertEq(vault.outstandingCommitted(address(0)), 0);

        vm.expectRevert(ScoopHolderRewards.AlreadyPaid.selector);
        vault.claim(1, address(0), alice, 3 ether, proof);
    }

    function test_pushThenClaimCannotDoublePay() public {
        _depositETH(5 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](1);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 2 ether);
        bytes32[] memory leaves = _leaves(2, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        bytes32[] memory proof = ScoopHolderRewardsMerkle.proof(leaves, 0);
        vm.prank(publisher);
        vault.publishRound(2, address(0), root, 2 ether);

        ScoopHolderRewards.Payout[] memory payouts = new ScoopHolderRewards.Payout[](1);
        payouts[0] = ScoopHolderRewards.Payout(alice, 2 ether, proof);
        vault.pushBatch(2, address(0), payouts);
        assertEq(alice.balance, 2 ether);

        vm.expectRevert(ScoopHolderRewards.AlreadyPaid.selector);
        vault.claim(2, address(0), alice, 2 ether, proof);
    }

    function test_claimThenPushCannotDoublePay() public {
        _depositETH(5 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](1);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 2 ether);
        bytes32[] memory leaves = _leaves(3, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        bytes32[] memory proof = ScoopHolderRewardsMerkle.proof(leaves, 0);
        vm.prank(publisher);
        vault.publishRound(3, address(0), root, 2 ether);

        vault.claim(3, address(0), alice, 2 ether, proof);

        ScoopHolderRewards.Payout[] memory payouts = new ScoopHolderRewards.Payout[](1);
        payouts[0] = ScoopHolderRewards.Payout(alice, 2 ether, proof);
        vm.recordLogs();
        vault.pushBatch(3, address(0), payouts);
        // still only 2 ether to alice
        assertEq(alice.balance, 2 ether);
    }

    function test_wrongAccountProofFails() public {
        _depositETH(5 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](1);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 1 ether);
        bytes32[] memory leaves = _leaves(4, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        bytes32[] memory proof = ScoopHolderRewardsMerkle.proof(leaves, 0);
        vm.prank(publisher);
        vault.publishRound(4, address(0), root, 1 ether);

        vm.expectRevert(ScoopHolderRewards.InvalidProof.selector);
        vault.claim(4, address(0), bob, 1 ether, proof);
    }

    function test_twoHolders_pushBatch_partialFailure() public {
        AcceptETHHolder good = new AcceptETHHolder();
        RejectETHHolder bad = new RejectETHHolder();
        _depositETH(10 ether);

        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](2);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(address(good), 3 ether);
        ents[1] = ScoopHolderRewardsMerkle.Entitlement(address(bad), 4 ether);
        bytes32[] memory leaves = _leaves(5, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        vm.prank(publisher);
        vault.publishRound(5, address(0), root, 7 ether);

        ScoopHolderRewards.Payout[] memory payouts = new ScoopHolderRewards.Payout[](2);
        payouts[0] = ScoopHolderRewards.Payout(address(good), 3 ether, ScoopHolderRewardsMerkle.proof(leaves, 0));
        payouts[1] = ScoopHolderRewards.Payout(address(bad), 4 ether, ScoopHolderRewardsMerkle.proof(leaves, 1));
        vault.pushBatch(5, address(0), payouts);

        assertEq(address(good).balance, 3 ether);
        assertEq(address(bad).balance, 0);
        assertTrue(vault.isPaid(5, address(0), address(good)));
        assertFalse(vault.isPaid(5, address(0), address(bad)));
        assertEq(vault.outstandingCommitted(address(0)), 4 ether);

        // bad recipient remains claimable — but claim also fails for rejecting contract
        vm.expectRevert(abi.encodeWithSelector(ScoopHolderRewards.NativeTransferFailed.selector, address(bad), 4 ether));
        vault.claim(5, address(0), address(bad), 4 ether, ScoopHolderRewardsMerkle.proof(leaves, 1));
        assertFalse(vault.isPaid(5, address(0), address(bad)));
        assertEq(vault.outstandingCommitted(address(0)), 4 ether);
    }

    function test_erc20_claimAndPush() public {
        _depositToken(20 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](2);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 5 ether);
        ents[1] = ScoopHolderRewardsMerkle.Entitlement(bob, 7 ether);
        bytes32[] memory leaves = _leaves(6, address(token), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        vm.prank(publisher);
        vault.publishRound(6, address(token), root, 12 ether);

        vault.claim(6, address(token), alice, 5 ether, ScoopHolderRewardsMerkle.proof(leaves, 0));
        assertEq(token.balanceOf(alice), 5 ether);

        ScoopHolderRewards.Payout[] memory payouts = new ScoopHolderRewards.Payout[](1);
        payouts[0] = ScoopHolderRewards.Payout(bob, 7 ether, ScoopHolderRewardsMerkle.proof(leaves, 1));
        vault.pushBatch(6, address(token), payouts);
        assertEq(token.balanceOf(bob), 7 ether);
        assertEq(vault.outstandingCommitted(address(token)), 0);
    }

    function test_sameAccountNextRoundAndSecondAsset() public {
        _depositETH(5 ether);
        _depositToken(5 ether);

        ScoopHolderRewardsMerkle.Entitlement[] memory e1 = new ScoopHolderRewardsMerkle.Entitlement[](1);
        e1[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 1 ether);
        bytes32[] memory l1 = _leaves(10, address(0), e1);
        vm.prank(publisher);
        vault.publishRound(10, address(0), ScoopHolderRewardsMerkle.merkleRoot(l1), 1 ether);
        vault.claim(10, address(0), alice, 1 ether, ScoopHolderRewardsMerkle.proof(l1, 0));

        ScoopHolderRewardsMerkle.Entitlement[] memory e2 = new ScoopHolderRewardsMerkle.Entitlement[](1);
        e2[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 1 ether);
        bytes32[] memory l2 = _leaves(11, address(0), e2);
        vm.prank(publisher);
        vault.publishRound(11, address(0), ScoopHolderRewardsMerkle.merkleRoot(l2), 1 ether);
        vault.claim(11, address(0), alice, 1 ether, ScoopHolderRewardsMerkle.proof(l2, 0));

        ScoopHolderRewardsMerkle.Entitlement[] memory e3 = new ScoopHolderRewardsMerkle.Entitlement[](1);
        e3[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 2 ether);
        bytes32[] memory l3 = _leaves(10, address(token), e3);
        vm.prank(publisher);
        vault.publishRound(10, address(token), ScoopHolderRewardsMerkle.merkleRoot(l3), 2 ether);
        vault.claim(10, address(token), alice, 2 ether, ScoopHolderRewardsMerkle.proof(l3, 0));

        assertEq(alice.balance, 2 ether);
        assertEq(token.balanceOf(alice), 2 ether);
    }

    function test_initialize_onlyOnce() public {
        ScoopHolderRewards v = new ScoopHolderRewards(publisher, launchDeployer);
        vm.prank(alice);
        vm.expectRevert(ScoopHolderRewards.UnauthorizedInitializer.selector);
        v.initializeFeeDistributor(distributor);
        vm.prank(launchDeployer);
        v.initializeFeeDistributor(distributor);
        vm.prank(launchDeployer);
        vm.expectRevert(ScoopHolderRewards.AlreadyInitialized.selector);
        v.initializeFeeDistributor(distributor);
    }

    function test_initialize_attackerCannotFrontRunBeforeOrAfter() public {
        ScoopHolderRewards v = new ScoopHolderRewards(publisher, launchDeployer);
        address attackerDist = makeAddr("attackerDist");

        // Before intended init: attacker cannot bind an alternate distributor.
        vm.prank(alice);
        vm.expectRevert(ScoopHolderRewards.UnauthorizedInitializer.selector);
        v.initializeFeeDistributor(attackerDist);
        assertEq(v.feeDistributor(), address(0));

        // Canonical init.
        vm.prank(launchDeployer);
        v.initializeFeeDistributor(distributor);
        assertEq(v.feeDistributor(), distributor);

        // After intended init: wrong caller is rejected (auth check precedes already-initialized).
        vm.prank(alice);
        vm.expectRevert(ScoopHolderRewards.UnauthorizedInitializer.selector);
        v.initializeFeeDistributor(attackerDist);
        assertEq(v.feeDistributor(), distributor);

        vm.prank(launchDeployer);
        vm.expectRevert(ScoopHolderRewards.AlreadyInitialized.selector);
        v.initializeFeeDistributor(attackerDist);
    }

    function test_initialize_zeroDistributorReverts() public {
        ScoopHolderRewards v = new ScoopHolderRewards(publisher, launchDeployer);
        vm.prank(launchDeployer);
        vm.expectRevert(ScoopHolderRewards.ZeroAddress.selector);
        v.initializeFeeDistributor(address(0));
    }

    function test_initialize_wrongLaunchDeployerCannotInitPredictedVault() public {
        // Vaults bind immutable launchDeployer at construction; a second deployer cannot init them.
        ScoopLaunchDeployer otherDeployer = new ScoopLaunchDeployer(makeAddr("pm2"), publisher);
        ScoopHolderRewards v = new ScoopHolderRewards(publisher, address(launchDeployer));
        vm.prank(address(otherDeployer));
        vm.expectRevert(ScoopHolderRewards.UnauthorizedInitializer.selector);
        v.initializeFeeDistributor(distributor);
    }

    function test_noSweepFunctions() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("sweep(address)", alice));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("withdraw(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("rescue(address,address,uint256)", address(0), alice, 1));
        assertFalse(ok);
    }

    function testFuzz_publishCannotExceedUncommitted(uint128 deposit, uint128 commit) public {
        deposit = uint128(bound(deposit, 1, 1000 ether));
        commit = uint128(bound(commit, 1, uint256(deposit) * 2));
        _depositETH(deposit);
        vm.prank(publisher);
        if (commit > deposit) {
            vm.expectRevert(ScoopHolderRewards.InsufficientUncommitted.selector);
            vault.publishRound(99, address(0), bytes32(uint256(1)), commit);
        } else {
            vault.publishRound(99, address(0), bytes32(uint256(1)), commit);
            assertEq(vault.uncommitted(address(0)), deposit - commit);
            assertEq(vault.outstandingCommitted(address(0)), commit);
        }
    }

    function test_publishRound_zeroRootAndZeroTotalRevert() public {
        _depositETH(1 ether);
        vm.startPrank(publisher);
        vm.expectRevert(ScoopHolderRewards.ZeroRoot.selector);
        vault.publishRound(1, address(0), bytes32(0), 1 ether);
        vm.expectRevert(ScoopHolderRewards.ZeroAmount.selector);
        vault.publishRound(1, address(0), bytes32(uint256(1)), 0);
        vm.stopPrank();
    }

    function test_publishRound_skippedRoundIdsOk() public {
        _depositETH(3 ether);
        vm.startPrank(publisher);
        vault.publishRound(100, address(0), bytes32(uint256(1)), 1 ether);
        vault.publishRound(102, address(0), bytes32(uint256(2)), 1 ether);
        vm.stopPrank();
        (,, bool p100) = vault.round(100, address(0));
        (,, bool p101) = vault.round(101, address(0));
        (,, bool p102) = vault.round(102, address(0));
        assertTrue(p100);
        assertFalse(p101);
        assertTrue(p102);
    }

    function test_claim_wrongAmountRoundAssetFail() public {
        _depositETH(5 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](1);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 1 ether);
        bytes32[] memory leaves = _leaves(7, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        bytes32[] memory proof = ScoopHolderRewardsMerkle.proof(leaves, 0);
        vm.prank(publisher);
        vault.publishRound(7, address(0), root, 1 ether);

        vm.expectRevert(ScoopHolderRewards.InvalidProof.selector);
        vault.claim(7, address(0), alice, 2 ether, proof);

        vm.expectRevert(ScoopHolderRewards.InvalidProof.selector);
        vault.claim(8, address(0), alice, 1 ether, proof);

        vm.expectRevert(ScoopHolderRewards.InvalidProof.selector);
        vault.claim(7, address(token), alice, 1 ether, proof);
    }

    function test_claim_crossVaultProofFails() public {
        ScoopHolderRewards other = new ScoopHolderRewards(publisher, launchDeployer);
        vm.prank(launchDeployer);
        other.initializeFeeDistributor(distributor);

        assertTrue(
            vault.leafHash(1, address(0), alice, 1 ether) != other.leafHash(1, address(0), alice, 1 ether),
            "leaves must bind vault address"
        );

        _depositETH(2 ether);
        bytes32 foreignLeaf =
            ScoopHolderRewardsMerkle.leaf(block.chainid, address(other), 1, address(0), alice, 1 ether);
        // Single-leaf root equals the foreign leaf; claim on this vault reconstructs a different leaf.
        vm.prank(publisher);
        vault.publishRound(1, address(0), foreignLeaf, 1 ether);

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.expectRevert(ScoopHolderRewards.InvalidProof.selector);
        vault.claim(1, address(0), alice, 1 ether, emptyProof);
    }

    function test_pushBatch_emptyReverts() public {
        ScoopHolderRewards.Payout[] memory payouts = new ScoopHolderRewards.Payout[](0);
        vm.expectRevert(ScoopHolderRewards.EmptyBatch.selector);
        vault.pushBatch(1, address(0), payouts);
    }

    function test_pushBatch_duplicateEntryDoesNotDoublePay() public {
        _depositETH(5 ether);
        ScoopHolderRewardsMerkle.Entitlement[] memory ents = new ScoopHolderRewardsMerkle.Entitlement[](1);
        ents[0] = ScoopHolderRewardsMerkle.Entitlement(alice, 1 ether);
        bytes32[] memory leaves = _leaves(12, address(0), ents);
        bytes32 root = ScoopHolderRewardsMerkle.merkleRoot(leaves);
        bytes32[] memory proof = ScoopHolderRewardsMerkle.proof(leaves, 0);
        vm.prank(publisher);
        vault.publishRound(12, address(0), root, 1 ether);

        ScoopHolderRewards.Payout[] memory payouts = new ScoopHolderRewards.Payout[](2);
        payouts[0] = ScoopHolderRewards.Payout(alice, 1 ether, proof);
        payouts[1] = ScoopHolderRewards.Payout(alice, 1 ether, proof);
        vault.pushBatch(12, address(0), payouts);
        assertEq(alice.balance, 1 ether);
        assertEq(vault.outstandingCommitted(address(0)), 0);
        assertEq(vault.totalPaid(address(0)), 1 ether);
    }
}
