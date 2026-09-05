// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopFactory} from "../../src/ScoopFactory.sol";

/// @dev Shared default presentation metadata for Factory fork/unit tests.
library ScoopLaunchMetadataHelpers {
    function defaultMetadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: "SCOOP test token", externalUrl: "https://scoop.fun", imageUri: "ipfs://bafy-scoop-test"
        });
    }

    /// @dev Realistic sizes for gas baselines (~100 / ~30 / ~60 bytes).
    function realisticMetadata() internal pure returns (ScoopFactory.LaunchMetadata memory) {
        return ScoopFactory.LaunchMetadata({
            description: "A SCOOP protocol test launch with realistic metadata length for gas measurement baselines.",
            externalUrl: "https://scoop.fun/token",
            imageUri: "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"
        });
    }
}
