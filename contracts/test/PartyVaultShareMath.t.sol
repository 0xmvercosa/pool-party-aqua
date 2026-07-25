// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import { PartyVault } from "../src/PartyVault.sol";
import { IAqua } from "../src/interfaces/IAqua.sol";
import { ICarryAdapter } from "../src/interfaces/ICarryAdapter.sol";

import { MockAqua } from "./mocks/MockAqua.sol";
import { MockCarryAdapter } from "./mocks/MockCarryAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceFeed } from "./mocks/MockPriceFeed.sol";
import { MockSwapVMRouter } from "./mocks/MockSwapVMRouter.sol";

/// @notice A stock OpenZeppelin ERC-4626 vault with the same +3 decimals offset, used only as the
///         reference implementation in the differential tests below.
contract ReferenceVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Reference", "REF") ERC4626(asset_) { }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }
}

/// @title PartyVault share math, differentially tested against OpenZeppelin ERC-4626
/// @notice VLT-R1 says the vault uses "OpenZeppelin ERC-4626 math internally: same conversion
///         formulas, same rounding directions, decimals offset +3". PartyVault cannot simply
///         inherit `ERC4626`, because that would drag in the ERC-20 share token VLT-R3 forbids, so
///         the conversion formulas are reimplemented. This suite exists so that claim is PROVEN
///         rather than asserted: a stock OZ `ERC4626` with the same offset is driven through the
///         same operations, and the two must agree exactly, to the wei, at every step.
///
///         Both vaults are kept in states where `totalAssets` is just the USDC balance (nothing
///         parked, no WETH held), so any divergence is pure arithmetic and not a NAV definition
///         difference.
contract PartyVaultShareMathTest is Test {
    uint256 private constant MAX_FUZZ_AMOUNT = 1e15; // 1 billion USDC, well past any real state

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockCarryAdapter internal adapter;
    PartyVault internal vault;
    ReferenceVault internal ozVault;

    address internal owner = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockAqua aqua = new MockAqua();
        MockSwapVMRouter router = new MockSwapVMRouter(aqua);
        MockPriceFeed feed = new MockPriceFeed(8, 3000e8);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        adapter = new MockCarryAdapter(predicted);
        vault = new PartyVault(
            IERC20(address(usdc)),
            IERC20(address(weth)),
            IAqua(address(aqua)),
            address(router),
            ICarryAdapter(address(adapter)),
            feed,
            owner,
            type(uint256).max // the cap is tested elsewhere; here we isolate the math
        );
        require(address(vault) == predicted, "prediction");

        ozVault = new ReferenceVault(IERC20(address(usdc)));
    }

    /// @notice The headline property: after any sequence of seed, donation and second deposit, both
    ///         vaults hold identical state and answer both conversions identically.
    function testFuzz_shareMath_isIdenticalToOpenZeppelin(
        uint256 seed,
        uint256 donation,
        uint256 secondDeposit,
        uint256 query
    ) public {
        seed = bound(seed, 1, MAX_FUZZ_AMOUNT);
        donation = bound(donation, 0, MAX_FUZZ_AMOUNT);
        secondDeposit = bound(secondDeposit, 1, MAX_FUZZ_AMOUNT);
        query = bound(query, 0, MAX_FUZZ_AMOUNT);

        _depositBoth(owner, seed);
        _assertParity(query);

        // A direct transfer that mints no shares: the donation half of the inflation attack.
        _donateBoth(donation);
        _assertParity(query);

        // The second depositor is the victim in that attack. If the donation is large enough to
        // round the deposit down to zero shares, the two implementations DIVERGE on purpose, and
        // that divergence is asserted rather than avoided: see the dedicated test below.
        if (vault.convertToShares(secondDeposit) == 0) {
            _fund(alice, secondDeposit);
            vm.prank(alice);
            vm.expectRevert(PartyVault.ZeroShares.selector);
            vault.deposit(secondDeposit);
            return;
        }

        _depositBoth(alice, secondDeposit);
        _assertParity(query);
    }

    /// @notice Minting shares must be identical too, not just the view functions: what a depositor
    ///         actually receives has to match `previewDeposit` on the reference implementation.
    function testFuzz_depositMintsExactlyWhatOpenZeppelinWould(uint256 seed, uint256 donation, uint256 amount) public {
        seed = bound(seed, 1, MAX_FUZZ_AMOUNT);
        donation = bound(donation, 0, MAX_FUZZ_AMOUNT);
        amount = bound(amount, 1, MAX_FUZZ_AMOUNT);

        _depositBoth(owner, seed);
        _donateBoth(donation);

        uint256 expected = ozVault.previewDeposit(amount);
        if (expected == 0) return; // covered by the divergence test below

        _fund(alice, amount);
        vm.prank(alice);
        uint256 minted = vault.deposit(amount);

        assertEq(minted, expected, "minted shares must equal OZ previewDeposit");
    }

    /// @notice Redemption must pay exactly what OZ's `previewRedeem` would pay.
    function testFuzz_redeemPaysExactlyWhatOpenZeppelinWould(uint256 seed, uint256 donation, uint256 sharePortion)
        public
    {
        seed = bound(seed, 1e6, MAX_FUZZ_AMOUNT);
        donation = bound(donation, 0, MAX_FUZZ_AMOUNT);

        _depositBoth(owner, seed);
        _donateBoth(donation);

        uint256 held = vault.sharesOf(owner);
        uint256 shares = bound(sharePortion, 1, held);

        uint256 expected = ozVault.previewRedeem(shares);
        if (expected == 0) {
            vm.prank(owner);
            vm.expectRevert(PartyVault.ZeroAssets.selector);
            vault.redeem(shares);
            return;
        }

        vm.prank(owner);
        uint256 paid = vault.redeem(shares);

        assertEq(paid, expected, "redeemed assets must equal OZ previewRedeem");
        assertEq(vault.totalShares(), held - shares, "burn is exact");
    }

    /// @notice The virtual-share defence must behave identically on a completely empty vault, which
    ///         is the state the classic first-depositor attack targets.
    function testFuzz_emptyVaultConversionsMatch(uint256 query) public view {
        query = bound(query, 0, MAX_FUZZ_AMOUNT);
        assertEq(vault.totalShares(), 0);
        assertEq(ozVault.totalSupply(), 0);
        assertEq(vault.convertToShares(query), ozVault.convertToShares(query), "empty convertToShares");
        assertEq(vault.convertToAssets(query), ozVault.convertToAssets(query), "empty convertToAssets");
    }

    /// @notice The offset itself, stated as a number rather than a comment: share decimals are the
    ///         asset's plus three, exactly as OZ computes them.
    function test_shareDecimalsMatchTheReference() public view {
        assertEq(vault.shareDecimals(), ozVault.decimals(), "share decimals");
        assertEq(vault.shareDecimals(), 9, "USDC 6 plus offset 3");
        assertEq(vault.DECIMALS_OFFSET(), 3);
    }

    /// @notice The one place we deliberately differ from OZ, pinned so it can never drift silently.
    /// @dev Stock ERC-4626 happily accepts a deposit that mints zero shares, which donates the
    ///      depositor's money to everyone else. PartyVault reverts `ZeroShares` instead. Same for a
    ///      redemption that would pay zero assets. This is strictly safer for the depositor and is
    ///      the only intended divergence from the reference implementation.
    function test_deliberateDivergence_zeroShareDepositIsRefused() public {
        _depositBoth(owner, 1);
        // A donation this large makes any small deposit round to zero shares.
        _donateBoth(1e15);

        uint256 dust = 1;
        assertEq(ozVault.previewDeposit(dust), 0, "OZ would mint nothing");

        _fund(alice, dust);
        vm.prank(alice);
        vm.expectRevert(PartyVault.ZeroShares.selector);
        vault.deposit(dust);

        // The reference implementation takes the money and mints nothing for it.
        _fund(bob, dust);
        vm.startPrank(bob);
        usdc.approve(address(ozVault), dust);
        ozVault.deposit(dust, bob);
        vm.stopPrank();
        assertEq(ozVault.balanceOf(bob), 0, "OZ accepted a deposit worth no shares");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    function _assertParity(uint256 query) private view {
        assertEq(vault.totalAssets(), ozVault.totalAssets(), "totalAssets");
        assertEq(vault.totalShares(), ozVault.totalSupply(), "share supply");
        assertEq(vault.convertToShares(query), ozVault.convertToShares(query), "convertToShares");
        assertEq(vault.convertToAssets(query), ozVault.convertToAssets(query), "convertToAssets");
    }

    function _fund(address who, uint256 amount) private {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    function _depositBoth(address who, uint256 amount) private {
        _fund(who, amount);
        vm.prank(who);
        vault.deposit(amount);

        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(ozVault), amount);
        ozVault.deposit(amount, who);
        vm.stopPrank();
    }

    function _donateBoth(uint256 amount) private {
        if (amount == 0) return;
        usdc.mint(address(vault), amount);
        usdc.mint(address(ozVault), amount);
    }
}
