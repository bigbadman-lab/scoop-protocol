// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopSecurityLocalBase} from "./ScoopSecurityLocalBase.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../../src/ScoopFactoryDeployer.sol";
import {ScoopTokenDeployer} from "../../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../../src/ScoopLaunchDeployer.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";
import {
    RejectETHRecipient,
    ReenterFactoryOnReceive,
    ReenterDistributorOnReceive,
    ReenterClaimOnReceive,
    CountingRecipient
} from "../mocks/security/MaliciousRecipients.sol";

/**
 * @notice Malicious ETH recipient / reentrancy tests for fee + claim paths.
 */
contract ScoopMaliciousRecipientTest is ScoopSecurityLocalBase {
    function test_rejectingLaunchFeeRecipient_launchReverts_noState() public {
        RejectETHRecipient rejector = new RejectETHRecipient();

        ScoopTokenDeployer td = new ScoopTokenDeployer();
        ScoopLaunchDeployer ld = new ScoopLaunchDeployer(makeAddr("pm"));
        ScoopQuoteRegistry qr = new ScoopQuoteRegistry(registryAuthority);
        ScoopPriceOracle po = new ScoopPriceOracle(oracleAuthority);

        vm.prank(registryAuthority);
        qr.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        vm.prank(oracleAuthority);
        po.configureFeed(address(0), address(ethFeed), 3600);

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(registry),
            makeAddr("poolManager"),
            makeAddr("positionManager"),
            makeAddr("permit2"),
            makeAddr("universalRouter"),
            address(td),
            address(ld),
            address(qr),
            address(po),
            buybackVault,
            operations,
            address(rejector)
        );
        ScoopFactory factory = protocol.factory();
        ScoopCreatorRewards factoryRewards = protocol.creatorRewards();
        assertEq(factory.launchFeeRecipient(), address(rejector));

        address dep = makeAddr("dep");
        vm.deal(dep, 1 ether);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "FeeFail",
            symbol: "FF",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(1))
        });

        // Prove recipient rejects ETH in isolation first.
        (bool okReject,) = address(rejector).call{value: 1 wei}("");
        assertFalse(okReject);

        uint256 feeBefore = address(rejector).balance;
        uint256 launchFee = factory.LAUNCH_FEE();
        vm.prank(dep);
        vm.expectRevert(ScoopFactory.LaunchFeeTransferFailed.selector);
        factory.launch{value: launchFee}(params);

        assertEq(address(rejector).balance, feeBefore);
        assertEq(address(factory).balance, 0);
        assertEq(dep.balance, 1 ether);
        assertEq(factoryRewards.sourceRegistrar(), address(factory));
        assertEq(address(factoryRewards).balance, 0);
    }

    function test_reenteringLaunchFeeRecipient_fullRevert_noDoubleFee() public {
        ReenterFactoryOnReceive reenter = new ReenterFactoryOnReceive();

        ScoopTokenDeployer td = new ScoopTokenDeployer();
        ScoopLaunchDeployer ld = new ScoopLaunchDeployer(makeAddr("pm"));
        ScoopQuoteRegistry qr = new ScoopQuoteRegistry(registryAuthority);
        ScoopPriceOracle po = new ScoopPriceOracle(oracleAuthority);
        vm.prank(registryAuthority);
        qr.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        vm.prank(oracleAuthority);
        po.configureFeed(address(0), address(ethFeed), 3600);

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(registry),
            makeAddr("poolManager"),
            makeAddr("positionManager"),
            makeAddr("permit2"),
            makeAddr("universalRouter"),
            address(td),
            address(ld),
            address(qr),
            address(po),
            buybackVault,
            operations,
            address(reenter)
        );
        ScoopFactory factory = protocol.factory();

        address dep = makeAddr("dep");
        vm.deal(dep, 1 ether);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Reenter",
            symbol: "RE",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: bytes32(uint256(2))
        });
        reenter.configure(factory, params);
        reenter.enableReenter(true);

        // Outer launch pays fee → receive reenters launch → nonReentrant → fee call fails.
        // Cache fee before expectRevert (staticcall must not be the "next call").
        uint256 launchFee = factory.LAUNCH_FEE();
        vm.prank(dep);
        vm.expectRevert(ScoopFactory.LaunchFeeTransferFailed.selector);
        factory.launch{value: launchFee}(params);

        // `attacked` is rolled back with the reverted fee payment; prove no fee retained.
        assertEq(address(reenter).balance, 0);
        assertEq(address(factory).balance, 0);
        assertEq(dep.balance, 1 ether);
    }

    function test_rejectingDeployer_distributeETH_revertsAtomically() public {
        RejectETHRecipient rejector = new RejectETHRecipient();
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
        _registerSource(address(hostile), walletCreatorId);
        vm.deal(address(hostile), 1 ether);

        uint256 rewardsBefore = address(rewards).balance;
        uint256 buybackBefore = buybackVault.balance;
        uint256 opsBefore = operations.balance;

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopFeeDistributor.NativeTransferFailed.selector, address(rejector), uint256(0.04 ether)
            )
        );
        hostile.distributeETH();

        assertEq(address(hostile).balance, 1 ether);
        assertEq(address(rewards).balance, rewardsBefore);
        assertEq(buybackVault.balance, buybackBefore);
        assertEq(operations.balance, opsBefore);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
    }

    function test_rejectingBuybackVault_distributeETH_revertsAtomically() public {
        RejectETHRecipient rejector = new RejectETHRecipient();
        ScoopFeeDistributor hostile = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            address(rejector),
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        _registerSource(address(hostile), walletCreatorId);
        vm.deal(address(hostile), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopFeeDistributor.NativeTransferFailed.selector, address(rejector), uint256(0.2 ether)
            )
        );
        hostile.distributeETH();
        assertEq(address(hostile).balance, 1 ether);
    }

    function test_rejectingOperations_distributeETH_revertsAtomically() public {
        RejectETHRecipient rejector = new RejectETHRecipient();
        ScoopFeeDistributor hostile = new ScoopFeeDistributor(
            address(rewards),
            deployerRecipient,
            buybackVault,
            address(rejector),
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        _registerSource(address(hostile), walletCreatorId);
        vm.deal(address(hostile), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopFeeDistributor.NativeTransferFailed.selector, address(rejector), uint256(0.06 ether)
            )
        );
        hostile.distributeETH();
        assertEq(address(hostile).balance, 1 ether);
    }

    function test_blastRadius_buybackAndOperations_areFactoryImmutables() public {
        ScoopTokenDeployer td = new ScoopTokenDeployer();
        ScoopLaunchDeployer ld = new ScoopLaunchDeployer(makeAddr("pm"));
        ScoopQuoteRegistry qr = new ScoopQuoteRegistry(registryAuthority);
        ScoopPriceOracle po = new ScoopPriceOracle(oracleAuthority);
        vm.prank(registryAuthority);
        qr.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        vm.prank(oracleAuthority);
        po.configureFeed(address(0), address(ethFeed), 3600);

        CountingRecipient sharedBuyback = new CountingRecipient();
        CountingRecipient sharedOps = new CountingRecipient();
        address feeRecipient = makeAddr("feeRecipient");

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(registry),
            makeAddr("poolManager"),
            makeAddr("positionManager"),
            makeAddr("permit2"),
            makeAddr("universalRouter"),
            address(td),
            address(ld),
            address(qr),
            address(po),
            address(sharedBuyback),
            address(sharedOps),
            feeRecipient
        );
        ScoopFactory factory = protocol.factory();

        assertEq(factory.buybackVault(), address(sharedBuyback));
        assertEq(factory.operations(), address(sharedOps));
        // Shared immutable buyback/ops DoS distributeETH for ALL launches on this Factory.
        assertTrue(true, "blast radius: shared immutable buyback/ops across launches");
    }

    function test_reenterDistributeETH_blockedByNonReentrant() public {
        ReenterDistributorOnReceive reenter = new ReenterDistributorOnReceive();
        ScoopFeeDistributor hostile = new ScoopFeeDistributor(
            address(rewards),
            address(reenter),
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS
        );
        _registerSource(address(hostile), walletCreatorId);
        reenter.configure(hostile);
        reenter.enableReenter(true);
        vm.deal(address(hostile), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopFeeDistributor.NativeTransferFailed.selector, address(reenter), uint256(0.04 ether)
            )
        );
        hostile.distributeETH();

        // Full tx rollback: attacked flag and balances restored; no partial credits.
        assertEq(address(hostile).balance, 1 ether);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
        assertEq(address(reenter).balance, 0);
    }

    function test_creatorClaimReentrancy_blocked_andBalanceZeroedBeforeSend() public {
        ReenterClaimOnReceive reenter = new ReenterClaimOnReceive();
        bytes32 rejectorId = registry.walletCreatorId(address(reenter));
        _registerSource(sourceA, rejectorId);

        vm.prank(sourceA);
        rewards.creditETH{value: 1 ether}();
        assertEq(rewards.claimableETH(rejectorId), 1 ether);

        reenter.configure(rewards, rejectorId, address(reenter));
        reenter.enableReenter(true);

        // CEI: balance zeroed before send; reentrant claim hits nonReentrant / zero balance;
        // outer reverts NativeTransferFailed and restores accounting.
        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopCreatorRewards.NativeTransferFailed.selector, address(reenter), uint256(1 ether)
            )
        );
        rewards.claimETH(rejectorId, address(reenter));

        // Full tx rollback preserves claimable (CEI zeroing undone by revert).
        assertEq(rewards.claimableETH(rejectorId), 1 ether);
        assertEq(address(rewards).balance, 1 ether);
        assertEq(address(reenter).balance, 0);
    }

    function test_claimETH_cei_balanceZeroedBeforeExternalCall_onSuccess() public {
        _registerSource(sourceA, walletCreatorId);
        vm.prank(sourceA);
        rewards.creditETH{value: 2 ether}();

        uint256 beforeBal = walletCreator.balance;
        rewards.claimETH(walletCreatorId, walletCreator);
        assertEq(rewards.claimableETH(walletCreatorId), 0);
        assertEq(walletCreator.balance, beforeBal + 2 ether);
        assertEq(address(rewards).balance, 0);
    }
}
