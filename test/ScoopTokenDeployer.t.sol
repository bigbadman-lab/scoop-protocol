// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopTokenDeployer} from "../src/ScoopTokenDeployer.sol";

contract ScoopTokenDeployerTest is Test {
    ScoopTokenDeployer deployer;
    address recipient;
    address caller;

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
        caller = makeAddr("caller");
    }

    function test_deployTokenSucceeds() public {
        address token = deployer.deployToken("Alpha", "ALP", recipient, bytes32(uint256(1)));
        assertTrue(token != address(0));
        assertGt(token.code.length, 0);
    }

    function test_deployedContractIsScoopTokenWithCorrectMetadataAndSupply() public {
        address tokenAddr = deployer.deployToken("Beta", "BET", recipient, bytes32(uint256(2)));
        ScoopToken token = ScoopToken(tokenAddr);

        assertEq(token.name(), "Beta");
        assertEq(token.symbol(), "BET");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.MAX_SUPPLY(), 1_000_000_000 ether);
        assertEq(token.balanceOf(recipient), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(deployer)), 0);
    }

    function test_predictTokenAddressMatchesDeployed() public {
        string memory name = "Gamma";
        string memory symbol = "GAM";
        bytes32 salt = bytes32(uint256(3));

        address predicted = deployer.predictTokenAddress(name, symbol, recipient, salt);
        address deployed = deployer.deployToken(name, symbol, recipient, salt);

        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
    }

    function test_differentSaltsProduceDifferentAddresses() public {
        address a = deployer.deployToken("Delta", "DEL", recipient, bytes32(uint256(10)));
        address b = deployer.deployToken("Delta", "DEL", recipient, bytes32(uint256(11)));
        assertTrue(a != b);
    }

    function test_sameSaltDifferentConstructorArgsProduceDifferentPredictions() public {
        bytes32 salt = bytes32(uint256(42));
        address predA = deployer.predictTokenAddress("One", "ONE", recipient, salt);
        address predB = deployer.predictTokenAddress("Two", "TWO", recipient, salt);
        address predC = deployer.predictTokenAddress("One", "ONE", makeAddr("other"), salt);

        assertTrue(predA != predB);
        assertTrue(predA != predC);
    }

    function test_duplicateCreate2DeploymentReverts() public {
        bytes32 salt = bytes32(uint256(99));
        deployer.deployToken("Dup", "DUP", recipient, salt);

        vm.expectRevert(Errors.FailedDeployment.selector);
        deployer.deployToken("Dup", "DUP", recipient, salt);
    }

    function test_permissionlessCallerCanDeployWithoutBecomingAdmin() public {
        vm.prank(caller);
        address tokenAddr = deployer.deployToken("CallerCoin", "CALL", recipient, bytes32(uint256(7)));
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
        address predicted = deployer.predictTokenAddress(name, symbol, recipient, salt);

        vm.expectEmit(true, true, true, true, address(deployer));
        emit TokenDeployed(predicted, address(this), recipient, salt, name, symbol);

        address deployed = deployer.deployToken(name, symbol, recipient, salt);
        assertEq(deployed, predicted);
    }

    function test_zeroRecipientDeploymentReverts() public {
        vm.expectRevert(ScoopToken.ZeroRecipient.selector);
        deployer.deployToken("Zero", "ZRO", address(0), bytes32(uint256(8)));
    }

    function testFuzz_predictMatchesDeploy(bytes32 salt, address to, string memory name, string memory symbol) public {
        vm.assume(to != address(0));
        vm.assume(bytes(name).length > 0 && bytes(name).length <= 32);
        vm.assume(bytes(symbol).length > 0 && bytes(symbol).length <= 16);

        // Avoid colliding with prior deployments in this fuzz run by salting with input hash.
        bytes32 uniqueSalt = keccak256(abi.encode(salt, to, name, symbol));

        address predicted = deployer.predictTokenAddress(name, symbol, to, uniqueSalt);
        address deployed = deployer.deployToken(name, symbol, to, uniqueSalt);

        assertEq(deployed, predicted);
        assertEq(ScoopToken(deployed).balanceOf(to), ScoopToken(deployed).MAX_SUPPLY());
    }
}
