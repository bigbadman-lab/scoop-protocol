// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ScoopFeeTypes
 * @notice Canonical immutable launch-fee destination enums for SCOOP Protocol.
 */
library ScoopFeeTypes {
    /// @notice Where the base 70% Creator Allocation leg is routed.
    enum CreatorAllocationDestination {
        Creator,
        Holders
    }

    /// @notice Where 100% of the additional trading-fee slice is routed.
    enum AdditionalFeeDestination {
        Creator,
        Deployer,
        Holders
    }
}
