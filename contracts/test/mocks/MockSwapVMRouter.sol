// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMakerHooks } from "../../src/interfaces/IMakerHooks.sol";
import { MockAqua } from "./MockAqua.sol";

/// @notice Stub SwapVM router that reproduces the settlement ordering of upstream
///         swap-vm tag v1.0.1, `src/SwapVM.sol` `_transferOut` / `_transferIn`, without the VM.
/// @dev Ordering that matters and is asserted by the vault suite: the maker's `preTransferOut` hook
///      fires FIRST, then `AQUA.pull` moves `tokenOut` out of the maker, then the taker's `tokenIn`
///      is pushed back to the maker. All three happen in one transaction, which is what makes the
///      Aave withdrawal "just in time".
contract MockSwapVMRouter {
    using SafeERC20 for IERC20;

    MockAqua public immutable AQUA;

    constructor(MockAqua aqua) {
        AQUA = aqua;
    }

    /// @notice Settles one fill against a maker, hook first, exactly like upstream.
    /// @param maker Maker being filled (the vault).
    /// @param strategyHash Strategy the fill runs against.
    /// @param tokenIn Token the taker gives.
    /// @param tokenOut Token the maker gives.
    /// @param amountIn Amount the taker gives.
    /// @param amountOut Amount the maker gives.
    function settle(
        address maker,
        bytes32 strategyHash,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) external {
        IMakerHooks(maker).preTransferOut(
            maker, msg.sender, tokenIn, tokenOut, amountIn, amountOut, strategyHash, "", ""
        );

        AQUA.pull(maker, strategyHash, tokenOut, amountOut, msg.sender);

        IERC20(tokenIn).safeTransferFrom(msg.sender, maker, amountIn);
    }

    /// @notice Calls only the maker hook, for gating tests.
    function callHookOnly(address maker, address hookMaker, address tokenOut, uint256 amountOut) external {
        IMakerHooks(maker).preTransferOut(hookMaker, msg.sender, address(0), tokenOut, 0, amountOut, bytes32(0), "", "");
    }
}
