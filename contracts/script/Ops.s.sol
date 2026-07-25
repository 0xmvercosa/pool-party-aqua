// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddressBook } from "../src/AddressBook.sol";
import { PartyVault } from "../src/PartyVault.sol";
import { IAqua } from "../src/interfaces/IAqua.sol";
import { IPriceFeed } from "../src/interfaces/IPriceFeed.sol";

/// @dev Shared plumbing for the launch-day scripts. Every one of them reads the vault address from
///      the environment so no address is ever hardcoded outside `AddressBook`.
abstract contract OpsBase is Script {
    PartyVault internal vault;

    function _loadVault() internal {
        require(block.chainid == AddressBook.CHAIN_ID, "Ops: not Arbitrum One");
        vault = PartyVault(vm.envAddress("VAULT_ADDRESS"));
    }
}

/// @title SeedAndPark
/// @notice Manager seed (VLT-R2) followed by parking the sleeve, in one signed run.
/// @dev POO-1062 R3. `SEED_USDC` is in USDC units (6 decimals); `BUFFER_BPS` is the share of the
///      seed to leave hot, 500 = 5 percent per D5.
contract SeedAndPark is OpsBase {
    function run() external {
        _loadVault();
        uint256 seed = vm.envUint("SEED_USDC");
        uint256 bufferBps = vm.envOr("BUFFER_BPS", uint256(500));
        require(seed > 0, "Seed: zero");
        require(bufferBps <= 10_000, "Seed: bad buffer");

        uint256 toPark = (seed * (10_000 - bufferBps)) / 10_000;

        vm.startBroadcast();
        IERC20(AddressBook.USDC).approve(address(vault), seed);
        uint256 shares = vault.deposit(seed);
        if (toPark > 0) vault.parkUsdc(toPark);
        vm.stopBroadcast();

        console.log("seeded (USDC):", seed);
        console.log("shares minted:", shares);
        console.log("parked (USDC):", toPark);
        console.log("hot buffer (USDC):", seed - toPark);
    }
}

/// @title ShipBand
/// @notice Ships one compiler-built band through the vault.
/// @dev POO-1062 R4. `ORDER_BYTES` is the ABI-encoded Order struct produced by the Track B compiler
///      (PRG-R9); the vault forces the Aqua app to the canonical router and records the token list
///      so the later dock replays it in full.
contract ShipBand is OpsBase {
    function run() external {
        _loadVault();
        bytes memory order = vm.envBytes("ORDER_BYTES");
        uint256 usdcAmount = vm.envUint("SHIP_USDC");
        require(order.length > 0, "Ship: empty order");

        address[] memory tokens = new address[](2);
        tokens[0] = AddressBook.USDC;
        tokens[1] = AddressBook.WETH;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0; // PRG-R2: both tokens registered, the empty side at 0

        vm.startBroadcast();
        bytes32 strategyHash = vault.execShip(order, tokens, amounts);
        vm.stopBroadcast();

        console.log("shipped USDC:", usdcAmount);
        console.log("strategyHash:");
        console.logBytes32(strategyHash);
        console.log("Record it in RUNBOOK.md and docs/VERIFIED.md.");
    }
}

/// @title Smoke
/// @notice Read-only post-launch state dump (POO-1062 R6, vault side).
/// @dev Pair it with Track B's `quote()` at three sizes. Nothing here broadcasts, so it is safe to
///      run at any time, including mid-demo.
contract Smoke is OpsBase {
    function run() external {
        _loadVault();

        uint256 buffer = IERC20(AddressBook.USDC).balanceOf(address(vault));
        uint256 parked = vault.ADAPTER().parkedBalance(AddressBook.USDC);
        uint256 wethHeld = IERC20(AddressBook.WETH).balanceOf(address(vault));
        (, int256 ethUsd,,,) = IPriceFeed(AddressBook.CHAINLINK_ETH_USD).latestRoundData();

        console.log("== PartyVault ==", address(vault));
        console.log("owner:            ", vault.OWNER());
        console.log("seeded:           ", vault.seeded());
        console.log("maxTvl (USDC):    ", vault.maxTvl());
        console.log("totalAssets (USDC):", vault.totalAssets());
        console.log("totalShares:      ", vault.totalShares());
        console.log("hot buffer (USDC):", buffer);
        console.log("parked in Aave:   ", parked);
        console.log("liquid USDC:      ", vault.liquidUsdc());
        console.log("WETH held (wei):  ", wethHeld);
        console.log("ETH/USD (8dp):    ", uint256(ethUsd));
        console.log("Aqua allowance:   ", IERC20(AddressBook.USDC).allowance(address(vault), AddressBook.AQUA));

        bytes32[] memory hashes = vault.activeStrategies();
        console.log("active strategies:", hashes.length);
        for (uint256 i; i < hashes.length; ++i) {
            (uint248 usdcLeft,) =
                IAqua(AddressBook.AQUA).rawBalances(address(vault), vault.ROUTER(), hashes[i], AddressBook.USDC);
            (uint248 wethLeft,) =
                IAqua(AddressBook.AQUA).rawBalances(address(vault), vault.ROUTER(), hashes[i], AddressBook.WETH);
            console.log("--- strategy", i);
            console.logBytes32(hashes[i]);
            console.log("    USDC virtual balance:", uint256(usdcLeft));
            console.log("    WETH virtual balance:", uint256(wethLeft));
        }
    }
}

/// @title EmergencyStop
/// @notice Docks every strategy and revokes the Aqua allowances, making the vault inert.
/// @dev POO-1062 R5, VLT-R11. Docking is accounting only, so it cannot fail for lack of liquidity.
///      Revoking the allowance is the belt to that braces: even a strategy that somehow stayed
///      active could not move a token afterwards. Investor redemption is unaffected.
contract EmergencyStop is OpsBase {
    function run() external {
        _loadVault();

        vm.startBroadcast();
        vault.dockAll();
        vault.revokeAquaApproval(IERC20(AddressBook.USDC), 0);
        vault.revokeAquaApproval(IERC20(AddressBook.WETH), 0);
        vm.stopBroadcast();

        console.log("all strategies docked, Aqua allowances revoked");
        console.log("active strategies now:", vault.activeStrategies().length);
    }
}
