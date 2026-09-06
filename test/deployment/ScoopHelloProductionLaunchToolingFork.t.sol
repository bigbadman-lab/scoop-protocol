// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {ScoopHelloCanaryLaunch} from "../../script/ScoopHelloCanaryLaunch.sol";
import {ScoopProtocolDeploy} from "../../script/ScoopProtocolDeploy.sol";
import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopToken} from "../../src/ScoopToken.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";

/**
 * @notice Milestone 5D HELLO — production canary launch tooling on a Robinhood fork.
 * @dev ONE HELLO canary only. Uses live production Factory when present. No broadcast.
 *
 *      HELLO was actually deployed at L2 block 55_863_290. This suite intentionally rehearses
 *      the production launch against the immediately preceding L2 chain state
 *      (PRE_HELLO_FORK_BLOCK = 55_863_289). Latest-chain state must NOT be used for the
 *      successful launch rehearsal because the production CREATE2 slots are now occupied.
 *      Runtime production tooling must continue refusing occupied CREATE2 slots
 *      (`requirePredictedSlotsEmpty` / `requireLaunchDoesNotExist`).
 *
 *      Robinhood is OP-stack: `createSelectFork(..., PRE_HELLO_FORK_BLOCK)` pins by L2
 *      sequence number, while EVM `block.number` reflects the L1 origin block for that L2
 *      block (HELLO receipt: L2 55_863_290 ↔ l1BlockNumber 25_917_345). Pre-HELLO state is
 *      therefore asserted via vacant predicted CREATE2 code, not `block.number` equality.
 */
