// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopTestToken} from "../../src/ScoopTestToken.sol";

interface IScoopInvariantRegistrar {
    function registerSourceAsRegistrar(address source, bytes32 creatorId) external;
}

/**
 * @notice Stateful fuzz handler for local (no-Uniswap) protocol invariants.
 * @dev Registration goes through `registrarProxy` (the invariant test), which is
 *      `ScoopCreatorRewards.sourceRegistrar`.
 */
contract ScoopInvariantHandler is Test {
    uint16 internal constant CREATOR_REWARDS_BPS = 7000;
    uint16 internal constant DEPLOYER_BPS = 400;
    uint16 internal constant BUYBACK_BPS = 2000;
    uint16 internal constant OPERATIONS_BPS = 600;

    ScoopCreatorRegistry public immutable registry;
    ScoopCreatorRewards public immutable rewards;
    ScoopFeeDistributor public immutable distributor;
    ScoopTestToken public immutable token;
    IScoopInvariantRegistrar public immutable registrarProxy;

    uint256 public immutable verificationAuthorityKey;
    address public immutable deployerRecipient;
    address public immutable buybackVault;
    address public immutable operations;
    address public immutable walletCreator;

    bytes32 public immutable walletCreatorId;
    bytes32 public immutable xCreatorId;
    uint256 public constant X_USER = 123456789;

    uint256 public ghostEthCredited;
    uint256 public ghostEthClaimed;
    uint256 public ghostTokenCredited;
    uint256 public ghostTokenClaimed;
    uint256 public sourceNonce;
    bool public xClaimed;

    address[] public sources;

    constructor(
        ScoopCreatorRegistry registry_,
        ScoopCreatorRewards rewards_,
        ScoopFeeDistributor distributor_,
        ScoopTestToken token_,
        IScoopInvariantRegistrar registrarProxy_,
        uint256 verificationAuthorityKey_,
        address deployerRecipient_,
        address buybackVault_,
        address operations_,
        address walletCreator_
    ) {
        registry = registry_;
        rewards = rewards_;
        distributor = distributor_;
        token = token_;
        registrarProxy = registrarProxy_;
        verificationAuthorityKey = verificationAuthorityKey_;
        deployerRecipient = deployerRecipient_;
        buybackVault = buybackVault_;
        operations = operations_;
        walletCreator = walletCreator_;

        walletCreatorId = registry_.walletCreatorId(walletCreator_);
        xCreatorId = registry_.xCreatorId(X_USER);
    }

    function registerSource(uint256 salt, bool useX) external {
        address source = address(uint160(uint256(keccak256(abi.encode("src", salt, sourceNonce++)))));
        if (source.code.length > 0 || source == address(0)) return;
        if (rewards.sourceCreatorId(source) != bytes32(0)) return;
        bytes32 creatorId = useX ? xCreatorId : walletCreatorId;
        try registrarProxy.registerSourceAsRegistrar(source, creatorId) {
            sources.push(source);
            vm.deal(source, 100 ether);
            if (token.balanceOf(address(this)) >= 10_000 ether) {
                token.transfer(source, 10_000 ether);
            }
        } catch {}
    }

    function creditETH(uint256 sourceIndex, uint256 amount) external {
        if (sources.length == 0) return;
        sourceIndex = sourceIndex % sources.length;
        amount = bound(amount, 1, 10 ether);
        address source = sources[sourceIndex];
        if (source.balance < amount) return;

        bytes32 creatorId = rewards.sourceCreatorId(source);
        vm.prank(source);
        try rewards.creditETH{value: amount}() {
            ghostEthCredited += amount;
            assertGe(rewards.claimableETH(creatorId), amount);
        } catch {}
    }

    function creditToken(uint256 sourceIndex, uint256 amount) external {
        if (sources.length == 0) return;
        sourceIndex = sourceIndex % sources.length;
        amount = bound(amount, 1, 1_000 ether);
        address source = sources[sourceIndex];
        if (token.balanceOf(source) < amount) return;

        bytes32 creatorId = rewards.sourceCreatorId(source);

        vm.startPrank(source);
        token.approve(address(rewards), amount);
        try rewards.creditToken(address(token), amount) {
            ghostTokenCredited += amount;
            assertGe(rewards.claimableToken(creatorId, address(token)), amount);
        } catch {}
        vm.stopPrank();
    }

    function distributeETH(uint256 amount) external {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(distributor), address(distributor).balance + amount);

        uint256 bal = address(distributor).balance;
        uint256 depBefore = deployerRecipient.balance;
        uint256 bbBefore = buybackVault.balance;
        uint256 opsBefore = operations.balance;
        bytes32 creatorId = rewards.sourceCreatorId(address(distributor));
        if (creatorId == bytes32(0)) return;
        uint256 claimBefore = rewards.claimableETH(creatorId);

        try distributor.distributeETH() {
            uint256 c = (bal * CREATOR_REWARDS_BPS) / 10_000;
            uint256 d = (bal * DEPLOYER_BPS) / 10_000;
            uint256 b = (bal * BUYBACK_BPS) / 10_000;
            uint256 o = bal - c - d - b;
            assertEq(deployerRecipient.balance - depBefore, d);
            assertEq(buybackVault.balance - bbBefore, b);
            assertEq(operations.balance - opsBefore, o);
            assertEq(rewards.claimableETH(creatorId) - claimBefore, c);
            assertEq(address(distributor).balance, 0);
            ghostEthCredited += c;
        } catch {}
    }

    function distributeToken(uint256 amount) external {
        amount = bound(amount, 1, 5_000 ether);
        if (token.balanceOf(address(this)) < amount) return;
        token.transfer(address(distributor), amount);

        uint256 bal = token.balanceOf(address(distributor));
        if (bal == 0) return;

        bytes32 creatorId = rewards.sourceCreatorId(address(distributor));
        if (creatorId == bytes32(0)) return;

        uint256 depBefore = token.balanceOf(deployerRecipient);
        uint256 bbBefore = token.balanceOf(buybackVault);
        uint256 opsBefore = token.balanceOf(operations);
        uint256 claimBefore = rewards.claimableToken(creatorId, address(token));

        try distributor.distributeToken(address(token)) {
            uint256 c = (bal * CREATOR_REWARDS_BPS) / 10_000;
            uint256 d = (bal * DEPLOYER_BPS) / 10_000;
            uint256 b = (bal * BUYBACK_BPS) / 10_000;
            uint256 o = bal - c - d - b;
            assertEq(token.balanceOf(deployerRecipient) - depBefore, d);
            assertEq(token.balanceOf(buybackVault) - bbBefore, b);
            assertEq(token.balanceOf(operations) - opsBefore, o);
            assertEq(rewards.claimableToken(creatorId, address(token)) - claimBefore, c);
            assertEq(token.balanceOf(address(distributor)), 0);
            ghostTokenCredited += c;
        } catch {}
    }

    function claimETH() external {
        uint256 claimable = rewards.claimableETH(walletCreatorId);
        if (claimable == 0) return;
        uint256 beforeBal = walletCreator.balance;
        try rewards.claimETH(walletCreatorId, walletCreator) {
            assertEq(walletCreator.balance, beforeBal + claimable);
            assertEq(rewards.claimableETH(walletCreatorId), 0);
            ghostEthClaimed += claimable;
        } catch {}
    }

    function claimToken() external {
        uint256 claimable = rewards.claimableToken(walletCreatorId, address(token));
        if (claimable == 0) return;
        uint256 beforeBal = token.balanceOf(walletCreator);
        try rewards.claimToken(walletCreatorId, address(token), walletCreator) {
            assertEq(token.balanceOf(walletCreator), beforeBal + claimable);
            assertEq(rewards.claimableToken(walletCreatorId, address(token)), 0);
            ghostTokenClaimed += claimable;
        } catch {}
    }

    function claimXIdentity(
        uint256 /* salt */
    )
        external
    {
        if (xClaimed) return;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = registry.hashClaimXIdentity(X_USER, walletCreator, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verificationAuthorityKey, digest);
        try registry.claimXIdentity(X_USER, walletCreator, deadline, abi.encodePacked(r, s, v)) {
            xClaimed = true;
            assertEq(registry.resolvedWallet(xCreatorId), walletCreator);
        } catch {}
    }

    function claimXETH() external {
        if (!xClaimed) return;
        uint256 claimable = rewards.claimableETH(xCreatorId);
        if (claimable == 0) return;
        uint256 beforeBal = walletCreator.balance;
        try rewards.claimETH(xCreatorId, address(0)) {
            assertEq(walletCreator.balance, beforeBal + claimable);
            assertEq(rewards.claimableETH(xCreatorId), 0);
            ghostEthClaimed += claimable;
        } catch {}
    }

    function claimXToken() external {
        if (!xClaimed) return;
        uint256 claimable = rewards.claimableToken(xCreatorId, address(token));
        if (claimable == 0) return;
        uint256 beforeBal = token.balanceOf(walletCreator);
        try rewards.claimToken(xCreatorId, address(token), address(0)) {
            assertEq(token.balanceOf(walletCreator), beforeBal + claimable);
            assertEq(rewards.claimableToken(xCreatorId, address(token)), 0);
            ghostTokenClaimed += claimable;
        } catch {}
    }

    receive() external payable {}
}
