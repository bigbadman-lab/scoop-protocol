// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/libraries/PositionInfoLibrary.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../src/ScoopFactoryDeployer.sol";
import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopLiquidityLocker} from "../src/ScoopLiquidityLocker.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";

/**
 * @notice Milestone 4K — Factory→ScoopToken metadata wiring, terminal discovery, salt collision.
 */
contract ScoopFactoryTokenMetadataForkTest is Test {
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    uint48 constant TEST_MAX_AGE = 7 days;
    uint256 constant FDV_REL_TOL = 1e15;
    uint256 constant LAUNCH_FEE = 0.0005 ether;

    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopTokenDeployer tokenDeployer;
    ScoopLaunchDeployer launchDeployer;
    ScoopQuoteRegistry quoteRegistry;
    ScoopPriceOracle priceOracle;
    ScoopFactory factory;

    address authority;
    uint256 authorityKey;
    address quoteAuthority;
    address oracleAuthority;
    address buybackVault;
    address operations;
    address launchFeeRecipient;
    address deployer;
    address walletCreator;
    address otherCreator;

    event ScoopTokenCreated(address indexed token, string description, string website, string imageUri);

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        (authority, authorityKey) = makeAddrAndKey("verificationAuthority");
        quoteAuthority = makeAddr("quoteAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        launchFeeRecipient = makeAddr("launchFeeRecipient");
        deployer = makeAddr("launchDeployer");
        walletCreator = makeAddr("walletCreator");
        otherCreator = makeAddr("otherCreator");

        registry = new ScoopCreatorRegistry(authority);
        tokenDeployer = new ScoopTokenDeployer();
        launchDeployer = new ScoopLaunchDeployer(POSITION_MANAGER_ADDR);
        quoteRegistry = new ScoopQuoteRegistry(quoteAuthority);
        priceOracle = new ScoopPriceOracle(oracleAuthority);

        vm.startPrank(quoteAuthority);
        quoteRegistry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        quoteRegistry.registerQuote(AAPL_TOKEN, ScoopQuoteRegistry.QuoteType.Stock);
        vm.stopPrank();

        vm.startPrank(oracleAuthority);
        priceOracle.configureFeed(address(0), ETH_USD_FEED, TEST_MAX_AGE);
        priceOracle.configureFeed(AAPL_TOKEN, AAPL_USD_FEED, TEST_MAX_AGE);
        vm.stopPrank();

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(registry),
            POOL_MANAGER_ADDR,
            POSITION_MANAGER_ADDR,
            PERMIT2_ADDR,
            UNIVERSAL_ROUTER_ADDR,
            address(tokenDeployer),
            address(launchDeployer),
            address(quoteRegistry),
            address(priceOracle),
            buybackVault,
            operations,
            launchFeeRecipient
        );
        factory = protocol.factory();
        rewards = protocol.creatorRewards();

        vm.deal(deployer, 50 ether);
    }

    function test_launchMetadataReachesToken_andEventConsistency() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.realisticMetadata();
        bytes32 creatorId = registry.walletCreatorId(walletCreator);

        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,) = factory.launch{value: LAUNCH_FEE}(
            ScoopFactory.LaunchParams({
                name: "Meta",
                symbol: "META",
                creatorId: creatorId,
                quoteAsset: address(0),
                metadata: md,
                salt: bytes32(uint256(1))
            })
        );

        ScoopToken t = ScoopToken(token);
        assertEq(t.logo(), md.imageUri);
        assertEq(t.description(), md.description);
        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = t.socials();
        assertEq(tw, md.twitter);
        assertEq(tg, md.telegram);
        assertEq(dc, md.discord);
        assertEq(web, md.website);
        assertEq(fc, md.farcaster);
        assertEq(t.deployer(), deployer);
        assertEq(t.launchFactory(), address(factory));

        (address evToken, string memory evDesc, string memory evWeb, string memory evImg) =
            _decodeCreated(vm.getRecordedLogs());
        assertEq(evToken, token);
        assertEq(evDesc, t.description());
        assertEq(evWeb, web);
        assertEq(evImg, t.logo());
    }

    function test_terminalStyleTokenOnlyDiscovery() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.realisticMetadata();
        address token = _launchEth("Term", "TERM", bytes32(uint256(2)), md, registry.walletCreatorId(walletCreator));

        // Consumer knows ONLY the token address — no Factory reads.
        ScoopToken t = ScoopToken(token);
        assertEq(t.name(), "Term");
        assertEq(t.symbol(), "TERM");
        assertEq(t.decimals(), 18);
        assertEq(t.logo(), md.imageUri);
        assertEq(t.description(), md.description);
        (,,, string memory web,) = t.socials();
        assertEq(web, md.website);
        assertEq(t.deployer(), deployer);
        assertEq(t.launchFactory(), address(factory));
        string memory uri = t.contractURI();
        assertTrue(bytes(uri).length > 0);
        assertEq(bytes(uri)[0], bytes1("d")); // data:...
    }

    function test_sameSaltDifferentMetadataStillCollides() public {
        ScoopFactory.LaunchMetadata memory a = ScoopLaunchMetadataHelpers.defaultMetadata();
        ScoopFactory.LaunchMetadata memory b = ScoopLaunchMetadataHelpers.realisticMetadata();
        bytes32 salt = bytes32(uint256(99));
        bytes32 creatorId = registry.walletCreatorId(walletCreator);

        _launchEth("A", "A", salt, a, creatorId);

        vm.prank(deployer);
        vm.expectRevert(); // launch-component CREATE2 collision (metadata-independent salt)
        factory.launch{value: LAUNCH_FEE}(
            ScoopFactory.LaunchParams({
                name: "B", symbol: "B", creatorId: creatorId, quoteAsset: address(0), metadata: b, salt: salt
            })
        );
    }

    function test_creatorIdIndependentOfTokenDeployerAndSocialX() public {
        // Deployer = Alice; creatorId = Bob; social X URL is unrelated.
        address alice = deployer;
        bytes32 bobId = registry.walletCreatorId(otherCreator);
        ScoopFactory.LaunchMetadata memory md = ScoopFactory.LaunchMetadata({
            description: "sep",
            imageUri: "ipfs://bafy-sep",
            twitter: "https://x.com/notbob",
            telegram: "",
            discord: "",
            website: "https://example.com",
            farcaster: ""
        });

        vm.prank(alice);
        (address token, address feeDist,,,) = factory.launch{value: LAUNCH_FEE}(
            ScoopFactory.LaunchParams({
                name: "Sep",
                symbol: "SEP",
                creatorId: bobId,
                quoteAsset: address(0),
                metadata: md,
                salt: bytes32(uint256(3))
            })
        );

        assertEq(ScoopToken(token).deployer(), alice);
        assertEq(ScoopFeeDistributor(payable(feeDist)).deployer(), alice);
        assertEq(rewards.sourceCreatorId(feeDist), bobId);
        (string memory tw,,,,) = ScoopToken(token).socials();
        assertEq(tw, "https://x.com/notbob");
    }

    function test_ethLaunchEconomicsUnchanged() public {
        address token = _launchEth(
            "Eco",
            "ECO",
            bytes32(uint256(4)),
            ScoopLaunchMetadataHelpers.defaultMetadata(),
            registry.walletCreatorId(walletCreator)
        );
        ScoopFactory.Launch memory rec = factory.getLaunch(token);
        assertEq(int256(factory.TICK_SPACING()), 10);
        assertEq(uint256(factory.LP_FEE()), 10_000);
        assertEq(factory.LAUNCH_FEE(), LAUNCH_FEE);
        assertEq(int256(rec.tickLower), int256(TickMath.minUsableTick(10)));
        assertTrue(rec.tickUpper <= rec.openingTick);
        assertGt(int256(rec.tickUpper - rec.tickLower), 10);
        assertEq(IERC721(POSITION_MANAGER_ADDR).ownerOf(rec.lpTokenId), rec.liquidityLocker);
        assertEq(address(factory).balance, 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);

        (, uint256 fdv) = _reconstructFdv(rec);
        assertApproxEqRel(fdv, 5_000e18, FDV_REL_TOL);

        console2.log("4K plain launch bytecode", token.code.length);
    }

    function test_ethLaunchAndBuy_withMetadata() public {
        bytes32 creatorId = registry.walletCreatorId(walletCreator);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Buy",
            symbol: "BUY",
            creatorId: creatorId,
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.realisticMetadata(),
            salt: bytes32(uint256(5))
        });
        uint256 quoteIn = 0.01 ether;
        vm.prank(deployer);
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: LAUNCH_FEE + quoteIn}(params, quoteIn, 1);
        assertGt(bought, 0);
        assertEq(ScoopToken(token).deployer(), deployer);
        assertEq(address(factory).balance, 0);
        console2.log("4K native launchAndBuy gas path ok", bought);
    }

    function test_aaplLaunchAndBuy_withMetadata() public {
        bytes32 salt = _findSalt("Ap", "AP", true);
        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "Ap",
            symbol: "AP",
            creatorId: registry.walletCreatorId(walletCreator),
            quoteAsset: AAPL_TOKEN,
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: salt
        });
        vm.prank(deployer);
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: LAUNCH_FEE}(params, aaplIn, 1);
        assertGt(bought, 0);
        assertEq(ScoopToken(token).launchFactory(), address(factory));
        assertEq(address(factory).balance, 0);
    }

    function test_scoopTokenBytecodeUnderLimit() public {
        address token = _launchEth(
            "Sz",
            "SZ",
            bytes32(uint256(6)),
            ScoopLaunchMetadataHelpers.realisticMetadata(),
            registry.walletCreatorId(walletCreator)
        );
        uint256 size = token.code.length;
        console2.log("ScoopToken runtime bytecode size", size);
        assertLt(size, 24576);
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    function _launchEth(
        string memory name,
        string memory symbol,
        bytes32 salt,
        ScoopFactory.LaunchMetadata memory md,
        bytes32 creatorId
    ) internal returns (address token) {
        vm.prank(deployer);
        (token,,,,) = factory.launch{value: LAUNCH_FEE}(
            ScoopFactory.LaunchParams({
                name: name, symbol: symbol, creatorId: creatorId, quoteAsset: address(0), metadata: md, salt: salt
            })
        );
    }

    function _decodeCreated(Vm.Log[] memory logs)
        internal
        pure
        returns (address token, string memory description, string memory website, string memory imageUri)
    {
        bytes32 topic = keccak256("ScoopTokenCreated(address,string,string,string)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                token = address(uint160(uint256(logs[i].topics[1])));
                (description, website, imageUri) = abi.decode(logs[i].data, (string, string, string));
                return (token, description, website, imageUri);
            }
        }
        revert("ScoopTokenCreated missing");
    }

    function _findSalt(string memory name, string memory symbol, bool tokenGtAapl) internal view returns (bytes32) {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        ScoopToken.Socials memory socials = ScoopToken.Socials({
            twitter: md.twitter,
            telegram: md.telegram,
            discord: md.discord,
            website: md.website,
            farcaster: md.farcaster
        });
        for (uint256 i = 1; i < 500; ++i) {
            bytes32 salt = keccak256(abi.encode(name, symbol, i));
            bytes32 launchSalt = keccak256(abi.encode(deployer, salt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, factory.TOKEN_DOMAIN()));
            address predicted = tokenDeployer.predictTokenAddress(
                name,
                symbol,
                address(factory),
                deployer,
                address(factory),
                md.imageUri,
                md.description,
                socials,
                tokenSalt
            );
            if (tokenGtAapl == (uint160(predicted) > uint160(AAPL_TOKEN))) return salt;
        }
        revert("salt not found");
    }

    function _reconstructFdv(ScoopFactory.Launch memory rec) internal view returns (uint256 tokenUsd, uint256 fdv) {
        uint256 ethUsd = priceOracle.getPriceUsd(address(0));
        // ETH quote launches: token sorts as currency1 → quote/token = 2^192 / sqrt^2
        uint256 quoteRawPerWhole = FullMath.mulDiv(
            FullMath.mulDiv(uint256(1e18), FixedPoint96.Q96, rec.openingSqrtPriceX96),
            FixedPoint96.Q96,
            rec.openingSqrtPriceX96
        );
        tokenUsd = FullMath.mulDiv(quoteRawPerWhole, ethUsd, 1e18);
        fdv = tokenUsd * 1_000_000_000;
    }
}
