// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICarryAdapter } from "../../src/interfaces/ICarryAdapter.sol";
import { IMakerHooks } from "../../src/interfaces/IMakerHooks.sol";

/// @notice The smallest possible maker that exercises the adapter's just-in-time path, used by the
///         Arbitrum fork suite so the adapter is proven independently of PartyVault's accounting.
/// @dev Deliberately dumb: a hot buffer, a carry adapter, and the one hook.
contract StubMakerVault is IMakerHooks {
    using SafeERC20 for IERC20;

    address public immutable UNDERLYING;

    ICarryAdapter public adapter;
    address public router;

    error NotRouter();
    error AlreadyInitialized();

    constructor(address underlying) {
        UNDERLYING = underlying;
    }

    /// @notice Binds the adapter and the router, and grants the router the pull allowance the way
    ///         the real vault grants it to the Aqua registry.
    function initialize(ICarryAdapter adapter_, address router_) external {
        if (address(adapter) != address(0)) revert AlreadyInitialized();
        adapter = adapter_;
        router = router_;
        IERC20(UNDERLYING).forceApprove(router_, type(uint256).max);
    }

    function park(uint256 amount) external {
        IERC20(UNDERLYING).forceApprove(address(adapter), amount);
        adapter.park(UNDERLYING, amount);
    }

    /// @inheritdoc IMakerHooks
    function preTransferOut(
        address,
        address,
        address,
        address tokenOut,
        uint256,
        uint256 amountOut,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external {
        if (msg.sender != router) revert NotRouter();
        uint256 buffer = IERC20(tokenOut).balanceOf(address(this));
        if (buffer < amountOut) adapter.unpark(tokenOut, amountOut - buffer);
    }
}

/// @notice Minimal stand-in for the settlement leg: fires the maker hook, then moves the maker's
///         tokens with `transferFrom`, which is exactly what `AQUA.pull` does. One transaction.
contract StubJitRouter {
    using SafeERC20 for IERC20;

    function settle(IMakerHooks maker, address underlying, address taker, uint256 amountOut) external {
        maker.preTransferOut(address(maker), taker, address(0), underlying, 0, amountOut, bytes32(0), "", "");
        IERC20(underlying).safeTransferFrom(address(maker), taker, amountOut);
    }
}
