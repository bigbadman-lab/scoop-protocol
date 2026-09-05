// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";

import {ScoopCreatorRegistry} from "../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../src/ScoopCreatorRewards.sol";
import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../src/ScoopLaunchDeployer.sol";
import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../src/ScoopFactoryDeployer.sol";
import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../src/ScoopPriceOracle.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";

/**
 * @notice Robinhood fork: ScoopFactory launch presentation metadata / terminal discovery (4H).
 */
contract ScoopFactoryMetadataForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER_ADDR = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER_ADDR = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_USD_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;

    uint48 constant TEST_MAX_AGE = 7 days;

    ScoopCreatorRegistry registry;
    ScoopCreatorRewards rewards;
    ScoopTokenDeployer tokenDeployer;
    ScoopLaunchDeployer launchDeployer;
    ScoopQuoteRegistry quoteRegistry;
    ScoopPriceOracle priceOracle;
    ScoopFactory factory;

    address authority;
    address quoteAuthority;
    address oracleAuthority;
    address buybackVault;
    address operations;
    address deployer;
    address walletCreator;
    bytes32 walletCreatorId;

    event ScoopTokenCreated(address indexed token, string description, string externalUrl, string imageUri);
    event TokenLaunched(
        address indexed token,
        address indexed deployer,
        bytes32 indexed creatorId,
        address quoteAsset,
        address feeDistributor,
        address liquidityLocker,
        PoolId poolId,
        uint256 lpTokenId,
        uint160 openingSqrtPriceX96,
        int24 openingTick,
        int24 tickLower,
        int24 tickUpper,
        string name,
        string symbol
    );

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        authority = makeAddr("verificationAuthority");
        quoteAuthority = makeAddr("quoteAuthority");
        oracleAuthority = makeAddr("oracleAuthority");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        deployer = makeAddr("launchDeployer");
        walletCreator = makeAddr("walletCreator");

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
            operations
        );
        factory = protocol.factory();
        rewards = protocol.creatorRewards();
        walletCreatorId = registry.walletCreatorId(walletCreator);

        vm.deal(deployer, 50 ether);
    }

    function test_launchEmitsScoopTokenCreated() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        vm.recordLogs();
        (address token,,,,) = _launchEth("Meta", "META", bytes32(uint256(1)), md);
        (address decoded, string memory d, string memory u, string memory img) =
            _decodeScoopTokenCreated(vm.getRecordedLogs());
        assertEq(decoded, token);
        assertEq(d, md.description);
        assertEq(u, md.externalUrl);
        assertEq(img, md.imageUri);
    }

    function test_metadataEventTokenMatchesActualToken() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        vm.recordLogs();
        (address token,,,,) = _launchEth("Tok2", "TK2", bytes32(uint256(3)), md);
        (address decoded, string memory d, string memory u, string memory i) =
            _decodeScoopTokenCreated(vm.getRecordedLogs());
        assertEq(decoded, token);
        assertEq(d, md.description);
        assertEq(u, md.externalUrl);
        assertEq(i, md.imageUri);
        assertEq(token, address(ScoopToken(token)));
    }

    function test_eventCanBeDecodedByIndexer() public {
        ScoopFactory.LaunchMetadata memory md = ScoopFactory.LaunchMetadata({
            description: "Indexer decode probe",
            externalUrl: "https://example.com/x",
            imageUri: "ipfs://bafy-indexer-decode-probe"
        });
        vm.recordLogs();
        (address token,,,,) = _launchEth("Idx", "IDX", bytes32(uint256(4)), md);
        (address decoded, string memory d, string memory u, string memory img) =
            _decodeScoopTokenCreated(vm.getRecordedLogs());
        assertEq(decoded, token);
        assertEq(d, "Indexer decode probe");
        assertEq(u, "https://example.com/x");
        assertEq(img, "ipfs://bafy-indexer-decode-probe");
    }

    function test_metadataEventTokenMatchesTokenLaunched() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        vm.recordLogs();
        (address token,,,,) = _launchEth("Join", "JOIN", bytes32(uint256(5)), md);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (address metaToken,,,) = _decodeScoopTokenCreated(logs);
        address launchedToken = _decodeTokenLaunchedToken(logs);
        assertEq(metaToken, token);
        assertEq(launchedToken, token);
    }

    function test_metadataTokenMatchesPoolCurrency() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        (address token,,, uint256 lpId,) = _launchEth("Pool", "POOL", bytes32(uint256(6)), md);
        (PoolKey memory key,) = IPositionManager(POSITION_MANAGER_ADDR).getPoolAndPositionInfo(lpId);
        assertTrue(Currency.unwrap(key.currency0) == token || Currency.unwrap(key.currency1) == token);
        // ETH quote → token is currency1
        assertEq(Currency.unwrap(key.currency1), token);
    }

    function test_twoLaunchesCannotCrossAssociateImages() public {
        ScoopFactory.LaunchMetadata memory alpha = ScoopFactory.LaunchMetadata({
            description: "Alpha token", externalUrl: "https://alpha.example", imageUri: "ipfs://bafy-alpha"
        });
        ScoopFactory.LaunchMetadata memory beta = ScoopFactory.LaunchMetadata({
            description: "Beta token", externalUrl: "https://beta.example", imageUri: "ipfs://bafy-beta"
        });

        vm.recordLogs();
        (address tokenA,,,,) = _launchEth("Alpha", "ALPHA", bytes32(uint256(10)), alpha);
        (address aTok, string memory aDesc, string memory aUrl, string memory aImg) =
            _decodeScoopTokenCreated(vm.getRecordedLogs());

        vm.recordLogs();
        (address tokenB,,,,) = _launchEth("Beta", "BETA", bytes32(uint256(11)), beta);
        (address bTok, string memory bDesc, string memory bUrl, string memory bImg) =
            _decodeScoopTokenCreated(vm.getRecordedLogs());

        assertEq(aTok, tokenA);
        assertEq(bTok, tokenB);
        assertEq(aDesc, "Alpha token");
        assertEq(bDesc, "Beta token");
        assertEq(aUrl, "https://alpha.example");
        assertEq(bUrl, "https://beta.example");
        assertEq(aImg, "ipfs://bafy-alpha");
        assertEq(bImg, "ipfs://bafy-beta");
        assertTrue(keccak256(bytes(aImg)) != keccak256(bytes(bImg)));
    }

    function test_metadataDoesNotChangeCreate2Identity() public {
        ScoopFactory.LaunchMetadata memory md1 = ScoopFactory.LaunchMetadata({
            description: "First description", externalUrl: "https://one.example", imageUri: "ipfs://bafy-one"
        });
        ScoopFactory.LaunchMetadata memory md2 = ScoopFactory.LaunchMetadata({
            description: "Totally different description text",
            externalUrl: "https://two.example/path",
            imageUri: "ipfs://bafy-two-different-cid"
        });

        bytes32 salt = bytes32(uint256(20));
        address predicted1 = _predictToken("Same", "SAME", salt);
        address predicted2 = _predictToken("Same", "SAME", salt);
        assertEq(predicted1, predicted2);

        (address token,,,,) = _launchEth("Same", "SAME", salt, md1);
        assertEq(token, predicted1);

        // Different metadata, same salt → CREATE2 collision / revert
        ScoopFactory.LaunchParams memory params = _ethParams("Same", "SAME", salt, md2);
        vm.prank(deployer);
        vm.expectRevert();
        factory.launch(params);
    }

    function test_sameSaltDifferentMetadataStillCollides() public {
        ScoopFactory.LaunchMetadata memory a = ScoopLaunchMetadataHelpers.defaultMetadata();
        ScoopFactory.LaunchMetadata memory b =
            ScoopFactory.LaunchMetadata({description: "Other", externalUrl: "", imageUri: "ipfs://bafy-other"});
        bytes32 salt = bytes32(uint256(21));
        _launchEth("Col", "COL", salt, a);
        vm.prank(deployer);
        vm.expectRevert();
        factory.launch(_ethParams("Col", "COL", salt, b));
    }

    function test_validIpfsImageUri() public {
        ScoopFactory.LaunchMetadata memory md = ScoopFactory.LaunchMetadata({
            description: "ok",
            externalUrl: "",
            imageUri: "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
        });
        (address token,,,,) = _launchEth("Ok", "OK", bytes32(uint256(30)), md);
        assertTrue(factory.isScoopToken(token));
    }

    function test_emptyImageUriReverts() public {
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: "x", externalUrl: "", imageUri: ""});
        vm.prank(deployer);
        vm.expectRevert(ScoopFactory.EmptyImageUri.selector);
        factory.launch(_ethParams("EImg", "EI", bytes32(uint256(31)), md));
    }

    function test_nonIpfsImageUriReverts() public {
        string[4] memory bad = ["https://example.com/image.png", "http://example.com/x.png", "ar://txid", "IPFS://bafy"];
        for (uint256 i; i < bad.length; ++i) {
            ScoopFactory.LaunchMetadata memory md =
                ScoopFactory.LaunchMetadata({description: "x", externalUrl: "", imageUri: bad[i]});
            vm.prank(deployer);
            vm.expectRevert(ScoopFactory.InvalidImageUriPrefix.selector);
            factory.launch(_ethParams("Bad", "BAD", bytes32(uint256(40 + i)), md));
        }
    }

    function test_malformedIpfsPrefixReverts() public {
        string[2] memory bad = ["ipfs:/bafy", "ipfs:/"];
        for (uint256 i; i < bad.length; ++i) {
            ScoopFactory.LaunchMetadata memory md =
                ScoopFactory.LaunchMetadata({description: "x", externalUrl: "", imageUri: bad[i]});
            vm.prank(deployer);
            vm.expectRevert(ScoopFactory.InvalidImageUriPrefix.selector);
            factory.launch(_ethParams("Mal", "MAL", bytes32(uint256(50 + i)), md));
        }
    }

    function test_oversizedImageUriReverts() public {
        string memory oversized = string(abi.encodePacked("ipfs://", _repeat("a", 122))); // 7+122=129 > 128
        assertEq(bytes(oversized).length, 129);
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: "x", externalUrl: "", imageUri: oversized});
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.ImageUriTooLong.selector, uint256(129)));
        factory.launch(_ethParams("BigI", "BI", bytes32(uint256(60)), md));
    }

    function test_emptyDescriptionReverts() public {
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: "", externalUrl: "", imageUri: "ipfs://bafy"});
        vm.prank(deployer);
        vm.expectRevert(ScoopFactory.EmptyDescription.selector);
        factory.launch(_ethParams("EDesc", "ED", bytes32(uint256(61)), md));
    }

    function test_descriptionAtMaxLength() public {
        string memory desc = _repeat("d", 280);
        assertEq(bytes(desc).length, 280);
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: desc, externalUrl: "", imageUri: "ipfs://bafy-max-desc"});
        (address token,,,,) = _launchEth("MaxD", "MD", bytes32(uint256(62)), md);
        assertTrue(factory.isScoopToken(token));
    }

    function test_oversizedDescriptionReverts() public {
        string memory desc = _repeat("d", 281);
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: desc, externalUrl: "", imageUri: "ipfs://bafy"});
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.DescriptionTooLong.selector, uint256(281)));
        factory.launch(_ethParams("BigD", "BD", bytes32(uint256(63)), md));
    }

    function test_emptyExternalUrlAllowed() public {
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: "no url", externalUrl: "", imageUri: "ipfs://bafy-empty-url"});
        (address token,,,,) = _launchEth("NoUrl", "NU", bytes32(uint256(64)), md);
        assertTrue(factory.isScoopToken(token));
    }

    function test_externalUrlAtMaxLength() public {
        string memory url = _repeat("u", 256);
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: "url", externalUrl: url, imageUri: "ipfs://bafy-url"});
        (address token,,,,) = _launchEth("MaxU", "MU", bytes32(uint256(65)), md);
        assertTrue(factory.isScoopToken(token));
    }

    function test_oversizedExternalUrlReverts() public {
        string memory url = _repeat("u", 257);
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: "url", externalUrl: url, imageUri: "ipfs://bafy"});
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(ScoopFactory.ExternalUrlTooLong.selector, uint256(257)));
        factory.launch(_ethParams("BigU", "BU", bytes32(uint256(66)), md));
    }

    function test_metadataUnicodeHandledAsBytes() public {
        // 4-byte UTF-8 rocket emoji × 70 = 280 bytes exactly
        bytes memory rocket = hex"f09f9a80";
        bytes memory built;
        for (uint256 i; i < 70; ++i) {
            built = abi.encodePacked(built, rocket);
        }
        assertEq(built.length, 280);
        ScoopFactory.LaunchMetadata memory md =
            ScoopFactory.LaunchMetadata({description: string(built), externalUrl: "", imageUri: "ipfs://bafy-unicode"});
        (address token,,,,) = _launchEth("Uni", "UNI", bytes32(uint256(67)), md);
        assertTrue(factory.isScoopToken(token));
    }

    function test_metadataHtmlLikeContentDoesNotAffectLaunch() public {
        ScoopFactory.LaunchMetadata memory md = ScoopFactory.LaunchMetadata({
            description: '<script>alert("x")</script> {"evil":true}',
            externalUrl: "javascript:alert(1)",
            imageUri: "ipfs://bafy-html-like"
        });
        (address token,,,,) = _launchEth("Html", "HTM", bytes32(uint256(68)), md);
        assertEq(factory.getLaunch(token).creatorId, registry.walletCreatorId(walletCreator));
        assertEq(IERC20(token).balanceOf(walletCreator), 0);
        assertEq(IERC20(token).totalSupply(), 1_000_000_000 ether);
    }

    function test_nativeLaunchAndBuyPreservesMetadata() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.realisticMetadata();
        ScoopFactory.LaunchParams memory params = _ethParams("BuyM", "BM", bytes32(uint256(70)), md);
        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,, uint256 bought) = factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, 1);
        console2.log("ETH launchAndBuy gas (w/ metadata)", gasBefore - gasleft());
        assertGt(bought, 0);
        (address decoded,,, string memory img) = _decodeScoopTokenCreated(vm.getRecordedLogs());
        assertEq(decoded, token);
        assertEq(img, md.imageUri);
    }

    function test_erc20LaunchAndBuyPreservesMetadata() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.realisticMetadata();
        bytes32 salt = _findAaplSalt("ABuy", "AB", true);
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "ABuy", symbol: "AB", creatorId: walletCreatorId, quoteAsset: AAPL_TOKEN, metadata: md, salt: salt
        });
        uint256 aaplIn = 0.1e18;
        deal(AAPL_TOKEN, deployer, aaplIn);
        vm.prank(deployer);
        IERC20(AAPL_TOKEN).approve(address(factory), aaplIn);

        uint256 gasBefore = gasleft();
        vm.prank(deployer);
        vm.recordLogs();
        (address token,,,,, uint256 bought) = factory.launchAndBuy(params, aaplIn, 1);
        console2.log("AAPL c0 launchAndBuy gas (w/ metadata)", gasBefore - gasleft());
        assertGt(bought, 0);
        (address decoded, string memory d,, string memory img) = _decodeScoopTokenCreated(vm.getRecordedLogs());
        assertEq(decoded, token);
        assertEq(d, md.description);
        assertEq(img, md.imageUri);
    }

    function test_plainEthLaunchGasWithMetadata() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.realisticMetadata();
        uint256 gasBefore = gasleft();
        _launchEth("Gas", "GAS", bytes32(uint256(71)), md);
        console2.log("plain ETH launch() gas (w/ metadata)", gasBefore - gasleft());
    }

    function test_failedLaunchEmitsNoPersistentMetadata_duplicateSalt() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        bytes32 salt = bytes32(uint256(80));
        _launchEth("DupM", "DM", salt, md);

        vm.recordLogs();
        vm.prank(deployer);
        vm.expectRevert();
        factory.launch(_ethParams("DupM", "DM", salt, md));
        assertFalse(_hasScoopTokenCreated(vm.getRecordedLogs()));
    }

    function test_failedInitialBuyEmitsNoPersistentMetadata() public {
        ScoopFactory.LaunchMetadata memory md = ScoopLaunchMetadataHelpers.defaultMetadata();
        ScoopFactory.LaunchParams memory params = _ethParams("SlipM", "SM", bytes32(uint256(81)), md);
        uint256 ethBefore = deployer.balance;
        vm.prank(deployer);
        vm.recordLogs();
        vm.expectRevert();
        factory.launchAndBuy{value: 0.01 ether}(params, 0.01 ether, type(uint128).max);
        // On revert, recorded logs from the call are empty / no successful events
        assertEq(deployer.balance, ethBefore);
        assertFalse(factory.isScoopToken(_predictToken("SlipM", "SM", bytes32(uint256(81)))));
    }

    function test_metadataDoesNotAffectCreatorAttribution() public {
        ScoopFactory.LaunchMetadata memory md = ScoopFactory.LaunchMetadata({
            description: "creator should ignore this",
            externalUrl: "https://not-a-creator-id.example",
            imageUri: "ipfs://bafy-not-creator"
        });
        (address token, address feeDist,,,) = _launchEth("AttrM", "AM", bytes32(uint256(82)), md);
        assertEq(factory.getLaunch(token).creatorId, walletCreatorId);
        assertEq(rewards.sourceCreatorId(feeDist), walletCreatorId);
    }

    function test_noMetadataStorageOrMutators() public {
        (address token,,,,) =
            _launchEth("Store", "ST", bytes32(uint256(83)), ScoopLaunchMetadataHelpers.defaultMetadata());
        (bool setImg,) = address(factory).call(abi.encodeWithSignature("setImage(address,string)", token, "x"));
        (bool upd,) = address(factory)
            .call(abi.encodeWithSignature("updateMetadata(address,string,string,string)", token, "a", "b", "c"));
        (bool ownerOk,) = address(factory).call(abi.encodeWithSignature("owner()"));
        assertFalse(setImg);
        assertFalse(upd);
        assertFalse(ownerOk);
    }

    function test_scoopTokenHasNoMetadataSurface() public {
        (address token,,,,) =
            _launchEth("TokAbi", "TA", bytes32(uint256(84)), ScoopLaunchMetadataHelpers.defaultMetadata());
        (bool tokenUri,) = token.call(abi.encodeWithSignature("tokenURI()"));
        (bool metaUri,) = token.call(abi.encodeWithSignature("metadataURI()"));
        (bool image,) = token.call(abi.encodeWithSignature("image()"));
        (bool setImage,) = token.call(abi.encodeWithSignature("setImage(string)", "x"));
        (bool setDesc,) = token.call(abi.encodeWithSignature("setDescription(string)", "x"));
        assertFalse(tokenUri);
        assertFalse(metaUri);
        assertFalse(image);
        assertFalse(setImage);
        assertFalse(setDesc);
        assertEq(ScoopToken(token).totalSupply(), 1_000_000_000 ether);
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    function _ethParams(string memory name, string memory symbol, bytes32 salt, ScoopFactory.LaunchMetadata memory md)
        internal
        view
        returns (ScoopFactory.LaunchParams memory)
    {
        return ScoopFactory.LaunchParams({
            name: name, symbol: symbol, creatorId: walletCreatorId, quoteAsset: address(0), metadata: md, salt: salt
        });
    }

    function _launchEth(string memory name, string memory symbol, bytes32 salt, ScoopFactory.LaunchMetadata memory md)
        internal
        returns (address token, address feeDist, address locker, uint256 lpId, PoolId poolId)
    {
        vm.prank(deployer);
        return factory.launch(_ethParams(name, symbol, salt, md));
    }

    function _predictToken(string memory name, string memory symbol, bytes32 salt) internal view returns (address) {
        bytes32 launchSalt = keccak256(abi.encode(deployer, salt));
        bytes32 tokenSalt = keccak256(abi.encode(launchSalt, factory.TOKEN_DOMAIN()));
        return tokenDeployer.predictTokenAddress(name, symbol, address(factory), tokenSalt);
    }

    function _findAaplSalt(string memory name, string memory symbol, bool tokenGreaterThanAapl)
        internal
        view
        returns (bytes32)
    {
        bytes32 domain = factory.TOKEN_DOMAIN();
        for (uint256 i = 1; i < 20_000; ++i) {
            bytes32 userSalt = bytes32(i);
            bytes32 launchSalt = keccak256(abi.encode(deployer, userSalt));
            bytes32 tokenSalt = keccak256(abi.encode(launchSalt, domain));
            address predicted = tokenDeployer.predictTokenAddress(name, symbol, address(factory), tokenSalt);
            if (tokenGreaterThanAapl && predicted > AAPL_TOKEN) return userSalt;
            if (!tokenGreaterThanAapl && predicted < AAPL_TOKEN && predicted != address(0)) return userSalt;
        }
        revert("salt not found");
    }

    function _decodeScoopTokenCreated(Vm.Log[] memory logs)
        internal
        pure
        returns (address token, string memory description, string memory externalUrl, string memory imageUri)
    {
        bytes32 topic0 = keccak256("ScoopTokenCreated(address,string,string,string)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic0) {
                token = address(uint160(uint256(logs[i].topics[1])));
                (description, externalUrl, imageUri) = abi.decode(logs[i].data, (string, string, string));
                return (token, description, externalUrl, imageUri);
            }
        }
        revert("ScoopTokenCreated not found");
    }

    function _decodeTokenLaunchedToken(Vm.Log[] memory logs) internal pure returns (address token) {
        bytes32 topic0 = keccak256(
            "TokenLaunched(address,address,bytes32,address,address,address,bytes32,uint256,uint160,int24,int24,int24,string,string)"
        );
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 4 && logs[i].topics[0] == topic0) {
                return address(uint160(uint256(logs[i].topics[1])));
            }
        }
        revert("TokenLaunched not found");
    }

    function _hasScoopTokenCreated(Vm.Log[] memory logs) internal pure returns (bool) {
        bytes32 topic0 = keccak256("ScoopTokenCreated(address,string,string,string)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length >= 2 && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }

    function _repeat(string memory unit, uint256 n) internal pure returns (string memory out) {
        bytes memory u = bytes(unit);
        bytes memory buf = new bytes(u.length * n);
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < u.length; ++j) {
                buf[i * u.length + j] = u[j];
            }
        }
        out = string(buf);
    }
}
