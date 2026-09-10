// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ScoopFeeDistributor} from "../src/ScoopFeeDistributor.sol";
import {ScoopTestToken} from "../src/ScoopTestToken.sol";
import {IScoopCreatorRewards} from "../src/interfaces/IScoopCreatorRewards.sol";
import {ScoopFeeMath} from "../src/libraries/ScoopFeeMath.sol";
import {ScoopFeeTypes} from "../src/libraries/ScoopFeeTypes.sol";
import {MockHolderRewards} from "./mocks/MockHolderRewards.sol";

/// @dev Minimal CreatorRewards stand-in for distributor unit tests (no registry/source gating).
contract MockCreatorRewards is IScoopCreatorRewards {
    uint256 public ethCredited;
    mapping(address => uint256) public tokenCredited;

    function creditETH() external payable override {
        ethCredited += msg.value;
    }

    function creditToken(address token, uint256 amount) external override {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        tokenCredited[token] += amount;
    }
}

/// @dev Test-only recipient that rejects native ETH.
contract RejectETH {
    receive() external payable {
        revert("no eth");
    }

    fallback() external payable {
        revert("no eth");
    }
}

contract ScoopFeeDistributorTest is Test {
    MockCreatorRewards creatorRewards;
    MockHolderRewards holderVault;
    address deployerRecipient;
    address buybackVault;
    address operations;
    address holderRewards;
    address caller;

    ScoopFeeDistributor distributor;
    ScoopTestToken token;

    function setUp() public {
        creatorRewards = new MockCreatorRewards();
        holderVault = new MockHolderRewards();
        deployerRecipient = makeAddr("deployer");
        buybackVault = makeAddr("buybackVault");
        operations = makeAddr("operations");
        holderRewards = address(holderVault);
        caller = makeAddr("caller");

        distributor = _dist(
            0, ScoopFeeTypes.CreatorAllocationDestination.Creator, ScoopFeeTypes.AdditionalFeeDestination.Creator
        );

        token = new ScoopTestToken("Scoop Test", "SCOOPT", address(this), 1_000_000_000 ether);
    }

    function _dist(
        uint24 additionalFee,
        ScoopFeeTypes.CreatorAllocationDestination creatorAlloc,
        ScoopFeeTypes.AdditionalFeeDestination additionalDest
    ) internal returns (ScoopFeeDistributor) {
        return new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            holderRewards,
            additionalFee,
            creatorAlloc,
            additionalDest
        );
    }

    function test_constructorStoresConfig() public view {
        assertEq(distributor.creatorRewards(), address(creatorRewards));
        assertEq(distributor.deployer(), deployerRecipient);
        assertEq(distributor.buybackVault(), buybackVault);
        assertEq(distributor.operations(), operations);
        assertEq(distributor.holderRewards(), holderRewards);
        assertEq(distributor.baseFee(), 10_000);
        assertEq(distributor.additionalFee(), 0);
        assertEq(distributor.totalPoolFee(), 10_000);
        assertEq(uint8(distributor.creatorAllocationDestination()), 0);
        assertEq(uint8(distributor.additionalFeeDestination()), 0);
        assertEq(distributor.CREATOR_REWARDS_BPS(), 7000);
        assertEq(distributor.DEPLOYER_BPS(), 400);
        assertEq(distributor.BUYBACK_BPS(), 2000);
        assertEq(distributor.OPERATIONS_BPS(), 600);
    }

    function test_constructorRejectsZeroRecipients() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroRecipient.selector);
        new ScoopFeeDistributor(
            address(0),
            deployerRecipient,
            buybackVault,
            operations,
            holderRewards,
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
    }

    function test_constructorRequiresHolderWhenHoldersPath() public {
        vm.expectRevert(ScoopFeeDistributor.HolderRewardsRequired.selector);
        new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            address(0),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Holders,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
    }

    function test_constructorAllowsZeroHolderWhenUnused() public {
        ScoopFeeDistributor d = new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            address(0),
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
        assertEq(d.holderRewards(), address(0));
    }

    function test_zeroAdditionalPreservesBaseEconomicsETH() public {
        vm.deal(address(distributor), 10_000);
        vm.prank(caller);
        distributor.distributeETH();

        assertEq(creatorRewards.ethCredited(), 7000);
        assertEq(deployerRecipient.balance, 400);
        assertEq(buybackVault.balance, 2000);
        assertEq(operations.balance, 600);
        assertEq(holderVault.ethDeposited(), 0);
        assertEq(address(distributor).balance, 0);
    }

    function test_additionalToDeployerETH() public {
        ScoopFeeDistributor d = _dist(
            10_000, ScoopFeeTypes.CreatorAllocationDestination.Creator, ScoopFeeTypes.AdditionalFeeDestination.Deployer
        );
        // F=20000, basePart=half
        vm.deal(address(d), 10_000);
        d.distributeETH();

        // basePart=5000 → creator 3500, deployer 200, buyback 1000, ops 300
        // extraPart=5000 → deployer
        assertEq(creatorRewards.ethCredited(), 3500);
        assertEq(deployerRecipient.balance, 200 + 5000);
        assertEq(buybackVault.balance, 1000);
        assertEq(operations.balance, 300);
        assertEq(holderVault.ethDeposited(), 0);
    }

    function test_combinedCreatorLegsETH() public {
        ScoopFeeDistributor d = _dist(
            10_000, ScoopFeeTypes.CreatorAllocationDestination.Creator, ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
        vm.deal(address(d), 10_000);
        d.distributeETH();

        // base creator 3500 + extra 5000
        assertEq(creatorRewards.ethCredited(), 3500 + 5000);
        assertEq(deployerRecipient.balance, 200);
        assertEq(buybackVault.balance, 1000);
        assertEq(operations.balance, 300);
    }

    function test_combinedHoldersLegsETH() public {
        ScoopFeeDistributor d = _dist(
            20_000, ScoopFeeTypes.CreatorAllocationDestination.Holders, ScoopFeeTypes.AdditionalFeeDestination.Holders
        );
        vm.deal(address(d), 30_000);
        d.distributeETH();

        // F=30000, basePart=10000, extra=20000
        // holders base 7000 + extra 20000 = 27000
        assertEq(holderVault.ethDeposited(), 27_000);
        assertEq(creatorRewards.ethCredited(), 0);
        assertEq(deployerRecipient.balance, 400);
        assertEq(buybackVault.balance, 2000);
        assertEq(operations.balance, 600);
    }

    function test_tokenRoutesMatchETH() public {
        ScoopFeeDistributor d = _dist(
            10_000, ScoopFeeTypes.CreatorAllocationDestination.Holders, ScoopFeeTypes.AdditionalFeeDestination.Deployer
        );
        token.transfer(address(d), 10_000);
        d.distributeToken(address(token));

        // basePart=5000 → holders 3500, deployer 200, buyback 1000, ops 300; extra 5000 → deployer
        assertEq(holderVault.tokenDeposited(address(token)), 3500);
        assertEq(token.balanceOf(deployerRecipient), 5200);
        assertEq(token.balanceOf(buybackVault), 1000);
        assertEq(token.balanceOf(operations), 300);
        assertEq(token.balanceOf(address(d)), 0);
    }

    function test_distributeETH_revertsZeroBalance() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroBalance.selector);
        distributor.distributeETH();
    }

    function test_distributeToken_revertsZeroToken() public {
        vm.expectRevert(ScoopFeeDistributor.ZeroToken.selector);
        distributor.distributeToken(address(0));
    }

    function test_distributeETH_revertsOnRejectingRecipient() public {
        RejectETH rejector = new RejectETH();
        ScoopFeeDistributor hostile = new ScoopFeeDistributor(
            address(creatorRewards),
            address(rejector),
            buybackVault,
            operations,
            holderRewards,
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Creator
        );
        vm.deal(address(hostile), 10_000);
        vm.expectRevert(
            abi.encodeWithSelector(ScoopFeeDistributor.NativeTransferFailed.selector, address(rejector), 400)
        );
        hostile.distributeETH();
    }

    function test_destinationMatrix_conservation(uint8 allocRaw, uint8 destRaw, uint24 feeStep, uint256 balance)
        public
    {
        ScoopFeeTypes.CreatorAllocationDestination alloc =
            ScoopFeeTypes.CreatorAllocationDestination(bound(allocRaw, 0, 1));
        ScoopFeeTypes.AdditionalFeeDestination dest = ScoopFeeTypes.AdditionalFeeDestination(bound(destRaw, 0, 2));
        uint24 additionalFee = uint24(bound(feeStep, 0, 20) * 1000);
        balance = bound(balance, 1, 1e24);

        creatorRewards = new MockCreatorRewards();
        ScoopFeeDistributor d = new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            holderRewards,
            additionalFee,
            alloc,
            dest
        );

        uint256 depBefore = deployerRecipient.balance;
        uint256 buyBefore = buybackVault.balance;
        uint256 opsBefore = operations.balance;
        uint256 holdBefore = holderVault.ethDeposited();
        uint256 crBefore = creatorRewards.ethCredited();

        vm.deal(address(d), balance);
        d.distributeETH();

        uint256 out = (deployerRecipient.balance - depBefore) + (buybackVault.balance - buyBefore)
            + (operations.balance - opsBefore) + (holderVault.ethDeposited() - holdBefore)
            + (creatorRewards.ethCredited() - crBefore);
        assertEq(out, balance);
        assertEq(address(d).balance, 0);
    }

    function test_additionalFeeZero_ignoresDestination() public {
        ScoopFeeDistributor a = _dist(
            0, ScoopFeeTypes.CreatorAllocationDestination.Creator, ScoopFeeTypes.AdditionalFeeDestination.Holders
        );
        ScoopFeeDistributor b = _dist(
            0, ScoopFeeTypes.CreatorAllocationDestination.Creator, ScoopFeeTypes.AdditionalFeeDestination.Deployer
        );
        vm.deal(address(a), 10_000);
        vm.deal(address(b), 10_000);
        a.distributeETH();

        uint256 cr = creatorRewards.ethCredited();
        uint256 dep = deployerRecipient.balance;
        uint256 hold = holderVault.ethDeposited();

        // reset recipients via new mock path — compare equal splits on fresh distributor b
        creatorRewards = new MockCreatorRewards();
        deployerRecipient = makeAddr("deployer2");
        holderVault = new MockHolderRewards();
        holderRewards = address(holderVault);
        buybackVault = makeAddr("buyback2");
        operations = makeAddr("ops2");
        b = new ScoopFeeDistributor(
            address(creatorRewards),
            deployerRecipient,
            buybackVault,
            operations,
            holderRewards,
            0,
            ScoopFeeTypes.CreatorAllocationDestination.Creator,
            ScoopFeeTypes.AdditionalFeeDestination.Deployer
        );
        vm.deal(address(b), 10_000);
        b.distributeETH();

        assertEq(cr, 7000);
        assertEq(creatorRewards.ethCredited(), 7000);
        assertEq(dep, 400);
        assertEq(deployerRecipient.balance, 400);
        assertEq(hold, 0);
        assertEq(holderVault.ethDeposited(), 0);
    }
}
