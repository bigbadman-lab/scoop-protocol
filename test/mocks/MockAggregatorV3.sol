// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/**
 * @title MockAggregatorV3
 * @notice TEST-ONLY controllable AggregatorV3 for ScoopPriceOracle unit tests.
 */
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 private _decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        roundId = 1;
        answeredInRound = 1;
        answer = 1e8;
        startedAt = 1;
        updatedAt = 1;
    }

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
