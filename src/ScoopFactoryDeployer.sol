// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoopCreatorRewards} from "./ScoopCreatorRewards.sol";
import {ScoopFactory} from "./ScoopFactory.sol";

/**
 * @title ScoopFactoryDeployer
 * @notice Atomically deploys ScoopCreatorRewards + ScoopFactory with a permanent registrar link.
 * @dev ScoopCreatorRewards stores an immutable `sourceRegistrar` that must equal ScoopFactory.
 *      Because each constructor embeds the other's address, CREATE2 cannot resolve the cycle.
 *
 *      This deployer breaks the cycle with CREATE address prediction:
 *      1. Predict the address of the second contract created by this deployer (the Factory)
 *      2. Deploy ScoopCreatorRewards(registry, predictedFactory)  // CREATE nonce 1
 *      3. Deploy ScoopFactory(..., rewards, ...)                  // CREATE nonce 2
 *      4. Require address(factory) == predictedFactory
 *
 *      Prediction uses CREATE (deployer + nonce), not CREATE2 init-code hash. Adding constructor
 *      arguments (e.g. universalRouter) does not change the predicted Factory address.
 *
 *      Result: CreatorRewards.sourceRegistrar == Factory with no mutable registrar setters.
 */
contract ScoopFactoryDeployer {
    error UnexpectedFactoryAddress(address expected, address actual);

    ScoopCreatorRewards public immutable creatorRewards;
    ScoopFactory public immutable factory;

    event ProtocolDeployed(address indexed factory, address indexed creatorRewards);

    constructor(
        address creatorRegistry_,
        address poolManager_,
        address positionManager_,
        address permit2_,
        address universalRouter_,
        address tokenDeployer_,
        address launchDeployer_,
        address buybackVault_,
        address operations_
    ) {
        // Contract accounts start at nonce 1. First `new` uses 1; Factory is the second `new` (nonce 2).
        address predictedFactory = _computeCreateAddress(address(this), 2);

        ScoopCreatorRewards rewards_ = new ScoopCreatorRewards(creatorRegistry_, predictedFactory);
        ScoopFactory factory_ = new ScoopFactory(
            poolManager_,
            positionManager_,
            permit2_,
            universalRouter_,
            tokenDeployer_,
            launchDeployer_,
            address(rewards_),
            buybackVault_,
            operations_
        );

        if (address(factory_) != predictedFactory) {
            revert UnexpectedFactoryAddress(predictedFactory, address(factory_));
        }

        creatorRewards = rewards_;
        factory = factory_;

        emit ProtocolDeployed(address(factory_), address(rewards_));
    }

    /// @dev CREATE address for deployer+nonce where 1 <= nonce <= 0x7f.
    function _computeCreateAddress(address deployer, uint256 nonce) private pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce))))))
        );
    }
}
