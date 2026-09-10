// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {ScoopFeeTypes} from "./ScoopFeeTypes.sol";

/**
 * @title ScoopFeeMath
 * @notice Pure validation and split math for SCOOP launch trading fees.
 * @dev Uniswap v4 LP fees use hundredths of a bip (`1% = 10_000`, denom `1_000_000`).
 *      Distributor BPS use denom `10_000` of the harvested base slice only.
 */
library ScoopFeeMath {
    using ScoopFeeTypes for ScoopFeeTypes.CreatorAllocationDestination;
    using ScoopFeeTypes for ScoopFeeTypes.AdditionalFeeDestination;

    uint24 internal constant BASE_FEE = 10_000;
    uint24 internal constant ADDITIONAL_FEE_STEP = 1_000;
    uint24 internal constant MAX_ADDITIONAL_FEE = 20_000;
    uint24 internal constant MAX_TOTAL_FEE = 30_000;

    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant CREATOR_REWARDS_BPS = 7000;
    uint16 internal constant DEPLOYER_BPS = 400;
    uint16 internal constant BUYBACK_BPS = 2000;
    uint16 internal constant OPERATIONS_BPS = 600;

    error InvalidAdditionalFee(uint24 additionalFee);
    error InvalidCreatorAllocationDestination(uint8 value);
    error InvalidAdditionalFeeDestination(uint8 value);
    error TotalFeeTooLarge(uint24 totalFee);

    struct SplitResult {
        uint256 basePart;
        uint256 extraPart;
        uint256 baseCreatorAmount;
        uint256 baseHoldersAmount;
        uint256 baseDeployerAmount;
        uint256 baseBuybackAmount;
        uint256 baseOperationsAmount;
        uint256 extraCreatorAmount;
        uint256 extraDeployerAmount;
        uint256 extraHoldersAmount;
    }

    /// @notice Validate additional fee: `0..20_000` in steps of `1_000`.
    function validateAdditionalFee(uint24 additionalFee) internal pure {
        if (additionalFee > MAX_ADDITIONAL_FEE || additionalFee % ADDITIONAL_FEE_STEP != 0) {
            revert InvalidAdditionalFee(additionalFee);
        }
        uint24 total = totalPoolFee(additionalFee);
        if (total > MAX_TOTAL_FEE || !LPFeeLibrary.isValid(total) || LPFeeLibrary.isDynamicFee(total)) {
            revert TotalFeeTooLarge(total);
        }
    }

    function totalPoolFee(uint24 additionalFee) internal pure returns (uint24) {
        return BASE_FEE + additionalFee;
    }

    function validateCreatorAllocationDestination(ScoopFeeTypes.CreatorAllocationDestination dest) internal pure {
        if (uint8(dest) > uint8(ScoopFeeTypes.CreatorAllocationDestination.Holders)) {
            revert InvalidCreatorAllocationDestination(uint8(dest));
        }
    }

    function validateAdditionalFeeDestination(ScoopFeeTypes.AdditionalFeeDestination dest) internal pure {
        if (uint8(dest) > uint8(ScoopFeeTypes.AdditionalFeeDestination.Holders)) {
            revert InvalidAdditionalFeeDestination(uint8(dest));
        }
    }

    /// @notice Split harvested balance `B` into base/extra and destination legs.
    function split(
        uint256 balance,
        uint24 additionalFee,
        ScoopFeeTypes.CreatorAllocationDestination creatorAlloc,
        ScoopFeeTypes.AdditionalFeeDestination additionalDest
    ) internal pure returns (SplitResult memory r) {
        uint24 F_b = BASE_FEE;
        uint24 F_a = additionalFee;

        if (F_a == 0) {
            r.basePart = balance;
            r.extraPart = 0;
        } else {
            uint24 F = F_b + F_a;
            r.basePart = (balance * uint256(F_b)) / uint256(F);
            r.extraPart = balance - r.basePart;
        }

        uint256 creatorAllocation = (r.basePart * CREATOR_REWARDS_BPS) / BPS_DENOMINATOR;
        r.baseDeployerAmount = (r.basePart * DEPLOYER_BPS) / BPS_DENOMINATOR;
        r.baseBuybackAmount = (r.basePart * BUYBACK_BPS) / BPS_DENOMINATOR;
        r.baseOperationsAmount = r.basePart - creatorAllocation - r.baseDeployerAmount - r.baseBuybackAmount;

        if (creatorAlloc == ScoopFeeTypes.CreatorAllocationDestination.Creator) {
            r.baseCreatorAmount = creatorAllocation;
        } else {
            r.baseHoldersAmount = creatorAllocation;
        }

        if (r.extraPart != 0) {
            if (additionalDest == ScoopFeeTypes.AdditionalFeeDestination.Creator) {
                r.extraCreatorAmount = r.extraPart;
            } else if (additionalDest == ScoopFeeTypes.AdditionalFeeDestination.Deployer) {
                r.extraDeployerAmount = r.extraPart;
            } else {
                r.extraHoldersAmount = r.extraPart;
            }
        }
    }

    function usesCreatorPath(
        ScoopFeeTypes.CreatorAllocationDestination creatorAlloc,
        ScoopFeeTypes.AdditionalFeeDestination additionalDest
    ) internal pure returns (bool) {
        return creatorAlloc == ScoopFeeTypes.CreatorAllocationDestination.Creator
            || additionalDest == ScoopFeeTypes.AdditionalFeeDestination.Creator;
    }

    function usesHoldersPath(
        ScoopFeeTypes.CreatorAllocationDestination creatorAlloc,
        ScoopFeeTypes.AdditionalFeeDestination additionalDest
    ) internal pure returns (bool) {
        return creatorAlloc == ScoopFeeTypes.CreatorAllocationDestination.Holders
            || additionalDest == ScoopFeeTypes.AdditionalFeeDestination.Holders;
    }
}
