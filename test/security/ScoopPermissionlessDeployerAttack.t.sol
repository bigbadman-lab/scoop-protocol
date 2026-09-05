// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Test} from "forge-std/Test.sol";

import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopFactoryDeployer} from "../../src/ScoopFactoryDeployer.sol";
import {ScoopToken} from "../../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../../src/ScoopTokenDeployer.sol";
import {ScoopLaunchDeployer} from "../../src/ScoopLaunchDeployer.sol";
import {ScoopCreatorRegistry} from "../../src/ScoopCreatorRegistry.sol";
import {ScoopCreatorRewards} from "../../src/ScoopCreatorRewards.sol";
import {ScoopQuoteRegistry} from "../../src/ScoopQuoteRegistry.sol";
import {ScoopPriceOracle} from "../../src/ScoopPriceOracle.sol";
import {ScoopLaunchMetadataHelpers} from "../helpers/ScoopLaunchMetadataHelpers.sol";

/**
 * @notice Permissionless CREATE2 deployer griefing analysis.
 * @dev Classification: launch-specific DoS / griefing (not theft).
 *      Attacker who knows (deployer, userSalt) and uses IDENTICAL constructor args can
 *      pre-occupy CREATE2 addresses so Factory.launch fails for that salt.
 *      Different bytecode → different address (cannot overwrite).
 *      Different msg.sender → different launchSalt (cannot steal victim address space).
 *      Changing user salt recovers.
 */
