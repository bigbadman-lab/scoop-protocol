// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopToken} from "../src/ScoopToken.sol";
import {ScoopJson} from "../src/libraries/ScoopJson.sol";

/// @dev Milestone 4K — ScoopToken metadata getters, contractURI JSON safety, immutability.
contract ScoopTokenMetadataTest is Test {
    address constant RECIPIENT = address(0xBEEF);
    address constant DEPLOYER = address(0xA11CE);
    address constant FACTORY = address(0xFACA11);

    function _deploy(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        ScoopToken.Socials memory socials_
    ) internal returns (ScoopToken) {
        return new ScoopToken(name_, symbol_, RECIPIENT, DEPLOYER, FACTORY, logo_, description_, socials_);
    }

    function test_logoDescriptionSocialsPinned() public {
        ScoopToken.Socials memory s = ScoopToken.Socials({
            twitter: "https://x.com/ex",
            telegram: "https://t.me/ex",
            discord: "https://discord.gg/ex",
            website: "https://example.com",
            farcaster: "https://warpcast.com/ex"
        });
        ScoopToken t = _deploy("Example", "EXMPL", "ipfs://bafy-example", "What this is.", s);

        assertEq(t.logo(), "ipfs://bafy-example");
        assertEq(t.description(), "What this is.");
        (string memory tw, string memory tg, string memory dc, string memory web, string memory fc) = t.socials();
        assertEq(tw, s.twitter);
        assertEq(tg, s.telegram);
        assertEq(dc, s.discord);
        assertEq(web, s.website);
        assertEq(fc, s.farcaster);
        assertEq(t.deployer(), DEPLOYER);
        assertEq(t.launchFactory(), FACTORY);

        (address d, string memory logo_, string memory desc_, ScoopToken.Socials memory gs) = t.getTokenInfo();
        assertEq(d, DEPLOYER);
        assertEq(logo_, t.logo());
        assertEq(desc_, t.description());
        assertEq(gs.website, s.website);
    }

    function test_contractURI_withWebsite() public {
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "https://example.com", farcaster: ""});
        ScoopToken t = _deploy("Example", "EXMPL", "ipfs://bafy-example", "What this is.", s);
        string memory uri = t.contractURI();
        assertTrue(_startsWith(uri, "data:application/json;utf8,"));
        string memory json = _stripDataUri(uri);
        assertTrue(_contains(json, '"name":"Example"'));
        assertTrue(_contains(json, '"symbol":"EXMPL"'));
        assertTrue(_contains(json, '"description":"What this is."'));
        assertTrue(_contains(json, '"image":"ipfs://bafy-example"'));
        assertTrue(_contains(json, '"external_link":"https://example.com"'));
        // No economics fields.
        assertFalse(_contains(json, "fdv"));
        assertFalse(_contains(json, "fee"));
        assertFalse(_contains(json, "creatorId"));
    }

    function test_contractURI_omitsExternalLinkWhenWebsiteEmpty() public {
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy("Example", "EXMPL", "ipfs://bafy-example", "What this is.", s);
        string memory json = _stripDataUri(t.contractURI());
        assertFalse(_contains(json, "external_link"));
        assertTrue(_contains(json, '"image":"ipfs://bafy-example"'));
    }

    function test_contractURI_escapesQuotesAndBackslash() public {
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy('Na"me', "SY\\M", "ipfs://x", 'He said "hi" \\ ok', s);
        string memory json = _stripDataUri(t.contractURI());
        assertTrue(_contains(json, 'Na\\"me'));
        assertTrue(_contains(json, "SY\\\\M"));
        assertTrue(_contains(json, 'He said \\"hi\\" \\\\ ok'));
        // Round-trip via escape helper for description.
        assertEq(ScoopJson.escape('He said "hi" \\ ok'), 'He said \\"hi\\" \\\\ ok');
    }

    function test_contractURI_escapesControlsAndPreservesUtf8() public {
        // description: hello + newline + tab + emoji
        string memory desc = string(abi.encodePacked("hello", bytes1(0x0a), bytes1(0x09), unicode"🚀"));
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy("N", "S", "ipfs://x", desc, s);
        string memory json = _stripDataUri(t.contractURI());
        assertTrue(_contains(json, "hello\\n\\t"));
        // UTF-8 rocket bytes preserved (not escaped as control).
        assertTrue(_contains(json, unicode"🚀"));
    }

    function test_contractURI_jsonInjectionCannotBreakOut() public {
        string memory evil = '", "hacked": true, "x": "';
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy("N", "S", "ipfs://x", evil, s);
        string memory json = _stripDataUri(t.contractURI());
        // Escaped quotes mean the injection is inside the description string value.
        assertTrue(_contains(json, '\\", \\"hacked\\": true'));
        assertFalse(_contains(json, '"hacked": true'));
    }

    function test_contractURI_htmlLookingContentPreservedEscaped() public {
        string memory html = "<script>alert(1)</script>";
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy("N", "S", "ipfs://x", html, s);
        string memory json = _stripDataUri(t.contractURI());
        assertTrue(_contains(json, html)); // no special JSON chars; raw preserved
    }

    function test_noMetadataMutators() public {
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy("N", "S", "ipfs://x", "d", s);
        address a = address(t);
        (bool ok1,) = a.call(abi.encodeWithSignature("setLogo(string)", "x"));
        (bool ok2,) = a.call(abi.encodeWithSignature("setDescription(string)", "x"));
        (bool ok3,) =
            a.call(abi.encodeWithSignature("setSocials(string,string,string,string,string)", "", "", "", "", ""));
        (bool ok4,) = a.call(abi.encodeWithSignature("setWebsite(string)", "x"));
        (bool ok5,) = a.call(abi.encodeWithSignature("setContractURI(string)", "x"));
        (bool ok6,) = a.call(abi.encodeWithSignature("setDeployer(address)", address(1)));
        (bool ok7,) = a.call(abi.encodeWithSignature("setLaunchFactory(address)", address(1)));
        (bool ok8,) = a.call(abi.encodeWithSignature("owner()"));
        assertFalse(ok1);
        assertFalse(ok2);
        assertFalse(ok3);
        assertFalse(ok4);
        assertFalse(ok5);
        assertFalse(ok6);
        assertFalse(ok7);
        assertFalse(ok8);
    }

    function test_supplyUnchanged() public {
        ScoopToken.Socials memory s =
            ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
        ScoopToken t = _deploy("N", "S", "ipfs://x", "d", s);
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.balanceOf(RECIPIENT), 1_000_000_000 ether);
        assertEq(t.balanceOf(DEPLOYER), 0);
    }

    function test_escape_controlBytesAsUnicode() public view {
        bytes memory raw = new bytes(1);
        raw[0] = 0x01;
        string memory escaped = ScoopJson.escape(string(raw));
        assertEq(escaped, "\\u0001");
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _stripDataUri(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes("data:application/json;utf8,");
        require(b.length >= prefix.length, "short");
        bytes memory out = new bytes(b.length - prefix.length);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[i + prefix.length];
        }
        return string(out);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
