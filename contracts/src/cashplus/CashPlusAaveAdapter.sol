// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IAavePool, IAToken } from "../interfaces/IAaveV3.sol";

/// @notice Immutable, vault-only custody for one Aave reserve. No debt, arbitrary calls or rescue authority.
contract CashPlusAaveAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable VAULT;
    address public immutable UNDERLYING;
    IAavePool public immutable POOL;
    IERC20 public immutable A_TOKEN;

    error NotVault();
    error InvalidReserve();
    error AmountMismatch();

    event Supplied(uint256 amount);
    event Withdrawn(uint256 amount);
    event ReceiptTransferred(address indexed to, uint256 amount);

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault();
        _;
    }

    constructor(address vault, address underlying, address pool, address receipt) {
        if (
            vault == address(0) || underlying == address(0) || receipt.code.length == 0 || pool.code.length == 0
                || IAToken(receipt).UNDERLYING_ASSET_ADDRESS() != underlying || IAToken(receipt).POOL() != pool
        ) {
            revert InvalidReserve();
        }
        VAULT = vault;
        UNDERLYING = underlying;
        POOL = IAavePool(pool);
        A_TOKEN = IERC20(receipt);
    }

    function park(uint256 amount) external onlyVault nonReentrant {
        uint256 beforeBalance = IERC20(UNDERLYING).balanceOf(address(this));
        IERC20(UNDERLYING).safeTransferFrom(VAULT, address(this), amount);
        if (IERC20(UNDERLYING).balanceOf(address(this)) != beforeBalance + amount) revert AmountMismatch();
        IERC20(UNDERLYING).forceApprove(address(POOL), amount);
        POOL.supply(UNDERLYING, amount, address(this), 0);
        IERC20(UNDERLYING).forceApprove(address(POOL), 0);
        if (IERC20(UNDERLYING).balanceOf(address(this)) != beforeBalance) revert AmountMismatch();
        emit Supplied(amount);
    }

    function unpark(uint256 amount) external onlyVault nonReentrant {
        uint256 beforeBalance = IERC20(UNDERLYING).balanceOf(VAULT);
        if (
            POOL.withdraw(UNDERLYING, amount, VAULT) != amount
                || IERC20(UNDERLYING).balanceOf(VAULT) != beforeBalance + amount
        ) revert AmountMismatch();
        emit Withdrawn(amount);
    }

    function transferReceipt(address to, uint256 amount, uint256 minimum) external onlyVault nonReentrant {
        uint256 beforeReceived = A_TOKEN.balanceOf(to);
        A_TOKEN.safeTransfer(to, amount);
        if (A_TOKEN.balanceOf(to) < beforeReceived + minimum) revert AmountMismatch();
        emit ReceiptTransferred(to, amount);
    }
    /// @notice Returns donated idle underlying to its vault; cannot direct funds to an operator.

    function returnIdle(uint256 amount) external onlyVault nonReentrant {
        IERC20(UNDERLYING).safeTransfer(VAULT, amount);
    }

    function parkedBalance() external view returns (uint256) {
        return A_TOKEN.balanceOf(address(this));
    }

    function idleBalance() external view returns (uint256) {
        return IERC20(UNDERLYING).balanceOf(address(this));
    }

    function lendingIndex() external view returns (uint256 index) {
        (bool ok, bytes memory data) =
            address(POOL).staticcall(abi.encodeWithSignature("getReserveNormalizedIncome(address)", UNDERLYING));
        if (ok && data.length == 32) index = abi.decode(data, (uint256));
    }
}
