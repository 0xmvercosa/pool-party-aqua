// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ICarryAdapter
/// @notice Frozen seam between PartyVault and a yield venue that holds the idle sleeve.
/// @dev FROZEN INTERFACE (rules ADP-R1..R5, epic POO-1057). Changing any signature here requires an
///      epic comment and Murilo's acknowledgement: the vault, the Aave adapter and the TypeScript
///      rails are all built against it in parallel. Aave v3 is the first implementation
///      (`AaveV3Adapter`, POO-1060); Compound and Morpho become sibling adapters with zero
///      vault-core changes.
interface ICarryAdapter {
    /// @notice Supplies `amount` of `token` into the venue on behalf of the owning vault.
    /// @dev Callable only by the owning vault (ADP-R1). The adapter PULLS the underlying with
    ///      `transferFrom(vault, adapter, amount)`, so the vault approves the adapter for exactly
    ///      `amount` immediately before calling and the allowance is fully consumed by the call.
    /// @param token Underlying token to supply.
    /// @param amount Underlying amount to supply.
    function park(address token, uint256 amount) external;

    /// @notice Withdraws exactly `amount` of `token` from the venue back to the owning vault.
    /// @dev Callable only by the owning vault (ADP-R1). Bubbles the venue's revert when the market
    ///      cannot serve the withdrawal (utilization spike). The vault treats that revert as
    ///      "temporarily illiquid", never as bad debt (ADP-R2).
    /// @param token Underlying token to withdraw.
    /// @param amount Exact underlying amount to withdraw.
    function unpark(address token, uint256 amount) external;

    /// @notice Interest-inclusive balance parked in the venue for `token`.
    /// @dev Grows every block so vault `totalAssets()` picks up carry continuously (ADP-R3).
    /// @param token Underlying token to query.
    /// @return Underlying amount currently redeemable from the venue.
    function parkedBalance(address token) external view returns (uint256);
}
