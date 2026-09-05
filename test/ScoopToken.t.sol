// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopToken} from "../src/ScoopToken.sol";

contract ScoopTokenTest is Test {
    string constant NAME = "Scoop Market";
    string constant SYMBOL = "SCOOPM";
    string constant LOGO = "ipfs://bafy-logo";
    string constant DESCRIPTION = "test description";

    address recipient;
    address tokenDeployerAddr;
    address launchFactoryAddr;
    ScoopToken.Socials socials;
    ScoopToken token;

    function setUp() public {
        recipient = makeAddr("recipient");
        tokenDeployerAddr = makeAddr("deployer");
        launchFactoryAddr = makeAddr("launchFactory");
        socials = ScoopToken.Socials({
            twitter: "https://x.com/scoop",
            telegram: "https://t.me/scoop",
            discord: "https://discord.gg/scoop",
            website: "https://scoop.fun",
            farcaster: "https://warpcast.com/scoop"
        });
        token =
            new ScoopToken(NAME, SYMBOL, recipient, tokenDeployerAddr, launchFactoryAddr, LOGO, DESCRIPTION, socials);
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
        new ScoopToken(NAME, SYMBOL, address(0), tokenDeployerAddr, launchFactoryAddr, LOGO, DESCRIPTION, socials);
    }

    function test_zeroDeployerReverts() public {
        vm.expectRevert(ScoopToken.ZeroDeployer.selector);
        new ScoopToken(NAME, SYMBOL, recipient, address(0), launchFactoryAddr, LOGO, DESCRIPTION, socials);
    }

    function test_zeroLaunchFactoryReverts() public {
        vm.expectRevert(ScoopToken.ZeroLaunchFactory.selector);
        new ScoopToken(NAME, SYMBOL, recipient, tokenDeployerAddr, address(0), LOGO, DESCRIPTION, socials);
    }

    function test_metadataGetters() public view {
        assertEq(token.deployer(), tokenDeployerAddr);
        assertEq(token.launchFactory(), launchFactoryAddr);
        assertEq(token.logo(), LOGO);
        assertEq(token.description(), DESCRIPTION);

        (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        ) = token.socials();
        assertEq(twitter, socials.twitter);
        assertEq(telegram, socials.telegram);
        assertEq(discord, socials.discord);
        assertEq(website, socials.website);
        assertEq(farcaster, socials.farcaster);

        (address deployer_, string memory logo_, string memory description_, ScoopToken.Socials memory socials_) =
            token.getTokenInfo();
        assertEq(deployer_, tokenDeployerAddr);
        assertEq(logo_, LOGO);
        assertEq(description_, DESCRIPTION);
        assertEq(socials_.twitter, socials.twitter);
        assertEq(socials_.website, socials.website);
    }

    function test_contractURIContainsPresentationFields() public view {
        string memory uri = token.contractURI();
        assertTrue(bytes(uri).length > 0);
        assertTrue(_contains(uri, "data:application/json"));
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
        (bool tokenUriOk,) = address(token).call(abi.encodeWithSignature("tokenURI()"));
        (bool metadataUriOk,) = address(token).call(abi.encodeWithSignature("metadataURI()"));
        (bool imageOk,) = address(token).call(abi.encodeWithSignature("image()"));
        (bool setImageOk,) = address(token).call(abi.encodeWithSignature("setImage(string)", "x"));
        (bool setLogoOk,) = address(token).call(abi.encodeWithSignature("setLogo(string)", "x"));
        (bool setDescOk,) = address(token).call(abi.encodeWithSignature("setDescription(string)", "x"));
        (bool setSocialsOk,) = address(token)
            .call(abi.encodeWithSignature("setSocials(string,string,string,string,string)", "a", "b", "c", "d", "e"));

        assertFalse(ownerOk);
        assertFalse(adminOk);
        assertFalse(mintOk);
        assertFalse(pauseOk);
        assertFalse(blacklistOk);
        assertFalse(whitelistOk);
        assertFalse(setNameOk);
        assertFalse(rescueOk);
        assertFalse(tokenUriOk);
        assertFalse(metadataUriOk);
        assertFalse(imageOk);
        assertFalse(setImageOk);
        assertFalse(setLogoOk);
        assertFalse(setDescOk);
        assertFalse(setSocialsOk);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
