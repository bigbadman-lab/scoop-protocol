// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopToken} from "../src/ScoopToken.sol";

contract ScoopTokenTest is Test {
    string constant NAME = "Scoop Market";
    string constant SYMBOL = "SCOOPM";

    address recipient;
    ScoopToken token;

    function setUp() public {
        recipient = makeAddr("recipient");
        token = new ScoopToken(NAME, SYMBOL, recipient);
    }

    function test_nameSetCorrectly() public view {
        assertEq(token.name(), NAME);
    }

    function test_symbolSetCorrectly() public view {
        assertEq(token.symbol(), SYMBOL);
    }

    function test_decimalsAre18() public view {
        assertEq(token.decimals(), 18);
    }

    function test_maxSupplyIsOneBillionEther() public view {
        assertEq(token.MAX_SUPPLY(), 1_000_000_000 ether);
    }

    function test_totalSupplyEqualsMaxSupply() public view {
        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    function test_fullSupplyMintedToRecipient() public view {
        assertEq(token.balanceOf(recipient), token.MAX_SUPPLY());
    }

    function test_zeroRecipientReverts() public {
        vm.expectRevert(ScoopToken.ZeroRecipient.selector);
        new ScoopToken(NAME, SYMBOL, address(0));
    }

    function test_transferWorks() public {
        address alice = makeAddr("alice");
        uint256 amount = 1_000 ether;

        vm.prank(recipient);
        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(recipient), token.MAX_SUPPLY() - amount);
    }

    function test_noOwnerAdminOrPrivilegedSurface() public {
        (bool ownerOk,) = address(token).call(abi.encodeWithSignature("owner()"));
        (bool adminOk,) = address(token).call(abi.encodeWithSignature("DEFAULT_ADMIN_ROLE()"));
        (bool mintOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", recipient, 1));
        (bool pauseOk,) = address(token).call(abi.encodeWithSignature("pause()"));
        (bool blacklistOk,) = address(token).call(abi.encodeWithSignature("blacklist(address)", recipient));
        (bool whitelistOk,) = address(token).call(abi.encodeWithSignature("whitelist(address)", recipient));
        (bool setNameOk,) = address(token).call(abi.encodeWithSignature("setName(string)", "x"));
        (bool rescueOk,) = address(token).call(abi.encodeWithSignature("rescueTokens(address,uint256)", recipient, 1));

        assertFalse(ownerOk);
        assertFalse(adminOk);
        assertFalse(mintOk);
        assertFalse(pauseOk);
        assertFalse(blacklistOk);
        assertFalse(whitelistOk);
        assertFalse(setNameOk);
        assertFalse(rescueOk);
    }
}
