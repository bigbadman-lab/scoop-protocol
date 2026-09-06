// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {ScoopProtocolDeploy} from "./ScoopProtocolDeploy.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";

/**
 * @title ScoopHelloCanaryLaunch
 * @notice ONE-OFF production HELLO canary helpers. Not general-purpose launch tooling.
 * @dev Protocol source is frozen. Does not broadcast. Does not mutate .env.
 */
library ScoopHelloCanaryLaunch {
    /// @dev Canonical production Factory from Phase A (chain 4663).
    address public constant EXPECTED_FACTORY = 0x15E874Bc667435ddbF2a67c0362701DC23C90833;
    /// @dev Dedicated HELLO canary wallet (not a protocol authority).
    address public constant EXPECTED_HELLO_CREATOR = 0x35AFfbCcC92ADd3FaB6b515326Da1433DcA7Cf9C;
    /// @dev keccak256(abi.encode(CreatorType.Wallet, EXPECTED_HELLO_CREATOR)).
    bytes32 public constant EXPECTED_CREATOR_ID = 0xffcbd42160aa8079474ac1074616a9c5f6e1e73a422c5a596a2f2cc978fa39ef;
    /// @dev Locked production salt — do not regenerate.
    bytes32 public constant PRODUCTION_SALT = 0x6b7c218e53e0f6a3131e7d4ff2fdd1a214495bdb54eaa2e4201a22ee5d0e3a68;

    uint256 public constant QUOTE_AMOUNT_IN = 0.01 ether;
    uint256 public constant MIN_TOKENS_OUT = 1;
    uint256 public constant EXPECTED_LAUNCH_FEE = 0.0005 ether;
    uint256 public constant TOTAL_VALUE = EXPECTED_LAUNCH_FEE + QUOTE_AMOUNT_IN; // 0.0105 ether
    uint8 public constant EXPECTED_ETH_FEED_DECIMALS = 8;

    string public constant NAME = "Hello World";
    string public constant SYMBOL = "HELLO";
    string public constant DESCRIPTION = "Hello, world. This is a test.";
    string public constant IMAGE_URI = "ipfs://bafybeihzgw4e5bppt5wu2eqrm524xdme6g73rzdoifo5hujjavnm7exwyi";
    string public constant TWITTER = "https://x.com/scoopterminal";
    string public constant WEBSITE = "https://scoop.fun";

    error HelloCanaryRefusal(string reason);
    error HelloCanaryPostAssert(string reason);

    struct Predicted {
        address token;
        address feeDistributor;
        address liquidityLocker;
        bytes32 launchSalt;
        bytes32 tokenSalt;
        bytes32 launchDomainSalt;
    }

    struct LaunchOutcome {
        address token;
        address feeDistributor;
        address liquidityLocker;
        uint256 lpTokenId;
        PoolId poolId;
        uint256 tokensBought;
    }

    struct Manifest {
        string mode;
        address factory;
        address helloCreator;
        bytes32 creatorId;
        bytes32 salt;
        Predicted predicted;
        LaunchOutcome outcome;
        uint256 launchFee;
        uint256 initialBuy;
        uint256 totalValue;
        uint256 minTokensOut;
    }

    function metadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: DESCRIPTION,
            imageUri: IMAGE_URI,
            twitter: TWITTER,
            telegram: "",
            discord: "",
            website: WEBSITE,
            farcaster: ""
        });
    }

    function buildParams(bytes32 creatorId) internal pure returns (ScoopFactory.LaunchParams memory) {
        return ScoopFactory.LaunchParams({
            name: NAME,
            symbol: SYMBOL,
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: metadata(),
            salt: PRODUCTION_SALT
        });
    }

    /// @notice Require locked HELLO creator address for this one-off canary.
    function requireExpectedHelloCreator(address helloCreator) internal pure {
        if (helloCreator == address(0)) revert HelloCanaryRefusal("HELLO_CREATOR_ADDRESS zero");
        if (helloCreator != EXPECTED_HELLO_CREATOR) {
            revert HelloCanaryRefusal("HELLO_CREATOR_ADDRESS must be locked canary wallet");
        }
    }

    /// @notice Require env Factory equals the locked production Factory for this canary.
    function requireExpectedFactory(address factory) internal pure {
        if (factory == address(0)) revert HelloCanaryRefusal("SCOOP_FACTORY zero");
        if (factory != EXPECTED_FACTORY) revert HelloCanaryRefusal("SCOOP_FACTORY must be production Factory");
    }

    function requireFactoryCode(address factory) internal view {
        if (factory.code.length == 0) revert HelloCanaryRefusal("SCOOP_FACTORY has no code");
    }

    /// @notice Live stack sanity: ETH quote/oracle, feed config, fee, AAPL off, creatorId lock.
    function assertProductionStackSane(ScoopFactory factory, address helloCreator, bytes32 expectedCreatorId)
        internal
        view
        returns (bytes32 creatorId)
    {
        requireRobinhood();
        requireExpectedHelloCreator(helloCreator);
        requireExpectedFactory(address(factory));
        requireFactoryCode(address(factory));

        ScoopQuoteRegistry quoteRegistry = factory.quoteRegistry();
        ScoopPriceOracle priceOracle = factory.priceOracle();
        address creatorRewards = address(factory.creatorRewards());
        address launchFeeRecipient = factory.launchFeeRecipient();

        if (address(quoteRegistry).code.length == 0) revert HelloCanaryRefusal("quoteRegistry no code");
        if (address(priceOracle).code.length == 0) revert HelloCanaryRefusal("priceOracle no code");
        if (creatorRewards.code.length == 0) revert HelloCanaryRefusal("creatorRewards no code");
        if (launchFeeRecipient == address(0)) revert HelloCanaryRefusal("launchFeeRecipient zero");

        if (factory.LAUNCH_FEE() != EXPECTED_LAUNCH_FEE) revert HelloCanaryRefusal("LAUNCH_FEE != 0.0005 ether");

        ScoopProtocolDeploy.assertEthConfigured(quoteRegistry, priceOracle, ScoopProtocolDeploy.PROPOSED_ETH_MAX_AGE);

        ScoopPriceOracle.PriceFeedConfig memory ethFeed = priceOracle.getFeedConfig(address(0));
        if (ethFeed.feed != ScoopProtocolDeploy.ETH_USD_FEED) revert HelloCanaryRefusal("ETH feed address");
        if (ethFeed.maxAge != ScoopProtocolDeploy.PROPOSED_ETH_MAX_AGE) revert HelloCanaryRefusal("ETH maxAge");
        if (ethFeed.feedDecimals != EXPECTED_ETH_FEED_DECIMALS) revert HelloCanaryRefusal("ETH feed decimals != 8");
        if (!ethFeed.enabled) revert HelloCanaryRefusal("ETH feed disabled");

        ScoopProtocolDeploy.assertAaplNotProductionRegistered(quoteRegistry);

        ScoopCreatorRegistry registry = ScoopCreatorRegistry(address(factory.creatorRewards().creatorRegistry()));
        creatorId = registry.walletCreatorId(helloCreator);
        if (creatorId != expectedCreatorId) revert HelloCanaryRefusal("creatorId mismatch vs locked value");
        if (creatorId != EXPECTED_CREATOR_ID) revert HelloCanaryRefusal("creatorId mismatch vs canary constant");
    }

    /// @notice Refusal helpers used by tests (and script preflight).
    function requireEthQuoteReady(ScoopQuoteRegistry quoteRegistry) internal view {
        if (!quoteRegistry.isRegistered(address(0))) revert HelloCanaryRefusal("ETH quote not registered");
        if (!quoteRegistry.isEnabled(address(0))) revert HelloCanaryRefusal("ETH quote not enabled");
    }

    function requireEthOracleReady(ScoopPriceOracle priceOracle) internal view {
        if (!priceOracle.isConfigured(address(0))) revert HelloCanaryRefusal("ETH oracle not configured");
        if (!priceOracle.isEnabled(address(0))) revert HelloCanaryRefusal("ETH oracle not enabled");
        ScoopPriceOracle.PriceFeedConfig memory ethFeed = priceOracle.getFeedConfig(address(0));
        if (ethFeed.feed != ScoopProtocolDeploy.ETH_USD_FEED) revert HelloCanaryRefusal("wrong ETH feed");
        if (ethFeed.maxAge != ScoopProtocolDeploy.PROPOSED_ETH_MAX_AGE) revert HelloCanaryRefusal("wrong ETH maxAge");
        if (ethFeed.feedDecimals != EXPECTED_ETH_FEED_DECIMALS) revert HelloCanaryRefusal("wrong ETH feed decimals");
        if (!ethFeed.enabled) revert HelloCanaryRefusal("ETH feed disabled");
    }

    function requireCreatorId(bytes32 actual, bytes32 expected) internal pure {
        if (actual != expected) revert HelloCanaryRefusal("wrong creatorId");
    }

    function requireSufficientEth(address helloCreator) internal view {
        if (helloCreator.balance < TOTAL_VALUE) {
            revert HelloCanaryRefusal("HELLO creator insufficient ETH for 0.0105");
        }
    }

    function predict(ScoopFactory factory, address helloCreator, ScoopFactory.LaunchParams memory params)
        internal
        view
        returns (Predicted memory p)
    {
        p.launchSalt = keccak256(abi.encode(helloCreator, params.salt));
        p.tokenSalt = keccak256(abi.encode(p.launchSalt, factory.TOKEN_DOMAIN()));
        p.launchDomainSalt = keccak256(abi.encode(p.launchSalt, factory.LAUNCH_DOMAIN()));

        ScoopToken.Socials memory socials = ScoopToken.Socials({
            twitter: params.metadata.twitter,
            telegram: params.metadata.telegram,
            discord: params.metadata.discord,
            website: params.metadata.website,
            farcaster: params.metadata.farcaster
        });

        ScoopTokenDeployer tokenDeployer = factory.tokenDeployer();
        p.token = tokenDeployer.predictTokenAddress(
            params.name,
            params.symbol,
            address(factory),
            helloCreator,
            address(factory),
            params.metadata.imageUri,
            params.metadata.description,
            socials,
            p.tokenSalt
        );

        ScoopLaunchDeployer launchDeployer = factory.launchDeployer();
        (p.feeDistributor, p.liquidityLocker) = launchDeployer.predictLaunch(
            address(factory.creatorRewards()),
            helloCreator,
            factory.buybackVault(),
            factory.operations(),
            factory.CREATOR_REWARDS_BPS(),
            factory.DEPLOYER_BPS(),
            factory.BUYBACK_BPS(),
            factory.OPERATIONS_BPS(),
            p.launchDomainSalt
        );
    }

    function requirePredictedSlotsEmpty(Predicted memory p) internal view {
        if (p.token == address(0)) revert HelloCanaryRefusal("predicted token zero");
        if (p.feeDistributor == address(0)) revert HelloCanaryRefusal("predicted feeDistributor zero");
        if (p.liquidityLocker == address(0)) revert HelloCanaryRefusal("predicted liquidityLocker zero");
        if (p.token.code.length != 0) revert HelloCanaryRefusal("predicted token already has code");
        if (p.feeDistributor.code.length != 0) revert HelloCanaryRefusal("predicted feeDistributor already has code");
        if (p.liquidityLocker.code.length != 0) {
            revert HelloCanaryRefusal("predicted liquidityLocker already has code");
        }
    }

    function requireLaunchDoesNotExist(ScoopFactory factory, address predictedToken) internal view {
        if (factory.isScoopToken(predictedToken)) {
            revert HelloCanaryRefusal("launch already exists for predicted token");
        }
    }

    /// @notice Call only launchAndBuy. Never plain launch.
    function executeLaunchAndBuy(ScoopFactory factory, ScoopFactory.LaunchParams memory params)
        internal
        returns (LaunchOutcome memory o)
    {
        (o.token, o.feeDistributor, o.liquidityLocker, o.lpTokenId, o.poolId, o.tokensBought) =
            factory.launchAndBuy{value: TOTAL_VALUE}(params, QUOTE_AMOUNT_IN, MIN_TOKENS_OUT);
    }

    function assertPostLaunch(
        ScoopFactory factory,
        address helloCreator,
        bytes32 creatorId,
        Predicted memory predicted,
        LaunchOutcome memory o
    ) internal view {
        if (o.token == address(0)) revert HelloCanaryPostAssert("token zero");
        if (o.token.code.length == 0) revert HelloCanaryPostAssert("token no code");
        if (o.token != predicted.token) revert HelloCanaryPostAssert("token != predicted");
        if (o.feeDistributor != predicted.feeDistributor) revert HelloCanaryPostAssert("feeDistributor != predicted");
        if (o.liquidityLocker != predicted.liquidityLocker) {
            revert HelloCanaryPostAssert("liquidityLocker != predicted");
        }
        if (o.feeDistributor.code.length == 0) revert HelloCanaryPostAssert("feeDistributor no code");
        if (o.liquidityLocker.code.length == 0) revert HelloCanaryPostAssert("liquidityLocker no code");
        if (o.tokensBought == 0) revert HelloCanaryPostAssert("tokensBought zero");
        if (IERC20(o.token).balanceOf(helloCreator) != o.tokensBought) {
            revert HelloCanaryPostAssert("initial buyer HELLO balance mismatch");
        }
        if (address(factory).balance != 0) revert HelloCanaryPostAssert("Factory ETH balance != 0");
        if (IERC20(o.token).balanceOf(address(factory)) != 0) {
            revert HelloCanaryPostAssert("Factory token balance != 0");
        }

        ScoopToken token = ScoopToken(o.token);
        if (keccak256(bytes(token.name())) != keccak256(bytes(NAME))) revert HelloCanaryPostAssert("name");
        if (keccak256(bytes(token.symbol())) != keccak256(bytes(SYMBOL))) revert HelloCanaryPostAssert("symbol");
        if (token.deployer() != helloCreator) revert HelloCanaryPostAssert("deployer");
        if (token.launchFactory() != address(factory)) revert HelloCanaryPostAssert("launchFactory");
        if (keccak256(bytes(token.logo())) != keccak256(bytes(IMAGE_URI))) revert HelloCanaryPostAssert("logo");
        if (keccak256(bytes(token.description())) != keccak256(bytes(DESCRIPTION))) {
            revert HelloCanaryPostAssert("description");
        }

        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = token.socials();
        if (keccak256(bytes(tw)) != keccak256(bytes(TWITTER))) revert HelloCanaryPostAssert("twitter");
        if (bytes(tg).length != 0) revert HelloCanaryPostAssert("telegram");
        if (bytes(dc).length != 0) revert HelloCanaryPostAssert("discord");
        if (keccak256(bytes(web)) != keccak256(bytes(WEBSITE))) revert HelloCanaryPostAssert("website");
        if (bytes(fc).length != 0) revert HelloCanaryPostAssert("farcaster");

        ScoopFactory.Launch memory rec = factory.getLaunch(o.token);
        if (rec.creatorId != creatorId) revert HelloCanaryPostAssert("launch.creatorId");
        if (rec.quoteAsset != address(0)) revert HelloCanaryPostAssert("launch.quoteAsset");
        if (rec.deployer != helloCreator) revert HelloCanaryPostAssert("launch.deployer");
        if (rec.feeDistributor != o.feeDistributor) revert HelloCanaryPostAssert("launch.feeDistributor");
        if (rec.liquidityLocker != o.liquidityLocker) revert HelloCanaryPostAssert("launch.liquidityLocker");
        if (rec.lpTokenId != o.lpTokenId) revert HelloCanaryPostAssert("launch.lpTokenId");

        if (IERC721(ScoopProtocolDeploy.POSITION_MANAGER).ownerOf(o.lpTokenId) != o.liquidityLocker) {
            revert HelloCanaryPostAssert("PositionManager owner != liquidityLocker");
        }
    }

    function requireRobinhood() internal view {
        ScoopProtocolDeploy.requireRobinhoodChain();
    }

    function logManifest(Manifest memory m) internal view {
        console2.log("==== HELLO PRODUCTION CANARY MANIFEST ====");
        console2.log("mode", m.mode);
        console2.log("chainId", block.chainid);
        console2.log("Factory", m.factory);
        console2.log("HELLO creator", m.helloCreator);
        console2.logBytes32(m.creatorId);
        console2.logBytes32(m.salt);
        console2.log("name", NAME);
        console2.log("symbol", SYMBOL);
        console2.log("imageUri", IMAGE_URI);
        console2.log("quoteAsset", address(0));
        console2.log("launchFee", m.launchFee);
        console2.log("initialBuy", m.initialBuy);
        console2.log("totalValue", m.totalValue);
        console2.log("minTokensOut", m.minTokensOut);
        console2.log("predicted token", m.predicted.token);
        console2.log("predicted feeDistributor", m.predicted.feeDistributor);
        console2.log("predicted liquidityLocker", m.predicted.liquidityLocker);
        console2.log("actual token", m.outcome.token);
        console2.log("feeDistributor", m.outcome.feeDistributor);
        console2.log("liquidityLocker", m.outcome.liquidityLocker);
        console2.log("lpTokenId", m.outcome.lpTokenId);
        console2.logBytes32(PoolId.unwrap(m.outcome.poolId));
        console2.log("tokensBought", m.outcome.tokensBought);
        console2.log("creator HELLO balance", IERC20(m.outcome.token).balanceOf(m.helloCreator));
        console2.log("Factory ETH balance", m.factory.balance);
        console2.log("Factory token balance", IERC20(m.outcome.token).balanceOf(m.factory));
        console2.log("HELLO_CANARY_COMPLETE", true);
        console2.log("STOP - perform mainnet canary forensics before any additional launch");
    }
}
