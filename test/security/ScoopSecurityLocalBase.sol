// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopFeeDistributor} from "../../src/ScoopFeeDistributor.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopTestToken} from "../../src/ScoopTestToken.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/**
 * @notice Shared local harness for Milestone 5B security unit tests (no Uniswap).
 * @dev CreatorRewards is deployed with `sourceRegistrar = address(this)` so tests can
 *      register sources directly. Use ScoopFactoryDeployer when a Factory-linked
 *      registrar is required.
 */
abstract contract ScoopSecurityLocalBase is Test {
    uint16 internal constant CREATOR_REWARDS_BPS = 7000;
    uint16 internal constant DEPLOYER_BPS = 400;
    uint16 internal constant BUYBACK_BPS = 2000;
    uint16 internal constant OPERATIONS_BPS = 600;

    ScoopCreatorRegistry internal registry;
    ScoopCreatorRewards internal rewards;
    ScoopFeeDistributor internal distributor;
    ScoopQuoteRegistry internal quoteRegistry;
    ScoopPriceOracle internal priceOracle;
    MockAggregatorV3 internal ethFeed;
    ScoopTestToken internal token;

    address internal verificationAuthority;
    uint256 internal verificationAuthorityKey;
    address internal registryAuthority;
    address internal oracleAuthority;
    address internal deployerRecipient;
    address internal buybackVault;
    address internal operations;
    address internal sourceA;
    address internal walletCreator;
    address internal otherWallet;
    address internal relayer;
    address internal attacker;

    uint256 internal constant X_USER = 123456789;

    bytes32 internal walletCreatorId;
    bytes32 internal xCreatorId;

    function setUp() public virtual {
        (verificationAuthority, verificationAuthorityKey) = makeAddrAndKey("verificationAuthority");
        registryAuthority = makeAddr("registryAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        deployerRecipient = makeAddr("deployerRecipient");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        sourceA = makeAddr("sourceA");
        walletCreator = makeAddr("walletCreator");
        otherWallet = makeAddr("otherWallet");
        relayer = makeAddr("relayer");
        attacker = makeAddr("attacker");

        registry = new ScoopCreatorRegistry(verificationAuthority);
        // Unit-test registrar is this harness (not Factory).
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

        quoteRegistry = new ScoopQuoteRegistry(registryAuthority);
        priceOracle = new ScoopPriceOracle(oracleAuthority);

        ethFeed = new MockAggregatorV3(8);
        vm.warp(1_000);
        ethFeed.setRound(1, 1e8, 900, 1000, 1);

        vm.prank(registryAuthority);
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        vm.prank(oracleAuthority);
        priceOracle.configureFeed(address(0), address(ethFeed), 3600);

        token = new ScoopTestToken("Scoop Test", "SCOOPT", address(this), 1_000_000_000 ether);

        walletCreatorId = registry.walletCreatorId(walletCreator);
        xCreatorId = registry.xCreatorId(X_USER);

        vm.deal(sourceA, 100 ether);
        vm.deal(address(this), 100 ether);
        token.transfer(sourceA, 1_000_000 ether);
    }

    function _registerSource(address source, bytes32 creatorId) internal {
        rewards.registerSource(source, creatorId);
    }

    function _signClaimX(uint256 xUserId, address wallet, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = registry.hashClaimXIdentity(xUserId, wallet, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(verificationAuthorityKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _claimX(uint256 xUserId, address wallet) internal {
        uint256 deadline = block.timestamp + 1 days;
        registry.claimXIdentity(xUserId, wallet, deadline, _signClaimX(xUserId, wallet, deadline));
    }

    function _approveToken(address owner_, address spender, uint256 amount) internal {
        vm.prank(owner_);
        token.approve(spender, amount);
    }

    receive() external payable {}
}
