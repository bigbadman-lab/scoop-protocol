// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopFactory} from "../../../src/ScoopFactory.sol";
import {ScoopFeeDistributor} from "../../../src/ScoopFeeDistributor.sol";
import {ScoopCreatorRewards} from "../../../src/ScoopCreatorRewards.sol";
import {ScoopLiquidityLocker} from "../../../src/ScoopLiquidityLocker.sol";

/// @dev Always rejects native ETH.
contract RejectETHRecipient {
    receive() external payable {
        revert("reject-eth");
    }

    fallback() external payable {
        revert("reject-eth");
    }
}

/// @dev Accepts ETH then attempts to reenter Factory.launch.
contract ReenterFactoryOnReceive {
    ScoopFactory public factory;
    ScoopFactory.LaunchParams public params;
    bool public attacked;
    bool public reenterEnabled;

    function configure(ScoopFactory factory_, ScoopFactory.LaunchParams memory params_) external {
        factory = factory_;
        params = params_;
    }

    function enableReenter(bool enabled) external {
        reenterEnabled = enabled;
    }

    receive() external payable {
        if (!reenterEnabled || attacked) return;
        attacked = true;
        factory.launch{value: factory.LAUNCH_FEE()}(params);
    }
}

/// @dev Accepts ETH then reenters FeeDistributor.distributeETH.
contract ReenterDistributorOnReceive {
    ScoopFeeDistributor public distributor;
    bool public attacked;
    bool public reenterEnabled;

    function configure(ScoopFeeDistributor distributor_) external {
        distributor = distributor_;
    }

    function enableReenter(bool enabled) external {
        reenterEnabled = enabled;
    }

    receive() external payable {
        if (!reenterEnabled || attacked) return;
        attacked = true;
        distributor.distributeETH();
    }
}

/// @dev Accepts ETH then reenters CreatorRewards.claimETH.
contract ReenterClaimOnReceive {
    ScoopCreatorRewards public rewards;
    bytes32 public creatorId;
    address public candidate;
    bool public attacked;
    bool public reenterEnabled;

    function configure(ScoopCreatorRewards rewards_, bytes32 creatorId_, address candidate_) external {
        rewards = rewards_;
        creatorId = creatorId_;
        candidate = candidate_;
    }

    function enableReenter(bool enabled) external {
        reenterEnabled = enabled;
    }

    receive() external payable {
        if (!reenterEnabled || attacked) return;
        attacked = true;
        rewards.claimETH(creatorId, candidate);
    }
}

/// @dev Burns a large amount of gas on receive without reverting.
contract GasBombRecipient {
    uint256 public burnLoops;

    constructor(uint256 burnLoops_) {
        burnLoops = burnLoops_;
    }

    receive() external payable {
        uint256 x;
        for (uint256 i; i < burnLoops; ++i) {
            x = uint256(keccak256(abi.encode(x, i)));
        }
        if (x == type(uint256).max) revert();
    }
}

/// @dev Counts receives; used to prove destinations cannot be redirected.
contract CountingRecipient {
    uint256 public ethReceived;
    uint256 public receiveCount;

    receive() external payable {
        ethReceived += msg.value;
        receiveCount += 1;
    }
}

/// @dev Attempts locker.collectFees during ETH receive.
contract ReenterLockerOnReceive {
    ScoopLiquidityLocker public locker;
    uint256 public tokenId;
    bool public attacked;
    bool public reenterEnabled;

    function configure(ScoopLiquidityLocker locker_, uint256 tokenId_) external {
        locker = locker_;
        tokenId = tokenId_;
    }

    function enableReenter(bool enabled) external {
        reenterEnabled = enabled;
    }

    receive() external payable {
        if (!reenterEnabled || attacked) return;
        attacked = true;
        locker.collectFees(tokenId);
    }
}
