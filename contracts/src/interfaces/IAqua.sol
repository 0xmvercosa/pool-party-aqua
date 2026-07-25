// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAqua
/// @notice Subset of the 1inch Aqua shared-liquidity registry that PartyVault calls as a maker.
/// @dev Declaration only, transcribed from the upstream `IAqua` at `1inch/aqua` tag `v1.0.0`
///      (`src/interfaces/IAqua.sol`), which is the generation deployed at
///      `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` on Arbitrum (`docs/VERIFIED.md`, gen 2).
///      Upstream Aqua is source-available under the Degensoft Aqua Source 1.1 license and is NOT
///      vendored into this repository; only the ABI shape we consume is restated here.
///      Attribution: Aqua, (c) Degensoft Ltd 2025.
///
///      Facts that shape the vault and that were read off that source, not guessed:
///      - `ship` returns `keccak256(strategy)` as the strategy hash (PRG-R9).
///      - `ship` reverts with `StrategiesMustBeImmutable` when a hash was already used, and a docked
///        strategy keeps a sentinel token count, so a docked hash is dead forever (PRG-R10).
///      - `dock` requires the token array to cover EVERY token registered by the ship, otherwise it
///        reverts with `DockingShouldCloseAllTokens`. The vault therefore stores the shipped token
///        list per strategy hash.
///      - `pull` executes `safeTransferFrom(maker, to, amount)`, so the maker (this vault) must hold
///        an ERC-20 allowance for the Aqua registry itself, not for the router.
interface IAqua {
    /// @notice Registers a strategy for `app` and sets its initial virtual balances.
    /// @param app The SwapVM router that is allowed to pull against this strategy.
    /// @param strategy ABI-encoded order bytes; the program lives in the last slice of `order.data`.
    /// @param tokens Every token the strategy quotes, including sides shipped at amount 0.
    /// @param amounts Initial virtual balance per token, index-aligned with `tokens`.
    /// @return strategyHash `keccak256(strategy)`.
    function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts)
        external
        returns (bytes32 strategyHash);

    /// @notice Deactivates a strategy by zeroing the virtual balance of every token it registered.
    /// @param app The SwapVM router the strategy was shipped to.
    /// @param strategyHash The hash returned by `ship`.
    /// @param tokens The complete token list the strategy was shipped with.
    function dock(address app, bytes32 strategyHash, address[] calldata tokens) external;

    /// @notice Current virtual balance of one token inside one strategy.
    /// @param maker The maker that shipped the strategy.
    /// @param app The SwapVM router the strategy was shipped to.
    /// @param strategyHash The hash returned by `ship`.
    /// @param token Token to read.
    /// @return balance Remaining virtual balance.
    /// @return tokensCount Number of tokens in the strategy, or the docked sentinel.
    function rawBalances(address maker, address app, bytes32 strategyHash, address token)
        external
        view
        returns (uint248 balance, uint8 tokensCount);
}
