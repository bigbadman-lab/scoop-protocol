// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";

/**
 * @title ScoopLiquidityLocker
 * @notice Permanently holds a Uniswap v4 PositionManager NFT for a SCOOP market.
 * @dev Collects accrued LP fees via the canonical PositionManager and sends them
 *      directly to an immutable ScoopFeeDistributor. The locker does not custody fees,
 *      does not split BPS, and cannot transfer/burn the NFT or remove principal liquidity.
 *
 *      Permissionless `collectFees` only credits fees to `feeDistributor`.
 *      Distribution of those assets is triggered separately on the distributor.
 */
contract ScoopLiquidityLocker is ERC721Holder {
    error ZeroPositionManager();
    error ZeroFeeDistributor();
    error NotTokenOwner();

    IPositionManager public immutable positionManager;
    address public immutable feeDistributor;

    event FeesCollected(uint256 indexed tokenId, address indexed feeDistributor_);

    constructor(address positionManager_, address feeDistributor_) {
        if (positionManager_ == address(0)) revert ZeroPositionManager();
        if (feeDistributor_ == address(0)) revert ZeroFeeDistributor();
        positionManager = IPositionManager(positionManager_);
        feeDistributor = feeDistributor_;
    }

    /// @notice Collect accrued LP fees for a locked position into `feeDistributor`.
    /// @dev Official PositionManager pattern: DECREASE_LIQUIDITY(0) then TAKE_PAIR to feeDistributor.
    ///      Principal liquidity is unchanged. Anyone may call; destination is always `feeDistributor`.
    function collectFees(uint256 tokenId) external {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
            revert NotTokenOwner();
        }

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        // liquidity = 0 credits fees only; amount0Min/amount1Min = 0 (principal delta is zero)
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, feeDistributor);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        emit FeesCollected(tokenId, feeDistributor);
    }
}
