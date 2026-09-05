// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";

contract ScoopTestTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    ScoopTestToken token;
    address recipient;
    address alice;

    function setUp() public {
        recipient = makeAddr("recipient");
        alice = makeAddr("alice");
        token = new ScoopTestToken("Scoop Test", "SCOOP", recipient, SUPPLY);
    }

    function test_constructorSetsName() public view {
        assertEq(token.name(), "Scoop Test");
    }

    function test_constructorSetsSymbol() public view {
        assertEq(token.symbol(), "SCOOP");
    }

    function test_constructorMintsExactSupplyToRecipient() public view {
        assertEq(token.balanceOf(recipient), SUPPLY);
    }

    function test_totalSupplyEqualsRequestedSupply() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployWithZeroRecipientReverts() public {
        vm.expectRevert(ScoopTestToken.ZeroRecipient.selector);
        new ScoopTestToken("Scoop Test", "SCOOP", address(0), SUPPLY);
    }

    function test_transferWorks() public {
        uint256 amount = 1_000 ether;

        vm.prank(recipient);
        bool success = token.transfer(alice, amount);

        assertTrue(success);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(recipient), SUPPLY - amount);
    }

    function test_noPrivilegedOwnerOrAdminState() public {
        // ScoopTestToken only adds ZeroRecipient; no Ownable/AccessControl surface.
        // Probe common privileged selectors — all must be empty (no code / no function).
        (bool ownerOk,) = address(token).call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = address(token).call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        (bool mintOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));

        assertFalse(ownerOk);
        assertFalse(adminOk);
        assertFalse(mintOk);
    }
}
