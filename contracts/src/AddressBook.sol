// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title AddressBook
/// @notice Every canonical Arbitrum One address Active Reserve touches, in ONE place.
/// @dev Mirrors `docs/VERIFIED.md`. A hardcoded address anywhere else in this repository is a
///      review-blocking defect (coordination rule 3). Each entry states how it was verified,
///      because the upstream READMEs document a dead generation of Aqua.
library AddressBook {
    /// @notice Arbitrum One.
    uint256 internal constant CHAIN_ID = 42_161;

    /// @notice Circle native USDC. `symbol()` reads "USDC".
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice Wrapped ether, the second token every band registers.
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @notice Aqua registry, GENERATION 2, the live one.
    /// @dev Generation 1 (`0x499943e74fb0ce105688beee8ef2abec5d936d31`) is dead and is what the
    ///      upstream READMEs document. Gen 2 is the pair referenced by the pinned SDKs and is the
    ///      registry the live ship tx `0xa966fc93...` targets.
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    /// @notice AquaSwapVMRouter, GENERATION 2. Its `AQUA()` getter points at {AQUA}.
    address internal constant AQUA_SWAP_VM_ROUTER = 0x1111113Db0e0ef9D0E3A50d5f094a3a57a26C0DE;

    /// @notice Aave v3 Pool. Matches the aToken's own `POOL()` getter.
    address internal constant AAVE_V3_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    /// @notice aArbUSDCn. Its `UNDERLYING_ASSET_ADDRESS()` returns {USDC}.
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    /// @notice Chainlink ETH/USD, 8 decimals. Median update gap 121s over a measured 24h.
    address internal constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
}
