// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceFeed
/// @notice Subset of the Chainlink `AggregatorV3Interface` the vault reads to value its WETH leg.
/// @dev Arbitrum ETH/USD feed: `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612`, 8 decimals
///      (`docs/VERIFIED.md`). Measured over 24h: 360 updates, median gap 121s, max gap 29.5 min.
interface IPriceFeed {
    /// @notice Number of decimals the answer carries.
    function decimals() external view returns (uint8);

    /// @notice Latest round data.
    /// @return roundId Round identifier.
    /// @return answer Price, in `decimals()` fixed point.
    /// @return startedAt Round start timestamp.
    /// @return updatedAt Timestamp of the answer.
    /// @return answeredInRound Round the answer was computed in.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
