// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

/**
 * @title ScoopHolderRewardsMerkle
 * @notice Test helper matching ScoopHolderRewards leaf + OpenZeppelin commutative Merkle trees.
 * @dev Leaf = keccak256(bytes.concat(keccak256(abi.encode(chainid, vault, roundId, asset, account, amount))))
 *      Node = commutativeKeccak256(a, b)  (sorted pair hash; same as OZ MerkleProof)
 */
library ScoopHolderRewardsMerkle {
    struct Entitlement {
        address account;
        uint256 amount;
    }

    function leaf(uint256 chainId, address vault, uint64 roundId, address asset, address account, uint256 amount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(chainId, vault, roundId, asset, account, amount))));
    }

    function merkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty");
        uint256 n = leaves.length;
        bytes32[] memory layer = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            layer[i] = leaves[i];
        }
        while (n > 1) {
            uint256 nextN = (n + 1) / 2;
            bytes32[] memory next = new bytes32[](nextN);
            for (uint256 i; i < nextN; ++i) {
                uint256 left = i * 2;
                if (left + 1 < n) {
                    next[i] = Hashes.commutativeKeccak256(layer[left], layer[left + 1]);
                } else {
                    next[i] = layer[left];
                }
            }
            layer = next;
            n = nextN;
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        require(index < leaves.length, "index");
        // Collect siblings along the path.
        // Worst-case depth ~ log2(n)+1; allocate generously.
        bytes32[] memory tmp = new bytes32[](64);
        uint256 depth;
        uint256 n = leaves.length;
        bytes32[] memory layer = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            layer[i] = leaves[i];
        }
        uint256 idx = index;
        while (n > 1) {
            uint256 sibling = idx % 2 == 0 ? idx + 1 : idx - 1;
            if (sibling < n) {
                tmp[depth++] = layer[sibling];
            }
            uint256 nextN = (n + 1) / 2;
            bytes32[] memory next = new bytes32[](nextN);
            for (uint256 i; i < nextN; ++i) {
                uint256 left = i * 2;
                if (left + 1 < n) {
                    next[i] = Hashes.commutativeKeccak256(layer[left], layer[left + 1]);
                } else {
                    next[i] = layer[left];
                }
            }
            layer = next;
            n = nextN;
            idx /= 2;
        }
        bytes32[] memory out = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }
}
