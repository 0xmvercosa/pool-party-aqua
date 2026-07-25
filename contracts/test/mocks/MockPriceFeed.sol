// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPriceFeed } from "../../src/interfaces/IPriceFeed.sol";

/// @notice Chainlink-shaped feed with a settable answer, for unit tests.
contract MockPriceFeed is IPriceFeed {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
