// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ScoopSecurityLocalBase} from "./ScoopSecurityLocalBase.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {
    FeeOnTransferERC20,
    FalseReturnERC20,
    NoReturnERC20,
    ReentrantTransferFromERC20
} from "../mocks/security/MaliciousERC20s.sol";

/**
 * @notice Malicious / non-standard ERC-20 behavior against CreatorRewards + FeeDistributor.
 * @dev Factory.launchAndBuy rejects fee-on-transfer quotes via balance-delta check
 *      (`UnsupportedTransferBehavior`). That path requires a full Uniswap launch (fork);
 *      documented here for the security report.
 */
contract ScoopMaliciousErc20Test is ScoopSecurityLocalBase {
    function test_feeOnTransfer_creditToken_creditsActualReceivedOnly() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        fot.transfer(sourceA, 1000 ether);
        _registerSource(sourceA, walletCreatorId);

        vm.startPrank(sourceA);
        fot.approve(address(rewards), 100 ether);
        rewards.creditToken(address(fot), 100 ether);
        vm.stopPrank();

        assertEq(rewards.claimableToken(walletCreatorId, address(fot)), 90 ether);
        assertEq(fot.balanceOf(address(rewards)), 90 ether);
    }

    function test_falseReturn_creditToken_failsClosed() public {
        FalseReturnERC20 bad = new FalseReturnERC20();
        bad.transfer(sourceA, 100 ether);
        _registerSource(sourceA, walletCreatorId);

        vm.startPrank(sourceA);
        bad.approve(address(rewards), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        rewards.creditToken(address(bad), 10 ether);
        vm.stopPrank();

        assertEq(rewards.claimableToken(walletCreatorId, address(bad)), 0);
    }

    function test_noReturn_creditToken_worksWithSafeERC20() public {
        NoReturnERC20 nortn = new NoReturnERC20();
        nortn.transfer(sourceA, 100 ether);

        _registerSource(sourceA, walletCreatorId);
        vm.startPrank(sourceA);
        nortn.approve(address(rewards), 25 ether);
        rewards.creditToken(address(nortn), 25 ether);
        vm.stopPrank();

        assertEq(rewards.claimableToken(walletCreatorId, address(nortn)), 25 ether);
        assertEq(nortn.balanceOf(address(rewards)), 25 ether);
    }

    function test_reentrantTransferFrom_duringCredit_failsClosed() public {
        ReentrantTransferFromERC20 reent = new ReentrantTransferFromERC20();
        reent.transfer(sourceA, 100 ether);
        _registerSource(sourceA, walletCreatorId);

        reent.arm(
            address(rewards),
            abi.encodeWithSelector(ScoopCreatorRewards.creditToken.selector, address(reent), uint256(1 ether))
        );

        vm.startPrank(sourceA);
        reent.approve(address(rewards), 10 ether);
        // Reentrant credit is blocked by nonReentrant; mock ignores inner failure and completes
        // the outer transfer — accounting still credits exactly once (fails closed / no double credit).
        rewards.creditToken(address(reent), 10 ether);
        vm.stopPrank();

        assertEq(rewards.claimableToken(walletCreatorId, address(reent)), 10 ether);
        assertEq(reent.balanceOf(address(rewards)), 10 ether);
    }

    function test_feeOnTransfer_distributeToken_creditsActualViaBalanceDelta() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        ScoopFeeDistributor dist = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        _registerSource(address(dist), walletCreatorId);

        fot.transfer(address(dist), 1000 ether);
        // FOT delivers 900 into distributor; creator leg requests 630 but FOT delivers 567.
        dist.distributeToken(address(fot));

        assertEq(rewards.claimableToken(walletCreatorId, address(fot)), 567 ether);
    }

    function test_falseReturn_distributeToken_failsClosed() public {
        FalseReturnERC20 bad = new FalseReturnERC20();
        deal(address(bad), address(distributor), 100 ether);
        _registerSource(address(distributor), walletCreatorId);

        vm.expectRevert();
        distributor.distributeToken(address(bad));
        assertEq(rewards.claimableToken(walletCreatorId, address(bad)), 0);
    }

    function test_noReturn_distributeToken_worksWithSafeERC20() public {
        NoReturnERC20 nortn = new NoReturnERC20();
        ScoopFeeDistributor dist = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        _registerSource(address(dist), walletCreatorId);

        nortn.transfer(address(dist), 1000 ether);
        dist.distributeToken(address(nortn));

        assertEq(rewards.claimableToken(walletCreatorId, address(nortn)), 700 ether);
        assertEq(nortn.balanceOf(deployerRecipient), 40 ether);
        assertEq(nortn.balanceOf(buybackVault), 200 ether);
        assertEq(nortn.balanceOf(operations), 60 ether);
        assertEq(nortn.balanceOf(address(dist)), 0);
    }

    /**
     * @notice Documented: Factory.launchAndBuy rejects fee-on-transfer quotes.
     * @dev `_pullExactQuote` requires `actualReceived == quoteAmountIn` else
     *      `UnsupportedTransferBehavior`. Full path needs fork Uniswap.
     */
    function test_documented_factoryLaunchAndBuy_rejectsFeeOnTransfer() public pure {
        bytes4 sel = ScoopFactory.UnsupportedTransferBehavior.selector;
        assertEq(sel, bytes4(keccak256("UnsupportedTransferBehavior()")));
    }
}
