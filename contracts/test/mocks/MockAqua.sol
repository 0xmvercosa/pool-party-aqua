// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAqua } from "../../src/interfaces/IAqua.sol";

/// @notice Behavioral stand-in for the 1inch Aqua registry, written from scratch against the
///         observable semantics of upstream aqua tag v1.0.0, `src/Aqua.sol`.
/// @dev Upstream is source-available under a Degensoft license and is deliberately NOT vendored
///      into this repository, so this mock reimplements the parts the vault depends on:
///      - `strategyHash = keccak256(strategy)`
///      - a strategy is immutable: shipping onto a used hash reverts
///      - dock requires the COMPLETE shipped token list, otherwise it reverts
///      - a docked strategy keeps the `0xff` sentinel token count, so its hash is dead forever
///      - `pull` moves tokens with `transferFrom(maker, to, amount)` and only the app may call it
///      The real registry is exercised for real on an Arbitrum fork in the adapter suite (POO-1060)
///      and on mainnet at launch (POO-1062).
contract MockAqua is IAqua {
    using SafeERC20 for IERC20;

    uint8 private constant _DOCKED = 0xff;

    struct Balance {
        uint248 amount;
        uint8 tokensCount;
    }

    mapping(address maker => mapping(address app => mapping(bytes32 hash => mapping(address token => Balance)))) private
        _balances;

    error StrategiesMustBeImmutable(address app, bytes32 strategyHash);
    error DockingShouldCloseAllTokens(address app, bytes32 strategyHash);

    event Shipped(address maker, address app, bytes32 strategyHash, bytes strategy);
    event Docked(address maker, address app, bytes32 strategyHash);
    event Pulled(address maker, address app, bytes32 strategyHash, address token, uint256 amount);

    function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts)
        external
        returns (bytes32 strategyHash)
    {
        strategyHash = keccak256(strategy);
        uint8 tokensCount = uint8(tokens.length);

        emit Shipped(msg.sender, app, strategyHash, strategy);
        for (uint256 i; i < tokens.length; ++i) {
            Balance storage balance = _balances[msg.sender][app][strategyHash][tokens[i]];
            if (balance.tokensCount != 0) revert StrategiesMustBeImmutable(app, strategyHash);
            balance.amount = uint248(amounts[i]);
            balance.tokensCount = tokensCount;
        }
    }

    function dock(address app, bytes32 strategyHash, address[] calldata tokens) external {
        for (uint256 i; i < tokens.length; ++i) {
            Balance storage balance = _balances[msg.sender][app][strategyHash][tokens[i]];
            if (balance.tokensCount != tokens.length) revert DockingShouldCloseAllTokens(app, strategyHash);
            balance.amount = 0;
            balance.tokensCount = _DOCKED;
        }
        emit Docked(msg.sender, app, strategyHash);
    }

    function rawBalances(address maker, address app, bytes32 strategyHash, address token)
        external
        view
        returns (uint248 balance, uint8 tokensCount)
    {
        Balance storage entry = _balances[maker][app][strategyHash][token];
        return (entry.amount, entry.tokensCount);
    }

    /// @notice Mirrors the upstream pull: only the app calls it, and it moves the maker's tokens.
    function pull(address maker, bytes32 strategyHash, address token, uint256 amount, address to) external {
        Balance storage balance = _balances[maker][msg.sender][strategyHash][token];
        balance.amount = uint248(balance.amount - amount);
        IERC20(token).safeTransferFrom(maker, to, amount);
        emit Pulled(maker, msg.sender, strategyHash, token, amount);
    }
}
