// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";

contract ScoopTokenDeployerTest is Test {
    ScoopTokenDeployer deployer;
    address recipient;
    address tokenDeployerAddr;
    address launchFactoryAddr;
    address caller;

    string constant LOGO = "ipfs://bafy-deployer";
    string constant DESCRIPTION = "deployer test";

    event TokenDeployed(
        address indexed token,
        address indexed caller,
        address indexed recipient,
        bytes32 salt,
        string name,
        string symbol
    );

    function setUp() public {
        deployer = new ScoopTokenDeployer();
        recipient = makeAddr("recipient");
        tokenDeployerAddr = makeAddr("deployerAttr");
        launchFactoryAddr = makeAddr("launchFactory");
        caller = makeAddr("caller");
    }

    function test_deployTokenSucceeds() public {
        address token = _deploy("Alpha", "ALP", recipient, bytes32(uint256(1)), LOGO, DESCRIPTION, _emptySocials());
        assertTrue(token != address(0));
        assertGt(token.code.length, 0);
    }

    function test_deployedContractIsScoopTokenWithCorrectMetadataAndSupply() public {
        ScoopToken.Socials memory socials = ScoopToken.Socials({
            twitter: "https://x.com/beta", telegram: "", discord: "", website: "https://beta.example", farcaster: ""
        });
        address tokenAddr = _deploy("Beta", "BET", recipient, bytes32(uint256(2)), "ipfs://beta", "Beta token", socials);
        ScoopToken token = ScoopToken(tokenAddr);

        assertEq(token.name(), "Beta");
        assertEq(token.symbol(), "BET");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.MAX_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.balanceOf(recipient), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(deployer)), 0);
        assertEq(token.deployer(), tokenDeployerAddr);
        assertEq(token.launchFactory(), launchFactoryAddr);
        assertEq(token.logo(), "ipfs://beta");
        assertEq(token.description(), "Beta token");
        (,,, string memory website,) = token.socials();
        assertEq(website, "https://beta.example");
    }

    function test_predictTokenAddressMatchesDeployed() public {
        string memory name = "Gamma";
        string memory symbol = "GAM";
        bytes32 salt = bytes32(uint256(3));
        ScoopToken.Socials memory socials = _emptySocials();

        address predicted = _predict(name, symbol, recipient, salt, LOGO, DESCRIPTION, socials);
        address deployed = _deploy(name, symbol, recipient, salt, LOGO, DESCRIPTION, socials);

        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
    }

    function test_predictEqualsDeployWithMetadata() public {
        ScoopToken.Socials memory socials = ScoopToken.Socials({
            twitter: "https://x.com/meta",
            telegram: "https://t.me/meta",
            discord: "https://discord.gg/meta",
            website: "https://meta.example",
            farcaster: "https://warpcast.com/meta"
        });
        bytes32 salt = bytes32(uint256(4));
        address predicted = _predict("Meta", "META", recipient, salt, "ipfs://meta-logo", "full metadata", socials);
        address deployed = _deploy("Meta", "META", recipient, salt, "ipfs://meta-logo", "full metadata", socials);
        assertEq(deployed, predicted);
        assertEq(ScoopToken(deployed).logo(), "ipfs://meta-logo");
        assertEq(ScoopToken(deployed).description(), "full metadata");
    }

    function test_differentMetadataProducesDifferentCreate2Address() public {
        bytes32 salt = bytes32(uint256(5));
        ScoopToken.Socials memory empty = _emptySocials();
        address predA = _predict("Same", "SAME", recipient, salt, "ipfs://a", "desc A", empty);
        address predB = _predict("Same", "SAME", recipient, salt, "ipfs://b", "desc B", empty);
        assertTrue(predA != predB);

        ScoopToken.Socials memory withSite = ScoopToken.Socials({
            twitter: "", telegram: "", discord: "", website: "https://different.example", farcaster: ""
        });
        address predC = _predict("Same", "SAME", recipient, salt, "ipfs://a", "desc A", withSite);
        assertTrue(predA != predC);
    }

    function test_differentSaltsProduceDifferentAddresses() public {
        ScoopToken.Socials memory socials = _emptySocials();
        address a = _deploy("Delta", "DEL", recipient, bytes32(uint256(10)), LOGO, DESCRIPTION, socials);
        address b = _deploy("Delta", "DEL", recipient, bytes32(uint256(11)), LOGO, DESCRIPTION, socials);
        assertTrue(a != b);
    }

    function test_sameSaltDifferentConstructorArgsProduceDifferentPredictions() public {
        bytes32 salt = bytes32(uint256(42));
        ScoopToken.Socials memory socials = _emptySocials();
        address predA = _predict("One", "ONE", recipient, salt, LOGO, DESCRIPTION, socials);
        address predB = _predict("Two", "TWO", recipient, salt, LOGO, DESCRIPTION, socials);
        address predC = _predict("One", "ONE", makeAddr("other"), salt, LOGO, DESCRIPTION, socials);
        address predD = _predict("One", "ONE", recipient, salt, "ipfs://other", DESCRIPTION, socials);

        assertTrue(predA != predB);
        assertTrue(predA != predC);
        assertTrue(predA != predD);
    }

    function test_duplicateCreate2DeploymentReverts() public {
        bytes32 salt = bytes32(uint256(99));
        ScoopToken.Socials memory socials = _emptySocials();
        _deploy("Dup", "DUP", recipient, salt, LOGO, DESCRIPTION, socials);

        vm.expectRevert(Errors.FailedDeployment.selector);
        _deploy("Dup", "DUP", recipient, salt, LOGO, DESCRIPTION, socials);
    }

    function test_permissionlessCallerCanDeployWithoutBecomingAdmin() public {
        ScoopToken.Socials memory socials = _emptySocials();
        vm.prank(caller);
        address tokenAddr = deployer.deployToken(
            "CallerCoin",
            "CALL",
            recipient,
            tokenDeployerAddr,
            launchFactoryAddr,
            LOGO,
            DESCRIPTION,
            socials,
            bytes32(uint256(7))
        );
        ScoopToken token = ScoopToken(tokenAddr);

        assertEq(token.balanceOf(recipient), token.MAX_SUPPLY());
        assertEq(token.balanceOf(caller), 0);

        (bool ownerOk,) = tokenAddr.call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = tokenAddr.call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        assertFalse(ownerOk);
        assertFalse(adminOk);
    }

    function test_deployerHasNoOwnerAdmin() public {
        (bool ownerOk,) = address(deployer).call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = address(deployer).call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        (bool setOk,) = address(deployer).call(abi.encodeWithSignature("setOwner(address)", caller));
        assertFalse(ownerOk);
        assertFalse(adminOk);
        assertFalse(setOk);
    }

    function test_tokenDeployedEventEmitted() public {
        string memory name = "EventToken";
        string memory symbol = "EVT";
        bytes32 salt = bytes32(uint256(55));
        ScoopToken.Socials memory socials = _emptySocials();
        address predicted = _predict(name, symbol, recipient, salt, LOGO, DESCRIPTION, socials);

        vm.expectEmit(true, true, true, true, address(deployer));
        emit TokenDeployed(predicted, address(this), recipient, salt, name, symbol);

        address deployed = _deploy(name, symbol, recipient, salt, LOGO, DESCRIPTION, socials);
        assertEq(deployed, predicted);
    }

    function test_zeroRecipientDeploymentReverts() public {
        vm.expectRevert(ScoopToken.ZeroRecipient.selector);
        _deploy("Zero", "ZRO", address(0), bytes32(uint256(8)), LOGO, DESCRIPTION, _emptySocials());
    }

    function test_zeroDeployerDeploymentReverts() public {
        ScoopToken.Socials memory socials = _emptySocials();
        vm.expectRevert(ScoopToken.ZeroDeployer.selector);
        deployer.deployToken(
            "ZeroDep", "ZD", recipient, address(0), launchFactoryAddr, LOGO, DESCRIPTION, socials, bytes32(uint256(9))
        );
    }

    function test_zeroLaunchFactoryDeploymentReverts() public {
        ScoopToken.Socials memory socials = _emptySocials();
        vm.expectRevert(ScoopToken.ZeroLaunchFactory.selector);
        deployer.deployToken(
            "ZeroFac", "ZF", recipient, tokenDeployerAddr, address(0), LOGO, DESCRIPTION, socials, bytes32(uint256(10))
        );
    }

    function testFuzz_predictMatchesDeploy(
        bytes32 salt,
        address to,
        address dep,
        address factory_,
        string memory name,
        string memory symbol,
        string memory logo,
        string memory description
    ) public {
        vm.assume(to != address(0) && dep != address(0) && factory_ != address(0));
        vm.assume(bytes(name).length > 0 && bytes(name).length <= 32);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length <= 16);
        vm.assume(bytes(logo).length <= 64);
        vm.assume(bytes(description).length <= 64);

        bytes32 uniqueSalt = keccak256(abi.encode(salt, to, dep, factory_, name, symbol, logo, description));
        ScoopToken.Socials memory socials = _emptySocials();

        address predicted =
            deployer.predictTokenAddress(name, symbol, to, dep, factory_, logo, description, socials, uniqueSalt);
        address deployed = deployer.deployToken(name, symbol, to, dep, factory_, logo, description, socials, uniqueSalt);

        assertEq(deployed, predicted);
        assertEq(ScoopToken(deployed).balanceOf(to), ScoopToken(deployed).MAX_SUPPLY());
        assertEq(ScoopToken(deployed).deployer(), dep);
        assertEq(ScoopToken(deployed).launchFactory(), factory_);
        assertEq(ScoopToken(deployed).logo(), logo);
        assertEq(ScoopToken(deployed).description(), description);
    }

    function _emptySocials() internal pure returns (ScoopToken.Socials memory) {
        return ScoopLaunchMetadataHelpers.emptySocials();
    }

    function _predict(
        string memory name,
        string memory symbol,
        address supplyRecipient,
        bytes32 salt,
        string memory logo,
        string memory description,
        ScoopToken.Socials memory socials
    ) internal view returns (address) {
        return deployer.predictTokenAddress(
            name, symbol, supplyRecipient, tokenDeployerAddr, launchFactoryAddr, logo, description, socials, salt
        );
    }

    function _deploy(
        string memory name,
        string memory symbol,
        address supplyRecipient,
        bytes32 salt,
        string memory logo,
        string memory description,
        ScoopToken.Socials memory socials
    ) internal returns (address) {
        return deployer.deployToken(
            name, symbol, supplyRecipient, tokenDeployerAddr, launchFactoryAddr, logo, description, socials, salt
        );
    }
}
