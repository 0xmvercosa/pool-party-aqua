// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SwapQuery, SwapRegisters, ICashPlusQuote } from "./CashPlusTypes.sol";

/// @notice Deterministic view implementation of both pinned Extruction ABI variants; consumes no taker bytes.
contract CashPlusPricing {
    address public immutable VAULT;
    address public immutable ROUTER;

    error InvalidContext();
    error ExactOutputUnsupported();
    error InsufficientVirtualLiquidity();

    constructor(address vault, address router) {
        VAULT = vault;
        ROUTER = router;
    }

    function extruction(
        bool,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata
    ) external view returns (uint256, uint256, SwapRegisters memory updatedSwap) {
        if (
            msg.sender != ROUTER || query.maker != VAULT || args.length != 8 || swap.amountNetPulled != 0
                || swap.amountOut != 0
        ) {
            if (!query.isExactIn) revert ExactOutputUnsupported();
            revert InvalidContext();
        }
        if (!query.isExactIn) revert ExactOutputUnsupported();
        updatedSwap = swap;
        updatedSwap.amountOut = ICashPlusQuote(VAULT).quoteTrade(
            query.orderHash, query.taker, query.tokenIn, query.tokenOut, swap.amountIn, uint64(bytes8(args))
        );
        if (updatedSwap.amountOut > swap.balanceOut) revert InsufficientVirtualLiquidity();
        return (nextPC, 0, updatedSwap);
    }
}
