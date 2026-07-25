// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AaveV3Adapter } from "../src/AaveV3Adapter.sol";
import { AddressBook } from "../src/AddressBook.sol";
import { PartyVault } from "../src/PartyVault.sol";
import { IAavePool } from "../src/interfaces/IAaveV3.sol";
import { IAqua } from "../src/interfaces/IAqua.sol";
import { ICarryAdapter } from "../src/interfaces/ICarryAdapter.sol";
import { IPriceFeed } from "../src/interfaces/IPriceFeed.sol";

/// @title Deploy Active Reserve
/// @notice Deploys `AaveV3Adapter` then `PartyVault` on Arbitrum One, wired to the gen-2 Aqua pair.
/// @dev POO-1062 R1. Run steps and signing instructions live in `RUNBOOK.md`.
///
///      The adapter and the vault reference each other immutably, so the script predicts the vault
///      address, constructs the adapter with it, and then asserts the pair. Those assertions run
///      during simulation, which happens BEFORE anything is broadcast: a wrong prediction aborts
///      the run instead of publishing a mis-wired pair.
///
///      Guard rails: refuses any chain that is not Arbitrum One, refuses a zero manager, and
///      refuses a `maxTvl` above the window cap so a fat-fingered env cannot open the vault wide.
contract DeployActiveReserve is Script {
    /// @dev D3 as amended for the 20-hour window: the seed is 50 to 200 USD. The cap is set a
    ///      little above that so the seed fits, and raising it is a deliberate manager action.
    uint256 internal constant WINDOW_MAX_TVL_CAP = 1000e6;

    function run() external returns (PartyVault vault, AaveV3Adapter adapter) {
        require(block.chainid == AddressBook.CHAIN_ID, "Deploy: not Arbitrum One");

        address manager = vm.envAddress("MANAGER_ADDRESS");
        uint256 maxTvl = vm.envUint("MAX_TVL_USDC");
        require(manager != address(0), "Deploy: zero manager");
        require(maxTvl > 0 && maxTvl <= WINDOW_MAX_TVL_CAP, "Deploy: maxTvl outside the window cap");

        address deployer = msg.sender;
        // Adapter takes the next nonce, the vault the one after it.
        address predictedVault = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        vm.startBroadcast();

        adapter = new AaveV3Adapter(
            IAavePool(AddressBook.AAVE_V3_POOL), predictedVault, AddressBook.USDC, IERC20(AddressBook.A_USDC)
        );

        vault = new PartyVault(
            IERC20(AddressBook.USDC),
            IERC20(AddressBook.WETH),
            IAqua(AddressBook.AQUA),
            AddressBook.AQUA_SWAP_VM_ROUTER,
            ICarryAdapter(address(adapter)),
            IPriceFeed(AddressBook.CHAINLINK_ETH_USD),
            manager,
            maxTvl
        );

        vm.stopBroadcast();

        require(address(vault) == predictedVault, "Deploy: vault address prediction failed");
        require(adapter.VAULT() == address(vault), "Deploy: adapter is not bound to the vault");
        require(address(vault.ADAPTER()) == address(adapter), "Deploy: vault is not bound to the adapter");
        require(vault.OWNER() == manager, "Deploy: wrong owner");
        require(vault.ROUTER() == AddressBook.AQUA_SWAP_VM_ROUTER, "Deploy: wrong router");
        require(address(vault.AQUA()) == AddressBook.AQUA, "Deploy: wrong Aqua registry");

        console.log("AaveV3Adapter:", address(adapter));
        console.log("PartyVault:   ", address(vault));
        console.log("manager:      ", manager);
        console.log("maxTvl (USDC):", maxTvl);
        console.log("Record both addresses in docs/VERIFIED.md and RUNBOOK.md.");
    }
}
