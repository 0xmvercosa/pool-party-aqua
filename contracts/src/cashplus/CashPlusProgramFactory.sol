// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { CashPlusTypes } from "./CashPlusTypes.sol";

/// @notice Sole canonical encoder, pinned to the generated AquaOpcodes table at SwapVM v1.0.2.
contract CashPlusProgramFactory {
    address public immutable VAULT;
    address public immutable PRICING;
    uint256 public constant CANONICAL_TRAITS = (1 << 254) | (1 << 252) | (1 << 251) | (1 << 250) | (1 << 249);
    uint256 public constant PROGRAM_VERSION = 1;

    error InvalidDeadline();

    constructor(address vault, address pricing) {
        VAULT = vault;
        PRICING = pricing;
    }

    function build(CashPlusTypes.ProgramParameters memory p) public view returns (CashPlusTypes.Order memory) {
        if (p.deadline > type(uint40).max) revert InvalidDeadline();
        // Empty hook data targets maker. All four hook slice offsets are zero. No custom receiver.
        bytes memory program = abi.encodePacked(
            uint8(13),
            uint8(5),
            uint40(p.deadline),
            uint8(32),
            uint8(28),
            PRICING,
            p.policyVersion,
            uint8(20),
            uint8(32),
            p.salt
        );
        return CashPlusTypes.Order(VAULT, CANONICAL_TRAITS, program);
    }

    function encode(CashPlusTypes.ProgramParameters calldata p) external view returns (bytes memory) {
        return abi.encode(build(p));
    }

    function hash(CashPlusTypes.ProgramParameters calldata p) external view returns (bytes32) {
        return keccak256(abi.encode(build(p)));
    }
}
