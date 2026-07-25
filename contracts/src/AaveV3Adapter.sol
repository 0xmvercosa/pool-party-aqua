// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAavePool, IAToken } from "./interfaces/IAaveV3.sol";
import { ICarryAdapter } from "./interfaces/ICarryAdapter.sol";

/// @title AaveV3Adapter
/// @notice Carry venue for the vault's idle USDC sleeve: supplies into Aave v3 and withdraws exact
///         amounts back, including from inside a fill transaction.
/// @dev Rules ADP-R1..R5 (`docs/01_BUSINESS_RULES.md`). Deliberately tiny and final:
///      - only the owning vault may `park` or `unpark` (ADP-R1)
///      - `unpark` withdraws EXACTLY the requested amount and bubbles Aave's revert when the
///        reserve cannot serve it. The vault reads that as "temporarily illiquid", never as bad
///        debt (ADP-R2)
///      - `parkedBalance` is the raw aToken balance, which is interest inclusive and rebases every
///        block, so vault NAV picks up carry continuously (ADP-R3)
///      - the adapter holds aTokens only; underlying is held for the few opcodes between the pull
///        and the supply (ADP-R4)
///      - no admin, no owner, no rescue, no upgrade path. Replacement means deploying a new vault
///        pointing at a new adapter (ADP-R5)
///
///      Single underlying by construction. `parkedBalance` answers 0 for any other token so vault
///      views stay total, while `park` and `unpark` reject it loudly.
///
///      Deployment order note: the adapter and the vault reference each other immutably, so the
///      deploy script predicts the vault address, constructs the adapter with it, and then asserts
///      `adapter.VAULT() == address(vault)`. A wrong prediction fails the deployment instead of
///      silently producing a mis-wired pair.
contract AaveV3Adapter is ICarryAdapter {
    using SafeERC20 for IERC20;

    /// @notice Aave v3 Pool.
    IAavePool public immutable POOL;

    /// @notice The only contract allowed to move this adapter's position.
    address public immutable VAULT;

    /// @notice The single underlying this adapter parks.
    address public immutable UNDERLYING;

    /// @notice Interest-bearing receipt token for {UNDERLYING}.
    IERC20 public immutable A_TOKEN;

    /// @notice Caller is not {VAULT}.
    error NotVault(address caller);
    /// @notice Token is not {UNDERLYING}.
    error UnsupportedToken(address token);
    /// @notice Aave returned a different amount than requested.
    error UnparkAmountMismatch(uint256 requested, uint256 withdrawn);
    /// @notice Constructor argument was the zero address.
    error ZeroAddress();
    /// @notice The aToken does not belong to the given pool and underlying.
    error ATokenMismatch();

    modifier onlyVault() {
        if (msg.sender != VAULT) revert NotVault(msg.sender);
        _;
    }

    /// @param pool Aave v3 Pool.
    /// @param vault The owning PartyVault.
    /// @param underlying Token this adapter parks, USDC for Active Reserve.
    /// @param aToken The pool's aToken for `underlying`.
    constructor(IAavePool pool, address vault, address underlying, IERC20 aToken) {
        if (
            address(pool) == address(0) || vault == address(0) || underlying == address(0)
                || address(aToken) == address(0)
        ) {
            revert ZeroAddress();
        }
        // Self-check the wiring at deploy time so a wrong aToken can never reach mainnet.
        if (
            IAToken(address(aToken)).UNDERLYING_ASSET_ADDRESS() != underlying
                || IAToken(address(aToken)).POOL() != address(pool)
        ) {
            revert ATokenMismatch();
        }

        POOL = pool;
        VAULT = vault;
        UNDERLYING = underlying;
        A_TOKEN = aToken;
    }

    /// @inheritdoc ICarryAdapter
    /// @dev Pulls the approved underlying from the vault and supplies it, so the adapter ends the
    ///      call holding aTokens and zero underlying (ADP-R4).
    function park(address token, uint256 amount) external onlyVault {
        if (token != UNDERLYING) revert UnsupportedToken(token);

        IERC20(token).safeTransferFrom(VAULT, address(this), amount);
        IERC20(token).forceApprove(address(POOL), amount);
        POOL.supply(token, amount, address(this), 0);
    }

    /// @inheritdoc ICarryAdapter
    /// @dev Withdraws straight to the vault, so no underlying is ever left sitting here. This is
    ///      the call the settlement hook makes inside a fill.
    function unpark(address token, uint256 amount) external onlyVault {
        if (token != UNDERLYING) revert UnsupportedToken(token);

        uint256 withdrawn = POOL.withdraw(token, amount, VAULT);
        if (withdrawn != amount) revert UnparkAmountMismatch(amount, withdrawn);
    }

    /// @inheritdoc ICarryAdapter
    function parkedBalance(address token) external view returns (uint256) {
        if (token != UNDERLYING) return 0;
        return A_TOKEN.balanceOf(address(this));
    }
}
