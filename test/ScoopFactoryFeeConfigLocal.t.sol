// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopFactory} from "../src/ScoopFactory.sol";
import {ScoopFeeMath} from "../src/libraries/ScoopFeeMath.sol";
import {ScoopFeeTypes} from "../src/libraries/ScoopFeeTypes.sol";
import {ScoopLaunchMetadataHelpers} from "./helpers/ScoopLaunchMetadataHelpers.sol";

/**
 * @notice Local (non-fork) coverage for Factory fee validation & constants.
 * @dev Full launch/pool integration remains in fork suites.
 */
contract ScoopFactoryFeeConfigLocalTest is Test {
    function test_factoryFeeConstants() public {
        // Deploy minimal stub is heavy; assert library/constants alignment used by Factory.
        assertEq(ScoopFeeMath.BASE_FEE, 10_000);
        assertEq(ScoopFeeMath.MAX_ADDITIONAL_FEE, 20_000);
        assertEq(ScoopFeeMath.ADDITIONAL_FEE_STEP, 1_000);

        for (uint24 f = 0; f <= 20_000; f += 1_000) {
            assertEq(ScoopFeeMath.totalPoolFee(f), 10_000 + f);
        }
        assertEq(ScoopFeeMath.totalPoolFee(0), 10_000);
        assertEq(ScoopFeeMath.totalPoolFee(1_000), 11_000);
        assertEq(ScoopFeeMath.totalPoolFee(10_000), 20_000);
        assertEq(ScoopFeeMath.totalPoolFee(20_000), 30_000);
    }

    function test_defaultLaunchParamsFeeFields() public pure {
        (
            uint24 additionalFee,
            ScoopFeeTypes.CreatorAllocationDestination creatorAlloc,
            ScoopFeeTypes.AdditionalFeeDestination additionalDest
        ) = ScoopLaunchMetadataHelpers.defaultFeeFields();
        assertEq(additionalFee, 0);
        assertEq(uint8(creatorAlloc), uint8(ScoopFeeTypes.CreatorAllocationDestination.Creator));
        assertEq(uint8(additionalDest), uint8(ScoopFeeTypes.AdditionalFeeDestination.Creator));
    }

    function test_usesCreatorAndHoldersPathHelpers() public pure {
        assertTrue(
            ScoopFeeMath.usesCreatorPath(
                ScoopFeeTypes.CreatorAllocationDestination.Creator, ScoopFeeTypes.AdditionalFeeDestination.Deployer
            )
        );
        assertFalse(
            ScoopFeeMath.usesCreatorPath(
                ScoopFeeTypes.CreatorAllocationDestination.Holders, ScoopFeeTypes.AdditionalFeeDestination.Holders
            )
        );
        assertTrue(
            ScoopFeeMath.usesHoldersPath(
                ScoopFeeTypes.CreatorAllocationDestination.Holders, ScoopFeeTypes.AdditionalFeeDestination.Creator
            )
        );
    }
}
