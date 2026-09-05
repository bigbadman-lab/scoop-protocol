// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopFactory} from "../../src/ScoopFactory.sol";
import {ScoopToken} from "../../src/ScoopToken.sol";

/// @dev Shared default presentation metadata for Factory fork/unit tests.
library ScoopLaunchMetadataHelpers {
    function defaultMetadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: "SCOOP test token",
            imageUri: "ipfs://bafy-scoop-test",
            twitter: "",
            telegram: "",
            discord: "",
            website: "https://scoop.fun",
            farcaster: ""
        });
    }

    /// @dev Realistic sizes for gas baselines.
    function realisticMetadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: "A SCOOP protocol test launch with realistic metadata length for gas measurement baselines.",
            imageUri: "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
            twitter: "https://x.com/scoopprotocol",
            telegram: "https://t.me/scoop",
            discord: "https://discord.gg/scoop",
            website: "https://scoop.fun/token",
            farcaster: "https://warpcast.com/scoop"
        });
    }

    function emptySocialsMetadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: "no socials",
            imageUri: "ipfs://bafy-empty-socials",
            twitter: "",
            telegram: "",
            discord: "",
            website: "",
            farcaster: ""
        });
    }

    /// @dev Build LaunchMetadata with empty socials except optional website.
    function metadata(string memory description, string memory website, string memory imageUri)
        internal
        pure
        returns (ScoopFactory.LaunchMetadata memory)
    {
        return ScoopFactory.LaunchMetadata({
            description: description,
            imageUri: imageUri,
            twitter: "",
            telegram: "",
            discord: "",
            website: website,
            farcaster: ""
        });
    }

    function toSocials(ScoopFactory.LaunchMetadata memory md) internal pure returns (ScoopToken.Socials memory) {
        return ScoopToken.Socials({
            twitter: md.twitter,
            telegram: md.telegram,
            discord: md.discord,
            website: md.website,
            farcaster: md.farcaster
        });
    }

    function emptySocials() internal pure returns (ScoopToken.Socials memory) {
        return ScoopToken.Socials({twitter: "", telegram: "", discord: "", website: "", farcaster: ""});
    }
}
