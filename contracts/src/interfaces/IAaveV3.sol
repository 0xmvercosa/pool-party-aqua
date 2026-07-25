// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAavePool
/// @notice Subset of the Aave v3 `Pool` the carry adapter calls.
/// @dev Arbitrum One Pool: `0x794a61358D6845594F94dc1DB02A252b5b4814aD` (verified on chain against
///      the aToken's own `POOL()` getter, see `docs/VERIFIED.md`).
interface IAavePool {
    /// @notice Supplies `amount` of `asset` and mints aTokens to `onBehalfOf`.
    /// @param asset Underlying token.
    /// @param amount Underlying amount.
    /// @param onBehalfOf Receiver of the aTokens.
    /// @param referralCode Unused, pass 0.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Burns aTokens and sends the underlying to `to`.
    /// @dev Reverts when the reserve cannot serve the withdrawal, which is exactly the
    ///      "temporarily illiquid" signal the vault relies on (ADP-R2).
    /// @param asset Underlying token.
    /// @param amount Underlying amount, or `type(uint256).max` for the full balance.
    /// @param to Receiver of the underlying.
    /// @return The amount actually withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title IAToken
/// @notice The two aToken getters the adapter uses to self-check its wiring at deploy time.
interface IAToken {
    /// @notice Underlying token this aToken represents.
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);

    /// @notice Pool that mints and burns this aToken.
    function POOL() external view returns (address);
}