contract ScoopHelloProductionLaunchToolingForkTest is Test {
    /// @dev L2 block immediately before HELLO mainnet canary tx at L2 55_863_290.
    uint256 internal constant PRE_HELLO_FORK_BLOCK = 55_863_289;
    /// @dev Canonical HELLO token — must have no code at PRE_HELLO_FORK_BLOCK.
    address internal constant HELLO_TOKEN = 0x2284ed0e4d446c6D78aC2d49a68BAE822Fd87373;

    ScoopFactory internal factory;
    address internal helloCreator;
    bytes32 internal creatorId;
    uint256 internal forkBlock;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), PRE_HELLO_FORK_BLOCK);
        forkBlock = PRE_HELLO_FORK_BLOCK;
        // Prove the fork is pre-HELLO: production CREATE2 token slot must be empty.
        assertEq(HELLO_TOKEN.code.length, 0, "fork must be pre-HELLO (token CREATE2 slot occupied on tip)");

        ScoopHelloCanaryLaunch.requireRobinhood();
        ScoopProtocolDeploy.assertCanonicalExternalBytecode();

        address factoryAddr = ScoopHelloCanaryLaunch.EXPECTED_FACTORY;
        helloCreator = ScoopHelloCanaryLaunch.EXPECTED_HELLO_CREATOR;

        require(factoryAddr.code.length > 0, "production Factory missing code - Phase A incomplete?");
        factory = ScoopFactory(factoryAddr);

        creatorId = ScoopHelloCanaryLaunch.assertProductionStackSane(
            factory, helloCreator, ScoopHelloCanaryLaunch.EXPECTED_CREATOR_ID
        );

        // Ensure canary wallet can pay launch+buy on this fork.
        vm.deal(helloCreator, 1 ether);

        console2.log("forkBlock (L2 pin)", forkBlock);
        console2.log("evm block.number (L1 origin)", block.number);
        console2.log("production Factory", address(factory));
        console2.log("HELLO creator", helloCreator);
        console2.logBytes32(creatorId);
    }

    function test_wrongChain_reverts() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ScoopProtocolDeploy.WrongChainId.selector, uint256(4663), uint256(1)));
        this.externalRequireRobinhood();
    }

    function test_wrongFactoryAddress_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "SCOOP_FACTORY must be production Factory"
            )
        );
        this.externalRequireExpectedFactory(address(0xBEEF));
    }

    function test_factoryNoCode_reverts() public {
        address empty = makeAddr("emptyFactory");
        // Bypass expected-factory lock to isolate no-code check.
        vm.expectRevert(
            abi.encodeWithSelector(ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "SCOOP_FACTORY has no code")
        );
        this.externalRequireFactoryCode(empty);
    }

    function test_wrongHelloCreator_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "HELLO_CREATOR_ADDRESS must be locked canary wallet"
            )
        );
        this.externalRequireExpectedHelloCreator(makeAddr("notHello"));
    }

    function test_wrongSignerPrivateKey_reverts() public {
        uint256 wrongPk = uint256(keccak256("wrong-hello-signer"));
        address derived = vm.addr(wrongPk);
        assertTrue(derived != helloCreator);
        // Mirrors LaunchHello signer gate without loading env secrets.
        vm.expectRevert("LaunchHello: HELLO_CREATOR_PRIVATE_KEY does not match HELLO_CREATOR_ADDRESS");
        this.externalRequireSignerMatch(wrongPk, helloCreator);
    }

    function test_wrongCreatorId_reverts() public {
        bytes32 wrong = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "wrong creatorId"));
        this.externalRequireCreatorId(wrong, ScoopHelloCanaryLaunch.EXPECTED_CREATOR_ID);
    }

    function test_ethQuoteNotEnabled_refuses() public {
        ScoopQuoteRegistry quoteRegistry = factory.quoteRegistry();
        address authority = quoteRegistry.registryAuthority();
        vm.prank(authority);
        quoteRegistry.setQuoteEnabled(address(0), false);

        vm.expectRevert(
            abi.encodeWithSelector(ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "ETH quote not enabled")
        );
        this.externalRequireEthQuoteReady(quoteRegistry);
    }

    function test_oracleNotEnabled_refuses() public {
        ScoopPriceOracle priceOracle = factory.priceOracle();
        address authority = priceOracle.oracleAuthority();
        vm.prank(authority);
        priceOracle.setFeedEnabled(address(0), false);

        vm.expectRevert(
            abi.encodeWithSelector(ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "ETH oracle not enabled")
        );
        this.externalRequireEthOracleReady(priceOracle);
    }

    function test_wrongEthMaxAge_refuses() public {
        ScoopPriceOracle priceOracle = factory.priceOracle();
        address authority = priceOracle.oracleAuthority();
        vm.prank(authority);
        priceOracle.setMaxAge(address(0), 1);

        vm.expectRevert(abi.encodeWithSelector(ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "wrong ETH maxAge"));
        this.externalRequireEthOracleReady(priceOracle);
    }

    function test_saltCollision_codePresent_refuses() public {
        ScoopFactory.LaunchParams memory params = ScoopHelloCanaryLaunch.buildParams(creatorId);
        ScoopHelloCanaryLaunch.Predicted memory predicted =
            ScoopHelloCanaryLaunch.predict(factory, helloCreator, params);

        // Occupy predicted token CREATE2 slot.
        vm.etch(predicted.token, hex"00");

        vm.expectRevert(
            abi.encodeWithSelector(
                ScoopHelloCanaryLaunch.HelloCanaryRefusal.selector, "predicted token already has code"
            )
        );
        this.externalRequirePredictedSlotsEmpty(predicted);
    }

    function test_helloMetadata_isExact() public view {
        ScoopFactory.LaunchMetadata memory md = ScoopHelloCanaryLaunch.metadata();
        assertEq(md.description, "Hello, world. This is a test.");
        assertEq(md.imageUri, "ipfs://bafybeihzgw4e5bppt5wu2eqrm524xdme6g73rzdoifo5hujjavnm7exwyi");
        assertEq(md.twitter, "https://x.com/scoopterminal");
        assertEq(md.telegram, "");
        assertEq(md.discord, "");
        assertEq(md.website, "https://scoop.fun");
        assertEq(md.farcaster, "");

        ScoopFactory.LaunchParams memory params = ScoopHelloCanaryLaunch.buildParams(creatorId);
        assertEq(params.name, "Hello World");
        assertEq(params.symbol, "HELLO");
        assertEq(params.quoteAsset, address(0));
        assertEq(params.salt, ScoopHelloCanaryLaunch.PRODUCTION_SALT);
        assertEq(params.creatorId, ScoopHelloCanaryLaunch.EXPECTED_CREATOR_ID);
    }

    function test_launchAndBuy_succeeds_oneHelloCanaryOnly() public {
        ScoopFactory.LaunchParams memory params = ScoopHelloCanaryLaunch.buildParams(creatorId);
        ScoopHelloCanaryLaunch.Predicted memory predicted =
            ScoopHelloCanaryLaunch.predict(factory, helloCreator, params);

        ScoopHelloCanaryLaunch.requirePredictedSlotsEmpty(predicted);
        ScoopHelloCanaryLaunch.requireLaunchDoesNotExist(factory, predicted.token);
        ScoopHelloCanaryLaunch.requireSufficientEth(helloCreator);

        assertEq(ScoopHelloCanaryLaunch.QUOTE_AMOUNT_IN, 0.01 ether);
        assertEq(ScoopHelloCanaryLaunch.EXPECTED_LAUNCH_FEE, 0.0005 ether);
        assertEq(ScoopHelloCanaryLaunch.TOTAL_VALUE, 0.0105 ether);
        assertEq(factory.LAUNCH_FEE(), 0.0005 ether);

        uint256 feeRecipientBefore = factory.launchFeeRecipient().balance;
        uint256 creatorBefore = helloCreator.balance;

        vm.recordLogs();
        vm.prank(helloCreator);
        ScoopHelloCanaryLaunch.LaunchOutcome memory outcome =
            ScoopHelloCanaryLaunch.executeLaunchAndBuy(factory, params);

        ScoopHelloCanaryLaunch.assertPostLaunch(factory, helloCreator, creatorId, predicted, outcome);

        assertEq(factory.launchFeeRecipient().balance - feeRecipientBefore, 0.0005 ether);
        assertEq(creatorBefore - helloCreator.balance, 0.0105 ether);
        assertEq(IERC20(outcome.token).balanceOf(helloCreator), outcome.tokensBought);
        assertGt(outcome.tokensBought, 0);

        _assertEvents(vm.getRecordedLogs(), outcome.token);

        ScoopToken token = ScoopToken(outcome.token);
        assertEq(token.name(), "Hello World");
        assertEq(token.symbol(), "HELLO");
        assertEq(token.deployer(), helloCreator);
        assertEq(token.launchFactory(), address(factory));
        assertEq(token.logo(), ScoopHelloCanaryLaunch.IMAGE_URI);
        assertEq(token.description(), ScoopHelloCanaryLaunch.DESCRIPTION);

        ScoopFactory.Launch memory rec = factory.getLaunch(outcome.token);
        assertEq(rec.creatorId, creatorId);
        assertEq(rec.quoteAsset, address(0));
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(outcome.token).balanceOf(address(factory)), 0);
        assertEq(IERC721(ScoopProtocolDeploy.POSITION_MANAGER).ownerOf(outcome.lpTokenId), outcome.liquidityLocker);

        console2.log("HELLO canary token", outcome.token);
        console2.log("HELLO feeDistributor", outcome.feeDistributor);
        console2.log("HELLO liquidityLocker", outcome.liquidityLocker);
        console2.log("HELLO tokensBought", outcome.tokensBought);
        console2.log("ONE_HELLO_CANARY_ONLY", true);
        console2.log("HELLO_CANARY_COMPLETE", true);
        console2.log("STOP - perform mainnet canary forensics before any additional launch");
    }

    function test_productionSalt_andCreatorId_locked() public view {
        assertEq(
            ScoopHelloCanaryLaunch.PRODUCTION_SALT,
            bytes32(0x6b7c218e53e0f6a3131e7d4ff2fdd1a214495bdb54eaa2e4201a22ee5d0e3a68)
        );
        assertEq(
            ScoopHelloCanaryLaunch.EXPECTED_CREATOR_ID,
            bytes32(0xffcbd42160aa8079474ac1074616a9c5f6e1e73a422c5a596a2f2cc978fa39ef)
        );
        ScoopCreatorRegistry registry =
            ScoopCreatorRegistry(ScoopCreatorRewards(address(factory.creatorRewards())).creatorRegistry());
        assertEq(registry.walletCreatorId(helloCreator), ScoopHelloCanaryLaunch.EXPECTED_CREATOR_ID);
    }

    // --- external wrappers for expectRevert ---

    function externalRequireRobinhood() external view {
        ScoopHelloCanaryLaunch.requireRobinhood();
    }

    function externalRequireExpectedFactory(address factoryAddr) external pure {
        ScoopHelloCanaryLaunch.requireExpectedFactory(factoryAddr);
    }

    function externalRequireFactoryCode(address factoryAddr) external view {
        ScoopHelloCanaryLaunch.requireFactoryCode(factoryAddr);
    }

    function externalRequireExpectedHelloCreator(address creator) external pure {
        ScoopHelloCanaryLaunch.requireExpectedHelloCreator(creator);
    }

    function externalRequireSignerMatch(uint256 pk, address expected) external view {
        address derived = vm.addr(pk);
        require(derived == expected, "LaunchHello: HELLO_CREATOR_PRIVATE_KEY does not match HELLO_CREATOR_ADDRESS");
    }

    function externalRequireCreatorId(bytes32 actual, bytes32 expected) external pure {
        ScoopHelloCanaryLaunch.requireCreatorId(actual, expected);
    }

    function externalRequireEthQuoteReady(ScoopQuoteRegistry quoteRegistry) external view {
        ScoopHelloCanaryLaunch.requireEthQuoteReady(quoteRegistry);
    }

    function externalRequireEthOracleReady(ScoopPriceOracle priceOracle) external view {
        ScoopHelloCanaryLaunch.requireEthOracleReady(priceOracle);
    }

    function externalRequirePredictedSlotsEmpty(ScoopHelloCanaryLaunch.Predicted calldata predicted) external view {
        ScoopHelloCanaryLaunch.requirePredictedSlotsEmpty(predicted);
    }

    function _assertEvents(Vm.Log[] memory logs, address token) internal pure {
        bytes32 feeTopic = keccak256("LaunchFeePaid(address,address,uint256)");
        bytes32 createdTopic = keccak256("ScoopTokenCreated(address,string,string,string)");
        bytes32 launchedTopic = keccak256(
            "TokenLaunched(address,address,bytes32,address,address,address,bytes32,uint256,uint160,int24,int24,int24,string,string)"
        );
        bytes32 buyTopic = keccak256("InitialBuyExecuted(address,address,address,uint256,uint256)");

        bool sawFee;
        bool sawCreated;
        bool sawLaunched;
        bool sawBuy;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == feeTopic) sawFee = true;
            if (t0 == createdTopic && logs[i].topics.length > 1) {
                if (address(uint160(uint256(logs[i].topics[1]))) == token) sawCreated = true;
            }
            if (t0 == launchedTopic && logs[i].topics.length > 1) {
                if (address(uint160(uint256(logs[i].topics[1]))) == token) sawLaunched = true;
            }
            if (t0 == buyTopic) sawBuy = true;
        }
        assertTrue(sawFee, "LaunchFeePaid");
        assertTrue(sawCreated, "ScoopTokenCreated");
        assertTrue(sawLaunched, "TokenLaunched");
        assertTrue(sawBuy, "InitialBuyExecuted");
    }
}
