// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ICashPlusInitialize {
    function INITIALIZER() external view returns (address);
    function USDC() external view returns (address);
    function initialize(address sponsor, uint256 seed) external;
}
/// @notice Atomic CREATE2 deployment and locked seeding; caller supplies reviewed vault creation code + constructor args.
/// @dev Never controls an existing vault. Caller-bound salt prevents another sender occupying its deployment.

contract CashPlusDeploymentFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error DeploymentFailed();
    error BindingMismatch();
    error SeedMismatch();

    event VaultDeployed(address indexed vault, address indexed sponsor, bytes32 initCodeHash, uint256 seed);

    function deploy(bytes calldata initCode, address usdc, uint256 seed, bytes32 salt)
        external
        nonReentrant
        returns (address vault)
    {
        bytes32 boundSalt = keccak256(abi.encode(msg.sender, salt));
        bytes memory code = initCode;
        assembly ("memory-safe") {
            vault := create2(0, add(code, 32), mload(code), boundSalt)
        }
        if (vault == address(0)) revert DeploymentFailed();
        if (ICashPlusInitialize(vault).INITIALIZER() != address(this) || ICashPlusInitialize(vault).USDC() != usdc) {
            revert BindingMismatch();
        }
        if (IERC20(usdc).balanceOf(vault) != 0) revert SeedMismatch();
        IERC20(usdc).safeTransferFrom(msg.sender, vault, seed);
        if (IERC20(usdc).balanceOf(vault) != seed) revert SeedMismatch();
        ICashPlusInitialize(vault).initialize(msg.sender, seed);
        emit VaultDeployed(vault, msg.sender, keccak256(initCode), seed);
    }

    function predict(address sponsor, bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), keccak256(abi.encode(sponsor, salt)), initCodeHash
                        )
                    )
                )
            )
        );
    }
}
