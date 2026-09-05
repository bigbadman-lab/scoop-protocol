// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopTestToken} from "../../src/ScoopTestToken.sol";
import {ScoopInvariantHandler, IScoopInvariantRegistrar} from "./ScoopInvariantHandler.sol";

/**
 * @notice Local stateful invariants (no Uniswap).
 * @dev Run with: FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=32 forge test --match-contract ScoopProtocolInvariantTest -vv
 */
contract ScoopProtocolInvariantTest is StdInvariant, Test, IScoopInvariantRegistrar {
    uint16 constant CREATOR_REWARDS_BPS = 7000;
    uint16 constant DEPLOYER_BPS = 400;
    uint16 constant BUYBACK_BPS = 2000;
    uint16 constant OPERATIONS_BPS = 600;

    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopFeeDistributor distributor;
    ScoopTestToken token;
    ScoopInvariantHandler handler;

    address verificationAuthority;
    uint256 verificationAuthorityKey;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address walletCreator;

    bytes32 walletCreatorId;
    bytes32 xCreatorId;

    /// @dev Registrar proxy for the handler — only the handler may request registrations.
    function registerSourceAsRegistrar(address source, bytes32 creatorId) external override {
        require(msg.sender == address(handler), "only handler");
        rewards.registerSource(source, creatorId);
    }

    function setUp() public {
        (verificationAuthority, verificationAuthorityKey) = makeAddrAndKey("verificationAuthority");
        deployerRecipient = makeAddr("deployerRecipient");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        walletCreator = makeAddr("walletCreator");

        registry = new ScoopCreatorRegistry(verificationAuthority);
        // This test contract is the immutable sourceRegistrar.
        rewards = new ScoopCreatorRewards(address(registry), address(this));
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
        token = new ScoopTestToken("Scoop Test", "SCOOPT", address(this), type(uint128).max);

        handler = new ScoopInvariantHandler(
            registry,
            rewards,
            distributor,
            token,
            IScoopInvariantRegistrar(address(this)),
            verificationAuthorityKey,
            deployerRecipient,
            buybackVault,
            operations,
            walletCreator
        );

        token.transfer(address(handler), 50_000_000 ether);
        vm.deal(address(handler), 100 ether);

        walletCreatorId = registry.walletCreatorId(walletCreator);
        xCreatorId = registry.xCreatorId(handler.X_USER());

        // Seed distributor as a permanent source.
        rewards.registerSource(address(distributor), walletCreatorId);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = ScoopInvariantHandler.registerSource.selector;
        selectors[1] = ScoopInvariantHandler.creditETH.selector;
        selectors[2] = ScoopInvariantHandler.creditToken.selector;
        selectors[3] = ScoopInvariantHandler.distributeETH.selector;
        selectors[4] = ScoopInvariantHandler.distributeToken.selector;
        selectors[5] = ScoopInvariantHandler.claimETH.selector;
        selectors[6] = ScoopInvariantHandler.claimToken.selector;
        selectors[7] = ScoopInvariantHandler.claimXIdentity.selector;
        selectors[8] = ScoopInvariantHandler.claimXETH.selector;
        selectors[9] = ScoopInvariantHandler.claimXToken.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        excludeContract(address(this));
    }

    function invariant_destinationsImmutable() public view {
        assertEq(distributor.creatorRewards(), address(rewards));
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.creatorRewardsBps(), CREATOR_REWARDS_BPS);
        assertEq(distributor.deployerBps(), DEPLOYER_BPS);
        assertEq(distributor.buybackBps(), BUYBACK_BPS);
        assertEq(distributor.operationsBps(), OPERATIONS_BPS);
    }

    function invariant_sourceCreatorIdWriteOnce() public view {
        assertEq(rewards.sourceCreatorId(address(distributor)), walletCreatorId);
    }

    function invariant_xBindingWriteOnce() public view {
        if (handler.xClaimed()) {
            assertEq(registry.xResolvedWallet(handler.X_USER()), walletCreator);
            assertTrue(registry.isClaimed(xCreatorId));
        }
    }

    function invariant_claimDoesNotOverpayETH() public view {
        uint256 claimable = rewards.claimableETH(walletCreatorId) + rewards.claimableETH(xCreatorId);
        assertGe(address(rewards).balance, claimable);
    }

    function invariant_totalCreditedEqualsClaimedPlusClaimableETH() public view {
        uint256 claimable = rewards.claimableETH(walletCreatorId) + rewards.claimableETH(xCreatorId);
        assertEq(handler.ghostEthClaimed() + claimable, handler.ghostEthCredited());
    }

    function invariant_totalCreditedEqualsClaimedPlusClaimableToken() public view {
        uint256 claimable = rewards.claimableToken(walletCreatorId, address(token))
            + rewards.claimableToken(xCreatorId, address(token));
        assertEq(handler.ghostTokenClaimed() + claimable, handler.ghostTokenCredited());
    }

    function invariant_feeConservationDestinationsPinned() public view {
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.creatorRewards(), address(rewards));
    }

    receive() external payable {}
}
