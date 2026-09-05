// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";
import {IScoopCreatorRewards} from "../src/interfaces/IScoopCreatorRewards.sol";

/// @dev Minimal CreatorRewards stand-in for distributor unit tests (no registry/source gating).
contract MockCreatorRewards is IScoopCreatorRewards {
    function creditETH() external payable override {}

    function creditToken(address token, uint256 amount) external override {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev Test-only recipient that rejects native ETH.
contract RejectETH {
    receive() external payable {
        revert("no eth");
    }

    fallback() external payable {
        revert("no eth");
    }
}

contract ScoopFeeDistributorTest is Test {
    uint16 constant CREATOR_REWARDS_BPS = 7000;
    uint16 constant DEPLOYER_BPS = 400;
    uint16 constant BUYBACK_BPS = 2000;
    uint16 constant OPERATIONS_BPS = 600;

    MockCreatorRewards creatorRewards;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address caller;

    ScoopFeeDistributor distributor;
    ScoopTestToken token;

    function setUp() public {
        creatorRewards = new MockCreatorRewards();
        deployerRecipient = makeAddr("deployer");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        caller = makeAddr("caller");

        distributor = new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );

        token = new ScoopTestToken("Scoop Test", "SCOOPT", address(this), 1_000_000_000 ether);
    }

    function test_constructorStoresAllRecipients() public view {
        assertEq(distributor.creatorRewards(), address(creatorRewards));
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
    }

    function test_constructorStoresAllBps() public view {
        assertEq(distributor.creatorRewardsBps(), CREATOR_REWARDS_BPS);
        assertEq(distributor.deployerBps(), DEPLOYER_BPS);
        assertEq(distributor.buybackBps(), BUYBACK_BPS);
        assertEq(distributor.operationsBps(), OPERATIONS_BPS);
    }

    function test_constructorRejectsZeroCreatorRewards() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        new ScoopFeeDistributor(
            address(0),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
    }

    function test_constructorRejectsZeroDeployer() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        new ScoopFeeDistributor(
            address(creatorRewards),
            address(0),
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
    }

    function test_constructorRejectsZeroBuybackVault() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            address(0),
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
    }

    function test_constructorRejectsZeroOperations() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            address(0),
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
    }

    function test_constructorRejectsBpsTotalBelow10000() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopFeeDistributor.InvalidBpsTotal.selector, uint16(9999)));
        new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            6999,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
    }

    function test_constructorRejectsBpsTotalAbove10000() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopFeeDistributor.InvalidBpsTotal.selector, uint16(10001)));
        new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            7001,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
    }

    function test_contractReceivesETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(distributor).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(distributor).balance, 1 ether);
    }

    function test_distributeETH_oneEther_v1Split() public {
        vm.deal(address(distributor), 1 ether);

        distributor.distributeETH();

        assertEq(address(creatorRewards).balance, 0.7 ether);
        assertEq(deployerRecipient.balance, 0.04 ether);
        assertEq(buybackVault.balance, 0.2 ether);
        assertEq(operations.balance, 0.06 ether);
        assertEq(address(distributor).balance, 0);
    }

    function test_distributeETH_permissionlessCallerGetsNoReward() public {
        vm.deal(address(distributor), 1 ether);
        uint256 callerBefore = caller.balance;

        vm.prank(caller);
        distributor.distributeETH();

        assertEq(caller.balance, callerBefore);
        assertEq(address(creatorRewards).balance, 0.7 ether);
        assertEq(deployerRecipient.balance, 0.04 ether);
        assertEq(buybackVault.balance, 0.2 ether);
        assertEq(operations.balance, 0.06 ether);
    }

    function test_distributeETH_balanceZeroAfterSuccess() public {
        vm.deal(address(distributor), 5 ether);
        distributor.distributeETH();
        assertEq(address(distributor).balance, 0);
    }

    function test_distributeETH_zeroBalanceReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroBalance.selector);
        distributor.distributeETH();
    }

    function test_distributeETH_repeatedDistributionsWork() public {
        vm.deal(address(distributor), 1 ether);
        distributor.distributeETH();

        vm.deal(address(distributor), 2 ether);
        distributor.distributeETH();

        assertEq(address(creatorRewards).balance, 0.7 ether + 1.4 ether);
        assertEq(deployerRecipient.balance, 0.04 ether + 0.08 ether);
        assertEq(buybackVault.balance, 0.2 ether + 0.4 ether);
        assertEq(operations.balance, 0.06 ether + 0.12 ether);
        assertEq(address(distributor).balance, 0);
    }

    function test_distributeETH_rejectingRecipientRevertsAtomically() public {
        RejectETH rejector = new RejectETH();
        ScoopFeeDistributor hostile = new ScoopFeeDistributor(
            address(creatorRewards),
            address(rejector),
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );

        vm.deal(address(hostile), 1 ether);

        uint256 rewardsBefore = address(creatorRewards).balance;
        uint256 buybackBefore = buybackVault.balance;
        uint256 opsBefore = operations.balance;

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopFeeDistributor.NativeTransferFailed.selector, address(rejector), uint256(0.04 ether)
            )
        );
        hostile.distributeETH();

        assertEq(address(hostile).balance, 1 ether);
        assertEq(address(creatorRewards).balance, rewardsBefore);
        assertEq(buybackVault.balance, buybackBefore);
        assertEq(operations.balance, opsBefore);
        assertEq(address(rejector).balance, 0);
    }

    function test_erc20CanBeSentToDistributor() public {
        token.transfer(address(distributor), 100 ether);
        assertEq(token.balanceOf(address(distributor)), 100 ether);
    }

    function test_distributeToken_v1Split() public {
        uint256 amount = 100 ether;
        token.transfer(address(distributor), amount);

        distributor.distributeToken(address(token));

        assertEq(token.balanceOf(address(creatorRewards)), 70 ether);
        assertEq(token.balanceOf(deployerRecipient), 4 ether);
        assertEq(token.balanceOf(buybackVault), 20 ether);
        assertEq(token.balanceOf(operations), 6 ether);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.allowance(address(distributor), address(creatorRewards)), 0);
    }

    function test_distributeToken_permissionless() public {
        token.transfer(address(distributor), 100 ether);

        vm.prank(caller);
        distributor.distributeToken(address(token));

        assertEq(token.balanceOf(address(creatorRewards)), 70 ether);
        assertEq(token.balanceOf(caller), 0);
    }

    function test_distributeToken_balanceZeroAfterSuccess() public {
        token.transfer(address(distributor), 50 ether);
        distributor.distributeToken(address(token));
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_distributeToken_zeroBalanceReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroBalance.selector);
        distributor.distributeToken(address(token));
    }

    function test_distributeToken_zeroTokenAddressReverts() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroToken.selector);
        distributor.distributeToken(address(0));
    }

    function test_distributeToken_roundingAllocatesCompleteBalance() public {
        uint256 awkward = 10_003;
        token.transfer(address(distributor), awkward);

        distributor.distributeToken(address(token));

        uint256 c = token.balanceOf(address(creatorRewards));
        uint256 d = token.balanceOf(deployerRecipient);
        uint256 b = token.balanceOf(buybackVault);
        uint256 o = token.balanceOf(operations);

        assertEq(c + d + b + o, awkward);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(c, (awkward * CREATOR_REWARDS_BPS) / 10_000);
        assertEq(d, (awkward * DEPLOYER_BPS) / 10_000);
        assertEq(b, (awkward * BUYBACK_BPS) / 10_000);
        assertEq(o, awkward - c - d - b);
    }

    function test_distributeToken_repeatedDistributionsWork() public {
        token.transfer(address(distributor), 100 ether);
        distributor.distributeToken(address(token));

        token.transfer(address(distributor), 50 ether);
        distributor.distributeToken(address(token));

        assertEq(token.balanceOf(address(creatorRewards)), 70 ether + 35 ether);
        assertEq(token.balanceOf(deployerRecipient), 4 ether + 2 ether);
        assertEq(token.balanceOf(buybackVault), 20 ether + 10 ether);
        assertEq(token.balanceOf(operations), 6 ether + 3 ether);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function test_immutableConfigurationCannotBeChanged() public {
        (bool setCreatorOk,) = address(distributor).call(abi.encodeWithSignature("setCreatorRewards(address)", caller));
        (bool setDeployerOk,) = address(distributor).call(abi.encodeWithSignature("setDeployer(address)", caller));
        (bool setBpsOk,) = address(distributor).call(abi.encodeWithSignature("setCreatorRewardsBps(uint16)", uint16(1)));
        (bool rescueOk,) = address(distributor).call(abi.encodeWithSignature("rescueETH(address)", caller));
        (bool ownableOk,) = address(distributor).call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = address(distributor).call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));

        assertFalse(setCreatorOk);
        assertFalse(setDeployerOk);
        assertFalse(setBpsOk);
        assertFalse(rescueOk);
        assertFalse(ownableOk);
        assertFalse(adminOk);

        assertEq(distributor.creatorRewards(), address(creatorRewards));
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.creatorRewardsBps(), CREATOR_REWARDS_BPS);
        assertEq(distributor.deployerBps(), DEPLOYER_BPS);
        assertEq(distributor.buybackBps(), BUYBACK_BPS);
        assertEq(distributor.operationsBps(), OPERATIONS_BPS);
    }

    function testFuzz_distributeETH_allocatesFullBalance(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        vm.deal(address(distributor), amount);

        uint256 cBefore = address(creatorRewards).balance;
        uint256 dBefore = deployerRecipient.balance;
        uint256 bBefore = buybackVault.balance;
        uint256 oBefore = operations.balance;

        distributor.distributeETH();

        uint256 c = address(creatorRewards).balance - cBefore;
        uint256 d = deployerRecipient.balance - dBefore;
        uint256 b = buybackVault.balance - bBefore;
        uint256 o = operations.balance - oBefore;

        assertEq(c + d + b + o, amount);
        assertEq(address(distributor).balance, 0);
    }

    function testFuzz_distributeToken_allocatesFullBalance(uint256 amount) public {
        amount = bound(amount, 1, token.balanceOf(address(this)));
        token.transfer(address(distributor), amount);

        uint256 cBefore = token.balanceOf(address(creatorRewards));
        uint256 dBefore = token.balanceOf(deployerRecipient);
        uint256 bBefore = token.balanceOf(buybackVault);
        uint256 oBefore = token.balanceOf(operations);

        distributor.distributeToken(address(token));

        uint256 c = token.balanceOf(address(creatorRewards)) - cBefore;
        uint256 d = token.balanceOf(deployerRecipient) - dBefore;
        uint256 b = token.balanceOf(buybackVault) - bBefore;
        uint256 o = token.balanceOf(operations) - oBefore;

        assertEq(c + d + b + o, amount);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    receive() external payable {}
}
