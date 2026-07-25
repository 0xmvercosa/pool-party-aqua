// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AaveV3Adapter } from "../src/AaveV3Adapter.sol";
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

/// @title VerifyDeployment
/// @notice Reads the deployed pair back OFF CHAIN STATE and reverts if anything is mis-wired.
/// @dev POO-1062 R1. `Deploy.s.sol` asserts the same facts, but those `require`s execute during
///      forge's simulation against a local fork of the chain, so they prove what the script INTENDED
///      to deploy, not what a full node now actually serves. This script closes that gap: it runs
///      after the broadcast, reads every immutable from the live contracts, and is the gate between
///      section 1 and section 2 of the runbook.
///
///      Read-only, no broadcast, so it costs nothing and can be re-run at any time. A revert here
///      means STOP: do not seed a vault whose wiring does not check out.
contract VerifyDeployment is OpsBase {
    function run() external view {
        require(block.chainid == AddressBook.CHAIN_ID, "Ops: not Arbitrum One");
        check(vm.envAddress("VAULT_ADDRESS"), vm.envAddress("MANAGER_ADDRESS"));
    }

    /// @notice The checks themselves, taking explicit arguments so tests and `cast` can call them
    ///         with no environment plumbing.
    /// @param vaultAddress The deployed PartyVault.
    /// @param expectedManager The address that was supposed to end up owning it.
    function check(address vaultAddress, address expectedManager) public view {
        PartyVault deployed = PartyVault(vaultAddress);

        // Both contracts exist as code, not just as addresses in a log we pasted.
        require(vaultAddress.code.length > 0, "Verify: vault has no code");
        AaveV3Adapter adapter = AaveV3Adapter(address(deployed.ADAPTER()));
        require(address(adapter).code.length > 0, "Verify: adapter has no code");

        // The binding, in both directions. This is the one a simulation cannot prove.
        require(adapter.VAULT() == vaultAddress, "Verify: adapter is not bound to this vault");

        // The vault's counterparties are the canonical gen-2 pair and nothing else.
        require(deployed.ROUTER() == AddressBook.AQUA_SWAP_VM_ROUTER, "Verify: wrong router");
        require(address(deployed.AQUA()) == AddressBook.AQUA, "Verify: wrong Aqua registry");
        require(address(deployed.USDC()) == AddressBook.USDC, "Verify: wrong USDC");
        require(address(deployed.WETH()) == AddressBook.WETH, "Verify: wrong WETH");
        require(address(deployed.PRICE_FEED()) == AddressBook.CHAINLINK_ETH_USD, "Verify: wrong price feed");

        // The adapter points at the right Aave reserve.
        require(address(adapter.POOL()) == AddressBook.AAVE_V3_POOL, "Verify: wrong Aave pool");
        require(adapter.UNDERLYING() == AddressBook.USDC, "Verify: wrong adapter underlying");
        require(address(adapter.A_TOKEN()) == AddressBook.A_USDC, "Verify: wrong aToken");

        // Ownership and share math are what the rules say.
        require(deployed.OWNER() == expectedManager, "Verify: owner is not the manager");
        require(deployed.DECIMALS_OFFSET() == 3, "Verify: decimals offset is not 3");
        require(deployed.shareDecimals() == 9, "Verify: share decimals are not 9");

        // Nothing has happened yet: a fresh deployment is unseeded with no strategies.
        require(!deployed.seeded(), "Verify: vault is already seeded, this is not a fresh deployment");
        require(deployed.activeStrategies().length == 0, "Verify: strategies already active");
        require(deployed.totalShares() == 0, "Verify: shares already outstanding");

        console.log("ON-CHAIN VERIFICATION PASSED");
        console.log("vault:        ", vaultAddress);
        console.log("adapter:      ", address(adapter));
        console.log("owner:        ", deployed.OWNER());
        console.log("router:       ", deployed.ROUTER());
        console.log("aqua registry:", address(deployed.AQUA()));
        console.log("maxTvl (USDC):", deployed.maxTvl());
        console.log("Safe to proceed to the seed step.");
    }
}

/// @title DockBand
/// @notice Docks one strategy by hash. The dock half of a roll (PRG-R8).
/// @dev Accounting only: no tokens move. Aqua needs the complete shipped token list, which the vault
///      stores per hash and replays itself, so the only input here is the hash. Pair it with
///      `ShipBand` and a CHANGED salt: a docked hash is dead forever (PRG-R10).
contract DockBand is OpsBase {
    function run() external {
        _loadVault();
        bytes32 strategyHash = vm.envBytes32("STRATEGY_HASH");
        require(vault.isStrategyActive(strategyHash), "Dock: strategy is not active on this vault");

        vm.startBroadcast();
        vault.execDock(strategyHash);
        vm.stopBroadcast();

        require(!vault.isStrategyActive(strategyHash), "Dock: strategy still active after docking");

        console.log("docked strategy:");
        console.logBytes32(strategyHash);
        console.log("active strategies remaining:", vault.activeStrategies().length);
        console.log("Ship the replacement with a CHANGED salt; this hash is dead forever.");
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
        console.log("adapter:          ", address(vault.ADAPTER()));
        console.log("router (Aqua app):", vault.ROUTER());
        console.log("aqua registry:    ", address(vault.AQUA()));
        console.log("seeded:           ", vault.seeded());
        console.log("maxTvl (USDC):    ", vault.maxTvl());
        console.log("totalAssets (USDC):", vault.totalAssets());
        console.log("totalShares:      ", vault.totalShares());
        console.log("hot buffer (USDC):", buffer);
        console.log("parked in Aave:   ", parked);
        console.log("liquid USDC:      ", vault.liquidUsdc());
        console.log("WETH held (wei):  ", wethHeld);
        console.log("ETH/USD (8dp):    ", uint256(ethUsd));

        // Allowances, all four of them. Aqua pulls from the maker, so USDC to the registry is the
        // one that must be set; everything to the router must stay zero, and the runbook check for
        // that is only performable if the router lines are actually printed.
        console.log("allow USDC -> Aqua:  ", IERC20(AddressBook.USDC).allowance(address(vault), AddressBook.AQUA));
        console.log("allow WETH -> Aqua:  ", IERC20(AddressBook.WETH).allowance(address(vault), AddressBook.AQUA));
        console.log("allow USDC -> router:", IERC20(AddressBook.USDC).allowance(address(vault), vault.ROUTER()));
        console.log("allow WETH -> router:", IERC20(AddressBook.WETH).allowance(address(vault), vault.ROUTER()));
        if (
            IERC20(AddressBook.USDC).allowance(address(vault), vault.ROUTER()) != 0
                || IERC20(AddressBook.WETH).allowance(address(vault), vault.ROUTER()) != 0
        ) {
            console.log("WARNING: the router holds an allowance it never needs. Investigate.");
        }

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
