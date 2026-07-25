// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IMakerHooks (pre-transfer-out subset)
/// @notice The maker-side settlement hook PartyVault answers so it can withdraw from Aave inside the
///         fill transaction (rule VLT-R9, the "just in time" path).
/// @dev Declaration only, transcribed from the upstream `IMakerHooks` at `1inch/swap-vm` tag
///      `v1.0.1` (`src/interfaces/IMakerHooks.sol`). Upstream SwapVM is source-available under the
///      Degensoft SwapVM 1.1 license and is NOT vendored here. Attribution: (c) Degensoft Ltd 2025.
///
///      Upstream declares four hooks (`preTransferIn`, `postTransferIn`, `preTransferOut`,
///      `postTransferOut`). We wire only `preTransferOut`, so only that one is restated. The router
///      calls a hook exclusively when the corresponding maker-traits flag is set on the order, and
///      when the hook has no explicit target it calls the maker itself, which is this vault.
///
///      Call site in upstream `src/SwapVM.sol` `_transferOut`: the hook fires immediately BEFORE
///      `AQUA.pull` moves `tokenOut` out of the maker, and it receives the settled `amountOut`. That
///      is what makes an exact-amount Aave withdrawal possible inside one transaction.
///
///      IMPORTANT for the program compiler (Track B): the argument list is fixed by upstream, so the
///      hook payload our order carries is only the `makerData` blob, and the selector the router
///      invokes is `preTransferOut(address,address,address,address,uint256,uint256,bytes32,bytes,bytes)`.
interface IMakerHooks {
    /// @notice Called before `tokenOut` leaves the maker.
    /// @param maker The maker of the order being settled.
    /// @param taker The address executing the swap.
    /// @param tokenIn Token flowing into the maker.
    /// @param tokenOut Token flowing out of the maker.
    /// @param amountIn Settled input amount.
    /// @param amountOut Settled output amount, the amount about to be pulled from the maker.
    /// @param orderHash Strategy hash of the order being settled.
    /// @param makerData Hook payload the maker embedded in the order at ship time.
    /// @param takerData Hook payload supplied by the taker at execution time. Taker controlled, so
    ///        implementations must never trust it.
    function preTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external;
}
