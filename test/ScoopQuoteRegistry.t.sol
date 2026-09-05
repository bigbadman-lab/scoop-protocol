// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ScoopQuoteRegistry} from "../src/ScoopQuoteRegistry.sol";

contract ScoopQuoteRegistryTest is Test {
    ScoopQuoteRegistry registry;

    address authority;
    address stranger;

    address constant SCOOP_ASSET = address(0xA11CE);
    address constant STOCK_ASSET = address(0xB0B);
    address constant PONS_ASSET = address(0xC0FFEE);
    address constant OTHER_ASSET = address(0xDEAD);

    event QuoteRegistered(address indexed asset, ScoopQuoteRegistry.QuoteType indexed quoteType);
    event QuoteStatusChanged(address indexed asset, bool enabled);

    function setUp() public {
        authority = makeAddr("registryAuthority");
        stranger = makeAddr("stranger");
        registry = new ScoopQuoteRegistry(authority);
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    function test_constructor_pinsAuthority() public view {
        assertEq(registry.registryAuthority(), authority);
    }

    function test_constructor_zeroAuthorityReverts() public {
        vm.expectRevert(ScoopQuoteRegistry.ZeroRegistryAuthority.selector);
        new ScoopQuoteRegistry(address(0));
    }

    // ─── Native ETH ──────────────────────────────────────────────────────────

    function test_registerNativeEth_succeeds() public {
        vm.expectEmit(true, true, false, true);
        emit QuoteRegistered(address(0), ScoopQuoteRegistry.QuoteType.Native);

        vm.prank(authority);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);

        assertTrue(registry.isRegistered(address(0)));
        assertTrue(registry.isEnabled(address(0)));
        assertEq(uint8(registry.quoteType(address(0))), uint8(ScoopQuoteRegistry.QuoteType.Native));

        ScoopQuoteRegistry.QuoteAsset memory q = registry.getQuote(address(0));
        assertEq(uint8(q.quoteType), uint8(ScoopQuoteRegistry.QuoteType.Native));
        assertTrue(q.enabled);
    }

    function test_registerAddressZero_asScoop_reverts() public {
        vm.prank(authority);
        vm.expectRevert(ScoopQuoteRegistry.InvalidNonNativeQuote.selector);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Scoop);
    }

    function test_registerAddressZero_asStock_reverts() public {
        vm.prank(authority);
        vm.expectRevert(ScoopQuoteRegistry.InvalidNonNativeQuote.selector);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Stock);
    }

    function test_registerAddressZero_asPons_reverts() public {
        vm.prank(authority);
        vm.expectRevert(ScoopQuoteRegistry.InvalidNonNativeQuote.selector);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Pons);
    }

    // ─── ERC20-like addresses ────────────────────────────────────────────────

    function test_registerScoop_succeeds() public {
        vm.prank(authority);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        assertEq(uint8(registry.quoteType(SCOOP_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Scoop));
        assertTrue(registry.isEnabled(SCOOP_ASSET));
    }

    function test_registerStock_succeeds() public {
        vm.prank(authority);
        registry.registerQuote(STOCK_ASSET, ScoopQuoteRegistry.QuoteType.Stock);
        assertEq(uint8(registry.quoteType(STOCK_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Stock));
    }

    function test_registerPons_succeeds() public {
        vm.prank(authority);
        registry.registerQuote(PONS_ASSET, ScoopQuoteRegistry.QuoteType.Pons);
        assertEq(uint8(registry.quoteType(PONS_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Pons));
    }

    function test_registerNonzeroAsNative_reverts() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.InvalidNativeQuote.selector, OTHER_ASSET));
        registry.registerQuote(OTHER_ASSET, ScoopQuoteRegistry.QuoteType.Native);
    }

    // ─── Duplicate registration ──────────────────────────────────────────────

    function test_duplicateRegistration_reverts() public {
        vm.startPrank(authority);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, SCOOP_ASSET));
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        vm.stopPrank();
    }

    function test_cannotReregisterUnderDifferentType() public {
        vm.startPrank(authority);
        registry.registerQuote(STOCK_ASSET, ScoopQuoteRegistry.QuoteType.Stock);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, STOCK_ASSET));
        registry.registerQuote(STOCK_ASSET, ScoopQuoteRegistry.QuoteType.Pons);
        vm.stopPrank();

        assertEq(uint8(registry.quoteType(STOCK_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Stock));
    }

    // ─── Enable / disable ────────────────────────────────────────────────────

    function test_disableAndReenable() public {
        vm.startPrank(authority);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);

        vm.expectEmit(true, false, false, true);
        emit QuoteStatusChanged(SCOOP_ASSET, false);
        registry.setQuoteEnabled(SCOOP_ASSET, false);

        assertTrue(registry.isRegistered(SCOOP_ASSET));
        assertFalse(registry.isEnabled(SCOOP_ASSET));
        assertEq(uint8(registry.quoteType(SCOOP_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Scoop));

        vm.expectEmit(true, false, false, true);
        emit QuoteStatusChanged(SCOOP_ASSET, true);
        registry.setQuoteEnabled(SCOOP_ASSET, true);

        assertTrue(registry.isEnabled(SCOOP_ASSET));
        assertEq(uint8(registry.quoteType(SCOOP_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Scoop));
        vm.stopPrank();
    }

    function test_setSameStatus_reverts() public {
        vm.startPrank(authority);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteStatusUnchanged.selector, SCOOP_ASSET, true));
        registry.setQuoteEnabled(SCOOP_ASSET, true);
        vm.stopPrank();
    }

    function test_setStatusUnregistered_reverts() public {
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteNotRegistered.selector, OTHER_ASSET));
        registry.setQuoteEnabled(OTHER_ASSET, false);
    }

    // ─── Unauthorized ────────────────────────────────────────────────────────

    function test_nonAuthority_register_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
    }

    function test_nonAuthority_disable_reverts() public {
        vm.prank(authority);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);

        vm.prank(stranger);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        registry.setQuoteEnabled(address(0), false);
    }

    function test_nonAuthority_reenable_reverts() public {
        vm.startPrank(authority);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        registry.setQuoteEnabled(SCOOP_ASSET, false);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(ScoopQuoteRegistry.Unauthorized.selector);
        registry.setQuoteEnabled(SCOOP_ASSET, true);
    }

    // ─── Reads ───────────────────────────────────────────────────────────────

    function test_unknownAsset_reads() public {
        assertFalse(registry.isRegistered(OTHER_ASSET));
        assertFalse(registry.isEnabled(OTHER_ASSET));

        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteNotRegistered.selector, OTHER_ASSET));
        registry.quoteType(OTHER_ASSET);

        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteNotRegistered.selector, OTHER_ASSET));
        registry.getQuote(OTHER_ASSET);
    }

    function test_getQuote_registered() public {
        vm.prank(authority);
        registry.registerQuote(PONS_ASSET, ScoopQuoteRegistry.QuoteType.Pons);

        ScoopQuoteRegistry.QuoteAsset memory q = registry.getQuote(PONS_ASSET);
        assertEq(uint8(q.quoteType), uint8(ScoopQuoteRegistry.QuoteType.Pons));
        assertTrue(q.enabled);
    }

    // ─── Enumeration ─────────────────────────────────────────────────────────

    function test_enumeration_insertionOrderAndDisable() public {
        assertEq(registry.registeredQuoteCount(), 0);

        vm.startPrank(authority);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        registry.registerQuote(STOCK_ASSET, ScoopQuoteRegistry.QuoteType.Stock);
        vm.stopPrank();

        assertEq(registry.registeredQuoteCount(), 3);
        assertEq(registry.registeredQuoteAt(0), address(0));
        assertEq(registry.registeredQuoteAt(1), SCOOP_ASSET);
        assertEq(registry.registeredQuoteAt(2), STOCK_ASSET);

        vm.prank(authority);
        registry.setQuoteEnabled(SCOOP_ASSET, false);

        assertEq(registry.registeredQuoteCount(), 3);
        assertEq(registry.registeredQuoteAt(1), SCOOP_ASSET);

        vm.prank(authority);
        registry.setQuoteEnabled(SCOOP_ASSET, true);
        assertEq(registry.registeredQuoteCount(), 3);
    }

    function test_registeredQuoteAt_outOfBounds_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.IndexOutOfBounds.selector, 0, 0));
        registry.registeredQuoteAt(0);

        vm.prank(authority);
        registry.registerQuote(address(0), ScoopQuoteRegistry.QuoteType.Native);

        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.IndexOutOfBounds.selector, 1, 1));
        registry.registeredQuoteAt(1);
    }

    // ─── Security surface ────────────────────────────────────────────────────

    function test_noAdminMutationSurface() public {
        // Forbidden admin/rescue/type-mutation selectors must not exist on the ABI.
        _assertNoFn(abi.encodeWithSignature("owner()"));
        _assertNoFn(abi.encodeWithSignature("transferOwnership(address)", stranger));
        _assertNoFn(abi.encodeWithSignature("setAuthority(address)", stranger));
        _assertNoFn(abi.encodeWithSignature("transferAuthority(address)", stranger));
        _assertNoFn(abi.encodeWithSignature("execute(address,bytes)", stranger, bytes("")));
        _assertNoFn(abi.encodeWithSignature("rescueETH(address,uint256)", stranger, uint256(1)));
        _assertNoFn(abi.encodeWithSignature("rescueToken(address,address,uint256)", SCOOP_ASSET, stranger, uint256(1)));
        _assertNoFn(abi.encodeWithSignature("setQuoteType(address,uint8)", SCOOP_ASSET, uint8(2)));
        _assertNoFn(abi.encodeWithSignature("deleteQuote(address)", SCOOP_ASSET));

        // Authority cannot change QuoteType after registration (re-register blocked).
        vm.startPrank(authority);
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Scoop);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, SCOOP_ASSET));
        registry.registerQuote(SCOOP_ASSET, ScoopQuoteRegistry.QuoteType.Stock);
        vm.stopPrank();
        assertEq(uint8(registry.quoteType(SCOOP_ASSET)), uint8(ScoopQuoteRegistry.QuoteType.Scoop));
    }

    function _assertNoFn(bytes memory callData) internal {
        vm.prank(authority);
        (bool success,) = address(registry).call(callData);
        assertFalse(success, "forbidden surface should not succeed");
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────────

    function testFuzz_registerNonNative(address asset, uint8 typeRaw) public {
        vm.assume(asset != address(0));
        ScoopQuoteRegistry.QuoteType qt = ScoopQuoteRegistry.QuoteType(bound(typeRaw, 1, 3));

        vm.prank(authority);
        registry.registerQuote(asset, qt);

        assertTrue(registry.isRegistered(asset));
        assertTrue(registry.isEnabled(asset));
        assertEq(uint8(registry.quoteType(asset)), uint8(qt));
    }

    function testFuzz_duplicateRegistrationReverts(address asset, uint8 typeRaw) public {
        ScoopQuoteRegistry.QuoteType qt;
        if (asset == address(0)) {
            qt = ScoopQuoteRegistry.QuoteType.Native;
        } else {
            qt = ScoopQuoteRegistry.QuoteType(bound(typeRaw, 1, 3));
        }

        vm.startPrank(authority);
        registry.registerQuote(asset, qt);
        vm.expectRevert(abi.encodeWithSelector(ScoopQuoteRegistry.QuoteAlreadyRegistered.selector, asset));
        registry.registerQuote(asset, qt);
        vm.stopPrank();
    }

    function testFuzz_enableLifecyclePreservesType(address asset, uint8 typeRaw) public {
        ScoopQuoteRegistry.QuoteType qt;
        if (asset == address(0)) {
            qt = ScoopQuoteRegistry.QuoteType.Native;
        } else {
            qt = ScoopQuoteRegistry.QuoteType(bound(typeRaw, 1, 3));
        }

        vm.startPrank(authority);
        registry.registerQuote(asset, qt);
        registry.setQuoteEnabled(asset, false);
        assertTrue(registry.isRegistered(asset));
        assertFalse(registry.isEnabled(asset));
        assertEq(uint8(registry.quoteType(asset)), uint8(qt));

        registry.setQuoteEnabled(asset, true);
        assertTrue(registry.isRegistered(asset));
        assertTrue(registry.isEnabled(asset));
        assertEq(uint8(registry.quoteType(asset)), uint8(qt));
        vm.stopPrank();
    }
}
