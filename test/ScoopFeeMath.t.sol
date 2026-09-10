// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopFeeMath} from "../src/libraries/ScoopFeeMath.sol";
import {ScoopFeeTypes} from "../src/libraries/ScoopFeeTypes.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

contract ScoopFeeMathHarness {
    function validateAdditionalFee(uint24 additionalFee) external pure {
        ScoopFeeMath.validateAdditionalFee(additionalFee);
    }
}

contract ScoopFeeMathTest is Test {
    ScoopFeeMathHarness harness;

    function setUp() public {
        harness = new ScoopFeeMathHarness();
    }

    function test_constantsMatchUniswapUnits() public pure {
        assertEq(ScoopFeeMath.BASE_FEE, 10_000);
        assertEq(ScoopFeeMath.ADDITIONAL_FEE_STEP, 1_000);
        assertEq(ScoopFeeMath.MAX_ADDITIONAL_FEE, 20_000);
        assertEq(ScoopFeeMath.MAX_TOTAL_FEE, 30_000);
        assertTrue(LPFeeLibrary.isValid(ScoopFeeMath.MAX_TOTAL_FEE));
        assertFalse(LPFeeLibrary.isDynamicFee(ScoopFeeMath.MAX_TOTAL_FEE));
    }

    function test_validAdditionalFeeGrid() public pure {
        for (uint24 f = 0; f <= 20_000; f += 1_000) {
            ScoopFeeMath.validateAdditionalFee(f);
            assertEq(ScoopFeeMath.totalPoolFee(f), 10_000 + f);
        }
    }

    function test_invalidAdditionalFees() public {
        uint24[8] memory bad = [uint24(1), 800, 999, 1001, 2500, 19999, 20001, 21000];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ScoopFeeMath.InvalidAdditionalFee.selector, bad[i]));
            harness.validateAdditionalFee(bad[i]);
        }
    }

    function test_splitZeroAdditional() public pure {
        ScoopFeeMath.SplitResult memory s = ScoopFeeMath.split(
            10_000,
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Holders
        );
        assertEq(s.basePart, 10_000);
        assertEq(s.extraPart, 0);
        assertEq(s.baseCreatorAmount, 7000);
        assertEq(s.baseDeployerAmount, 400);
        assertEq(s.baseBuybackAmount, 2000);
        assertEq(s.baseOperationsAmount, 600);
        assertEq(s.extraHoldersAmount, 0);
        assertEq(s.baseHoldersAmount, 0);
    }

    function test_splitConservationGrid() public pure {
        uint256[12] memory bals = [uint256(0), 1, 2, 3, 10, 99, 100, 999, 1000, 1001, 1e6, 1e18];
        for (uint24 fee = 0; fee <= 20_000; fee += 1_000) {
            for (uint256 i; i < bals.length; ++i) {
                for (uint8 alloc; alloc < 2; ++alloc) {
                    for (uint8 dest; dest < 3; ++dest) {
                        ScoopFeeMath.SplitResult memory s = ScoopFeeMath.split(
                            bals[i],
                            fee,
                            ScoopFeeTypes.CreatorAllocationDestination(alloc),
                            ScoopFeeTypes.AdditionalFeeDestination(dest)
                        );
                        assertEq(s.basePart + s.extraPart, bals[i]);
                        uint256 out = s.baseCreatorAmount + s.baseHoldersAmount + s.baseDeployerAmount
                            + s.baseBuybackAmount + s.baseOperationsAmount + s.extraCreatorAmount
                            + s.extraDeployerAmount + s.extraHoldersAmount;
                        assertEq(out, bals[i]);
                        if (fee == 0) {
                            assertEq(s.extraPart, 0);
                            assertEq(s.extraCreatorAmount + s.extraDeployerAmount + s.extraHoldersAmount, 0);
                        }
                    }
                }
            }
        }
    }

    function testFuzz_splitConservation(uint256 balance, uint8 feeStep, uint8 alloc, uint8 dest) public pure {
        balance = bound(balance, 0, type(uint128).max);
        uint24 additionalFee = uint24(bound(feeStep, 0, 20) * 1000);
        ScoopFeeTypes.CreatorAllocationDestination a = ScoopFeeTypes.CreatorAllocationDestination(bound(alloc, 0, 1));
        ScoopFeeTypes.AdditionalFeeDestination d = ScoopFeeTypes.AdditionalFeeDestination(bound(dest, 0, 2));

        ScoopFeeMath.SplitResult memory s = ScoopFeeMath.split(balance, additionalFee, a, d);
        assertEq(s.basePart + s.extraPart, balance);
        uint256 out = s.baseCreatorAmount + s.baseHoldersAmount + s.baseDeployerAmount + s.baseBuybackAmount
            + s.baseOperationsAmount + s.extraCreatorAmount + s.extraDeployerAmount + s.extraHoldersAmount;
        assertEq(out, balance);
        assertLe(ScoopFeeMath.totalPoolFee(additionalFee), 30_000);
    }
}
