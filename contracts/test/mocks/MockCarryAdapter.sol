// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ICarryAdapter } from "../../src/interfaces/ICarryAdapter.sol";

/// @notice Stub {ICarryAdapter} for vault unit tests: holds the underlying instead of aTokens and
///         accrues yield only when a test asks it to.
/// @dev The real Aave v3 adapter and its fork tests live in POO-1060. This stub exists so the vault
///      suite can exercise park, unpark, the redemption liquidity gate and the just-in-time hook
///      without a fork, and so it can simulate the utilization-stress revert (ADP-R2).
contract MockCarryAdapter is ICarryAdapter {
    using SafeERC20 for IERC20;

    address public immutable vault;

    mapping(address token => uint256 amount) public parked;

    /// @notice When true, {unpark} reverts the way Aave does under utilization stress.
    bool public unparkShouldFail;

    error NotVault(address caller);
    error UnparkFailed();

    constructor(address vault_) {
        vault = vault_;
    }

    function setUnparkShouldFail(bool value) external {
        unparkShouldFail = value;
    }

    /// @notice Simulates carry accrual: mints nothing, the test funds the adapter and calls this.
    function accrue(address token, uint256 amount) external {
        parked[token] += amount;
    }

    /// @inheritdoc ICarryAdapter
    function park(address token, uint256 amount) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        IERC20(token).safeTransferFrom(vault, address(this), amount);
        parked[token] += amount;
    }

    /// @inheritdoc ICarryAdapter
    function unpark(address token, uint256 amount) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (unparkShouldFail) revert UnparkFailed();
        parked[token] -= amount;
        IERC20(token).safeTransfer(vault, amount);
    }

    /// @inheritdoc ICarryAdapter
    function parkedBalance(address token) external view returns (uint256) {
        return parked[token];
    }
}