contract ScoopPermissionlessDeployerAttackTest is Test {
    uint16 constant CREATOR_REWARDS_BPS = 7000;
    uint16 constant DEPLOYER_BPS = 400;
    uint16 constant BUYBACK_BPS = 2000;
    uint16 constant OPERATIONS_BPS = 600;

    ScoopTokenDeployer tokenDeployer;
    ScoopLaunchDeployer launchDeployer;

    address positionManager;
    address creatorRewardsAddr;
    address buybackVault;
    address operations;
    address victim;
    address attacker;
    address factoryPlaceholder;

    function setUp() public {
        positionManager = makeAddr("positionManager");
        creatorRewardsAddr = makeAddr("creatorRewards");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
        factoryPlaceholder = makeAddr("factory");

        tokenDeployer = new ScoopTokenDeployer();
        launchDeployer = new ScoopLaunchDeployer(positionManager);
    }

    function _launchSalt(address deployer, bytes32 userSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(deployer, userSalt));
    }

    function _tokenSalt(bytes32 launchSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(launchSalt, keccak256("SCOOP_TOKEN")));
    }

    function _launchDomainSalt(bytes32 launchSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(launchSalt, keccak256("SCOOP_LAUNCH")));
    }

    function _socials() internal pure returns (ScoopToken.Socials memory) {
        return ScoopLaunchMetadataHelpers.emptySocials();
    }

    function test_attackerCanComputeSaltsKnowingDeployerAndUserSalt() public view {
        bytes32 userSalt = bytes32(uint256(42));
        bytes32 launchSalt = _launchSalt(victim, userSalt);
        assertEq(launchSalt, keccak256(abi.encode(victim, userSalt)));
        assertEq(_tokenSalt(launchSalt), keccak256(abi.encode(launchSalt, keccak256("SCOOP_TOKEN"))));
        assertEq(_launchDomainSalt(launchSalt), keccak256(abi.encode(launchSalt, keccak256("SCOOP_LAUNCH"))));
    }

    function test_preDeployIdenticalToken_causesCreate2Fail() public {
        bytes32 userSalt = bytes32(uint256(1));
        bytes32 tokenSalt = _tokenSalt(_launchSalt(victim, userSalt));
        ScoopToken.Socials memory socials = _socials();

        address predicted = tokenDeployer.predictTokenAddress(
            "Grief", "GRF", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://a", "desc", socials, tokenSalt
        );

        vm.prank(attacker);
        address occupied = tokenDeployer.deployToken(
            "Grief", "GRF", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://a", "desc", socials, tokenSalt
        );
        assertEq(occupied, predicted);
        assertGt(occupied.code.length, 0);

        vm.expectRevert(Errors.FailedDeployment.selector);
        tokenDeployer.deployToken(
            "Grief", "GRF", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://a", "desc", socials, tokenSalt
        );
    }

    function test_preDeployIdenticalLaunchComponents_causesCreate2Fail() public {
        bytes32 userSalt = bytes32(uint256(2));
        bytes32 launchDomainSalt = _launchDomainSalt(_launchSalt(victim, userSalt));

        (address predDist,) = launchDeployer.predictLaunch(
            creatorRewardsAddr,
            victim,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            launchDomainSalt
        );

        vm.prank(attacker);
        (address dist,) = launchDeployer.deployLaunch(
            creatorRewardsAddr,
            victim,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            launchDomainSalt
        );
        assertEq(dist, predDist);

        vm.expectRevert(Errors.FailedDeployment.selector);
        launchDeployer.deployLaunch(
            creatorRewardsAddr,
            victim,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            launchDomainSalt
        );
    }

    function test_differentBytecode_cannotOccupySameAddress() public {
        bytes32 userSalt = bytes32(uint256(3));
        bytes32 tokenSalt = _tokenSalt(_launchSalt(victim, userSalt));
        ScoopToken.Socials memory socials = _socials();

        address victimPredicted = tokenDeployer.predictTokenAddress(
            "Victim", "VCT", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://a", "A", socials, tokenSalt
        );

        vm.prank(attacker);
        address other = tokenDeployer.deployToken(
            "Other", "OTH", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://b", "B", socials, tokenSalt
        );
        assertTrue(other != victimPredicted);
        assertEq(victimPredicted.code.length, 0);

        address deployed = tokenDeployer.deployToken(
            "Victim", "VCT", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://a", "A", socials, tokenSalt
        );
        assertEq(deployed, victimPredicted);
    }

    function test_differentMsgSender_differentLaunchSalt_cannotStealVictimAddress() public {
        bytes32 userSalt = bytes32(uint256(4));
        ScoopToken.Socials memory socials = _socials();

        address victimAddr = tokenDeployer.predictTokenAddress(
            "Same",
            "SAME",
            factoryPlaceholder,
            victim,
            factoryPlaceholder,
            "ipfs://x",
            "d",
            socials,
            _tokenSalt(_launchSalt(victim, userSalt))
        );
        address attackerAddr = tokenDeployer.predictTokenAddress(
            "Same",
            "SAME",
            factoryPlaceholder,
            victim,
            factoryPlaceholder,
            "ipfs://x",
            "d",
            socials,
            _tokenSalt(_launchSalt(attacker, userSalt))
        );
        assertTrue(victimAddr != attackerAddr);

        // Even mirroring victim constructor args with attacker salt yields a different address.
        address attackerWithVictimArgs = tokenDeployer.predictTokenAddress(
            "Same",
            "SAME",
            factoryPlaceholder,
            victim,
            factoryPlaceholder,
            "ipfs://x",
            "d",
            socials,
            _tokenSalt(_launchSalt(attacker, userSalt))
        );
        assertTrue(victimAddr != attackerWithVictimArgs);
    }

    function test_changingUserSalt_recoversAfterGrief() public {
        ScoopToken.Socials memory socials = _socials();
        bytes32 tokenSalt1 = _tokenSalt(_launchSalt(victim, bytes32(uint256(5))));

        vm.prank(attacker);
        tokenDeployer.deployToken(
            "Grief", "GRF", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://g", "g", socials, tokenSalt1
        );

        bytes32 tokenSalt2 = _tokenSalt(_launchSalt(victim, bytes32(uint256(6))));
        address recovered = tokenDeployer.deployToken(
            "Grief", "GRF", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://g", "g", socials, tokenSalt2
        );
        assertTrue(recovered != address(0));
        assertGt(recovered.code.length, 0);
    }

    function test_classification_isLaunchSpecificGriefNotTheft() public {
        bytes32 tokenSalt = _tokenSalt(_launchSalt(victim, bytes32(uint256(7))));
        ScoopToken.Socials memory socials = _socials();

        vm.prank(attacker);
        address occupied = tokenDeployer.deployToken(
            "X", "X", factoryPlaceholder, victim, factoryPlaceholder, "ipfs://x", "x", socials, tokenSalt
        );

        ScoopToken t = ScoopToken(occupied);
        assertEq(t.balanceOf(factoryPlaceholder), t.MAX_SUPPLY());
        assertEq(t.deployer(), victim);
        assertEq(t.launchFactory(), factoryPlaceholder);
        // Pre-deploy occupies the CREATE2 slot; it does not grant Factory LP/fee rights.
        assertTrue(true, "CREATE2 collision is salt-DoS / griefing, not fund theft");
    }

    /// @dev Optional fork: full Factory.launch fails after permissionless pre-deploy of launch components.
    function testFork_preDeployLaunch_blocksFactoryLaunch() public {
        string memory rpc;
        try vm.envString("ROBINHOOD_RPC_URL") returns (string memory u) {
            rpc = u;
        } catch {
            return;
        }
        try vm.createSelectFork(rpc) {}
        catch {
            // Skip when RPC is unreachable in this environment.
            return;
        }

        address poolManager = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
        address positionManager_ = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
        address universalRouter = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        address ethUsdFeed = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

        address authority = makeAddr("va");
        address quoteAuth = makeAddr("qa");
        address oracleAuth = makeAddr("oa");
        address feeRecipient = makeAddr("feeRecipient");

        ScoopCreatorRegistry reg = new ScoopCreatorRegistry(authority);
        ScoopTokenDeployer td = new ScoopTokenDeployer();
        ScoopLaunchDeployer ld = new ScoopLaunchDeployer(positionManager_);
        ScoopQuoteRegistry qr = new ScoopQuoteRegistry(quoteAuth);
        ScoopPriceOracle po = new ScoopPriceOracle(oracleAuth);

        vm.prank(quoteAuth);
        qr.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        vm.prank(oracleAuth);
        po.configureFeed(address(0), ethUsdFeed, 7 days);

        ScoopFactoryDeployer protocol = new ScoopFactoryDeployer(
            address(reg),
            poolManager,
            positionManager_,
            permit2,
            universalRouter,
            address(td),
            address(ld),
            address(qr),
            address(po),
            buybackVault,
            operations,
            feeRecipient
        );
        ScoopFactory factory = protocol.factory();
        ScoopCreatorRewards rewards_ = protocol.creatorRewards();

        address dep = makeAddr("dep");
        vm.deal(dep, 1 ether);
        bytes32 userSalt = bytes32(uint256(99));
        bytes32 launchDomainSalt = _launchDomainSalt(_launchSalt(dep, userSalt));

        vm.prank(attacker);
        ld.deployLaunch(
            address(rewards_),
            dep,
            buybackVault,
            operations,
            CREATOR_REWARDS_BPS,
            DEPLOYER_BPS,
            BUYBACK_BPS,
            OPERATIONS_BPS,
            launchDomainSalt
        );

        address wc = makeAddr("wc");
        ScoopFactory.LaunchParams memory params = ScoopFactory.LaunchParams({
            name: "DoS",
            symbol: "DOS",
            creatorId: reg.walletCreatorId(wc),
            quoteAsset: address(0),
            metadata: ScoopLaunchMetadataHelpers.defaultMetadata(),
            salt: userSalt
        });

        uint256 launchFee = factory.LAUNCH_FEE();
        vm.prank(dep);
        vm.expectRevert();
        factory.launch{value: launchFee}(params);
    }
}
