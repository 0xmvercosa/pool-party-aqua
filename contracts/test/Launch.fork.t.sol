// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AaveV3Adapter } from "../src/AaveV3Adapter.sol";
import { AddressBook } from "../src/AddressBook.sol";
import { PartyVault } from "../src/PartyVault.sol";
import { IAavePool, IAToken } from "../src/interfaces/IAaveV3.sol";
import { IAqua } from "../src/interfaces/IAqua.sol";
import { ICarryAdapter } from "../src/interfaces/ICarryAdapter.sol";
import { IPriceFeed } from "../src/interfaces/IPriceFeed.sol";

interface IAquaRouterView {
    function AQUA() external view returns (address);
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}

/// @title Launch rehearsal against live Arbitrum state
/// @notice Everything POO-1062 will do on mainnet, run first on a fork: deploy the pair exactly the
///         way `script/Deploy.s.sol` does, seed, park, ship TWO bands to the REAL Aqua registry,
///         read them back, and dock them all. Also re-verifies every address in `AddressBook`
///         against the chain, so `docs/VERIFIED.md` cannot silently rot.
contract LaunchForkTest is Test {
    uint256 internal constant USDC_ONE = 1e6;

    address internal manager = makeAddr("manager");

    PartyVault internal vault;
    AaveV3Adapter internal adapter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc")));

        // Same sequence as script/Deploy.s.sol: predict, deploy adapter, deploy vault, assert.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        adapter = new AaveV3Adapter(
            IAavePool(AddressBook.AAVE_V3_POOL), predicted, AddressBook.USDC, IERC20(AddressBook.A_USDC)
        );
        vault = new PartyVault(
            IERC20(AddressBook.USDC),
            IERC20(AddressBook.WETH),
            IAqua(AddressBook.AQUA),
            AddressBook.AQUA_SWAP_VM_ROUTER,
            ICarryAdapter(address(adapter)),
            IPriceFeed(AddressBook.CHAINLINK_ETH_USD),
            manager,
            200 * USDC_ONE
        );
        assertEq(address(vault), predicted, "address prediction is what the deploy script relies on");
        assertEq(adapter.VAULT(), address(vault));
    }

    // -------------------------------------------------------------------------------------------
    // AddressBook re-verification: docs/VERIFIED.md, asserted by code
    // -------------------------------------------------------------------------------------------

    function test_addressBook_matchesTheChain() public view {
        assertEq(block.chainid, AddressBook.CHAIN_ID, "chain id");

        // Gen-2 pairing: each router's AQUA() getter points at its own registry.
        assertEq(
            IAquaRouterView(AddressBook.AQUA_SWAP_VM_ROUTER).AQUA(),
            AddressBook.AQUA,
            "router must point at the gen-2 registry"
        );

        assertEq(IERC20Symbol(AddressBook.USDC).symbol(), "USDC", "native USDC");
        assertEq(IERC20Symbol(AddressBook.A_USDC).symbol(), "aArbUSDCn", "Aave USDC receipt token");
        assertEq(IAToken(AddressBook.A_USDC).UNDERLYING_ASSET_ADDRESS(), AddressBook.USDC, "aToken underlying");
        assertEq(IAToken(AddressBook.A_USDC).POOL(), AddressBook.AAVE_V3_POOL, "aToken pool");
        assertEq(IERC20Symbol(AddressBook.WETH).symbol(), "WETH", "WETH");

        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(AddressBook.CHAINLINK_ETH_USD).latestRoundData();
        assertEq(IPriceFeed(AddressBook.CHAINLINK_ETH_USD).decimals(), 8, "feed decimals");
        assertGt(answer, 0, "feed answers positive");
        assertLe(block.timestamp - updatedAt, 90 minutes, "feed within the D9 staleness bound");
    }

    /// @notice The dead generation must never be reachable from our address book.
    function test_addressBook_doesNotReferenceTheDeadGeneration() public pure {
        address deadRegistry = 0x499943E74FB0cE105688beeE8Ef2ABec5D936d31;
        address deadRouter = 0x8fDD04Dbf6111437B44bbca99C28882434e0958f;
        assertTrue(AddressBook.AQUA != deadRegistry, "gen-1 registry must not be used");
        assertTrue(AddressBook.AQUA_SWAP_VM_ROUTER != deadRouter, "gen-1 router must not be used");
    }

    // -------------------------------------------------------------------------------------------
    // The launch sequence, end to end, against the real registry
    // -------------------------------------------------------------------------------------------

    function test_launchSequence_seedParkShipTwoBandsThenDockAll() public {
        // 1. Manager seed (VLT-R2). D3 window amount.
        uint256 seed = 200 * USDC_ONE;
        deal(AddressBook.USDC, manager, seed);
        vm.startPrank(manager);
        IERC20(AddressBook.USDC).approve(address(vault), seed);
        vault.deposit(seed);

        // 2. Park 95 percent, keep a 5 percent hot buffer (D5).
        vault.parkUsdc(190 * USDC_ONE);
        vm.stopPrank();

        // Tolerance is Aave's scaled-balance rounding on supply, one USDC unit on 190, not ours.
        assertApproxEqAbs(vault.totalAssets(), seed, 2, "parking is NAV neutral");
        assertEq(IERC20(AddressBook.USDC).balanceOf(address(vault)), 10 * USDC_ONE, "hot buffer");
        assertApproxEqAbs(adapter.parkedBalance(AddressBook.USDC), 190 * USDC_ONE, 1, "earning in Aave");

        // 3. Ship BOTH bands to the REAL Aqua registry, combined within the 10 percent sleeve
        //    (PRG-R5/R6): production 12 USDC plus demo 8 USDC on a 200 USDC vault.
        bytes32 productionHash = _ship("active-reserve/production/epoch-1", 12 * USDC_ONE);
        bytes32 demoHash = _ship("active-reserve/demo/epoch-1", 8 * USDC_ONE);

        assertEq(vault.activeStrategies().length, 2, "one vault, two live strategies");
        assertTrue(productionHash != demoHash, "distinct salts give distinct hashes");

        // 4. Read the virtual balances back off the real registry.
        _assertRegistryBalance(productionHash, AddressBook.USDC, 12 * USDC_ONE);
        _assertRegistryBalance(productionHash, AddressBook.WETH, 0);
        _assertRegistryBalance(demoHash, AddressBook.USDC, 8 * USDC_ONE);

        // The registry, not the router, holds the pull allowance.
        assertEq(
            IERC20(AddressBook.USDC).allowance(address(vault), AddressBook.AQUA), type(uint256).max, "Aqua may pull"
        );
        assertEq(
            IERC20(AddressBook.USDC).allowance(address(vault), AddressBook.AQUA_SWAP_VM_ROUTER),
            0,
            "the router never needs an allowance"
        );

        // Shipping is accounting only: not one token moved.
        assertApproxEqAbs(vault.totalAssets(), seed, 2, "ship is NAV neutral");
        assertEq(IERC20(AddressBook.USDC).balanceOf(address(vault)), 10 * USDC_ONE, "buffer untouched by shipping");

        // 5. Emergency stop: dock everything, then revoke.
        vm.startPrank(manager);
        vault.dockAll();
        vault.revokeAquaApproval(IERC20(AddressBook.USDC), 0);
        vm.stopPrank();

        assertEq(vault.activeStrategies().length, 0, "nothing active");
        _assertRegistryBalance(productionHash, AddressBook.USDC, 0);
        _assertRegistryBalance(demoHash, AddressBook.USDC, 0);
        assertEq(IERC20(AddressBook.USDC).allowance(address(vault), AddressBook.AQUA), 0, "allowance revoked");
        assertApproxEqAbs(vault.totalAssets(), seed, 2, "dockAll is NAV neutral");

        // 6. The manager can still get the money out afterwards: inert, not stuck.
        uint256 shares = vault.sharesOf(manager);
        vm.prank(manager);
        uint256 redeemed = vault.redeem(shares);
        assertApproxEqAbs(redeemed, seed, 2, "seed recoverable after the emergency stop");
    }

    /// @notice The real registry refuses to re-ship a docked hash, which is why every roll must
    ///         change the salt (PRG-R10). Proven here against the live contract, not a mock.
    function test_dockedHashIsDeadOnTheRealRegistry() public {
        _seedAndPark();
        bytes memory order = "active-reserve/production/epoch-1";
        bytes32 hash = _ship(order, 5 * USDC_ONE);

        vm.prank(manager);
        vault.execDock(hash);

        (address[] memory tokens, uint256[] memory amounts) = _bandArrays(5 * USDC_ONE);
        vm.prank(manager);
        vm.expectRevert();
        vault.execShip(order, tokens, amounts);

        // The same band with a fresh salt ships fine, which is exactly what a roll does.
        bytes32 rolled = _ship("active-reserve/production/epoch-2", 5 * USDC_ONE);
        assertTrue(vault.isStrategyActive(rolled));
    }

    function test_rollIsDockPlusShipWithNoTokenMovement() public {
        _seedAndPark();
        uint256 navBefore = vault.totalAssets();

        bytes32 epoch1 = _ship("active-reserve/production/epoch-1", 10 * USDC_ONE);

        vm.prank(manager);
        vault.execDock(epoch1);
        bytes32 epoch2 = _ship("active-reserve/production/epoch-2", 10 * USDC_ONE);

        assertFalse(vault.isStrategyActive(epoch1));
        assertTrue(vault.isStrategyActive(epoch2));
        _assertRegistryBalance(epoch1, AddressBook.USDC, 0);
        _assertRegistryBalance(epoch2, AddressBook.USDC, 10 * USDC_ONE);
        assertEq(vault.totalAssets(), navBefore, "a roll is two accounting writes, no slippage");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    function _seedAndPark() private {
        uint256 seed = 200 * USDC_ONE;
        deal(AddressBook.USDC, manager, seed);
        vm.startPrank(manager);
        IERC20(AddressBook.USDC).approve(address(vault), seed);
        vault.deposit(seed);
        vault.parkUsdc(190 * USDC_ONE);
        vm.stopPrank();
    }

    function _bandArrays(uint256 usdcAmount) private pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](2);
        tokens[0] = AddressBook.USDC;
        tokens[1] = AddressBook.WETH;
        amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0; // PRG-R2
    }

    function _ship(bytes memory order, uint256 usdcAmount) private returns (bytes32 hash) {
        (address[] memory tokens, uint256[] memory amounts) = _bandArrays(usdcAmount);
        vm.prank(manager);
        hash = vault.execShip(order, tokens, amounts);
        assertEq(hash, keccak256(order), "Aqua hashes the order bytes (PRG-R9)");
    }

    function _assertRegistryBalance(bytes32 hash, address token, uint256 expected) private view {
        (uint248 balance,) = IAqua(AddressBook.AQUA).rawBalances(address(vault), vault.ROUTER(), hash, token);
        assertEq(uint256(balance), expected, "registry virtual balance");
    }
}
