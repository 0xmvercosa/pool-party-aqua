// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AaveV3Adapter } from "../src/AaveV3Adapter.sol";
import { PartyVault } from "../src/PartyVault.sol";
import { IAavePool } from "../src/interfaces/IAaveV3.sol";
import { IAqua } from "../src/interfaces/IAqua.sol";
import { ICarryAdapter } from "../src/interfaces/ICarryAdapter.sol";
import { IPriceFeed } from "../src/interfaces/IPriceFeed.sol";

import { MockAqua } from "./mocks/MockAqua.sol";
import { MockSwapVMRouter } from "./mocks/MockSwapVMRouter.sol";
import { StubJitRouter, StubMakerVault } from "./mocks/StubMakerVault.sol";

/// @title AaveV3Adapter against live Arbitrum state
/// @notice Fork suite for POO-1060. Every address below was verified on chain, not copied from a
///         README: the aToken's own `UNDERLYING_ASSET_ADDRESS()` and `POOL()` getters were read
///         back and matched (see `docs/VERIFIED.md`).
///
///         Run with the default public endpoint or your own:
///         `forge test --match-path 'test/*.fork.t.sol'`
///         `ARBITRUM_RPC_URL=... forge test --match-path 'test/*.fork.t.sol'`
contract AaveV3AdapterForkTest is Test {
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    uint256 internal constant USDC_ONE = 1e6;
    uint256 internal constant WETH_ONE = 1e18;

    AaveV3Adapter internal adapter;
    address internal vault = makeAddr("vault");

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc")));
        adapter = new AaveV3Adapter(IAavePool(AAVE_POOL), vault, USDC, IERC20(A_USDC));
    }

    // -------------------------------------------------------------------------------------------
    // Wiring and access control
    // -------------------------------------------------------------------------------------------

    function test_constructor_selfChecksTheAToken() public view {
        assertEq(address(adapter.POOL()), AAVE_POOL);
        assertEq(adapter.VAULT(), vault);
        assertEq(adapter.UNDERLYING(), USDC);
        assertEq(address(adapter.A_TOKEN()), A_USDC);
    }

    function test_constructor_rejectsAnATokenFromAnotherReserve() public {
        // aWETH belongs to the same pool but to a different underlying.
        address aWeth = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
        vm.expectRevert(AaveV3Adapter.ATokenMismatch.selector);
        new AaveV3Adapter(IAavePool(AAVE_POOL), vault, USDC, IERC20(aWeth));
    }

    function testFuzz_onlyVaultCanMoveThePosition(address caller) public {
        vm.assume(caller != vault);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.NotVault.selector, caller));
        adapter.park(USDC, 1);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.NotVault.selector, caller));
        adapter.unpark(USDC, 1);
    }

    function test_unsupportedTokenIsRejectedButNeverBreaksViews() public {
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.UnsupportedToken.selector, WETH));
        adapter.park(WETH, 1);

        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.UnsupportedToken.selector, WETH));
        adapter.unpark(WETH, 1);

        // Views stay total so vault NAV never reverts on an unrelated token.
        assertEq(adapter.parkedBalance(WETH), 0);
    }

    function test_noAdminSurface() public view {
        // ADP-R5: nothing that could move the position outside park/unpark exists.
        assertFalse(_hasSelector("owner()"));
        assertFalse(_hasSelector("transferOwnership(address)"));
        assertFalse(_hasSelector("rescue(address,uint256)"));
        assertFalse(_hasSelector("sweep(address)"));
    }

    // -------------------------------------------------------------------------------------------
    // ADP-R3: park supplies, aUSDC accrues
    // -------------------------------------------------------------------------------------------

    function test_park_suppliesAndHoldsOnlyATokens() public {
        _park(10_000 * USDC_ONE);

        assertApproxEqAbs(adapter.parkedBalance(USDC), 10_000 * USDC_ONE, 1, "parked balance");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "no underlying left behind (ADP-R4)");
        assertEq(IERC20(USDC).allowance(address(adapter), AAVE_POOL), 0, "supply consumed the allowance");
        assertGt(IERC20(A_USDC).balanceOf(address(adapter)), 0, "holds aTokens");
    }

    function test_parkedBalance_accruesOverTime() public {
        _park(100_000 * USDC_ONE);
        uint256 start = adapter.parkedBalance(USDC);

        vm.warp(block.timestamp + 90 days);

        uint256 after90d = adapter.parkedBalance(USDC);
        assertGt(after90d, start, "aUSDC must accrue");

        // Report the implied rate so the demo can quote a real number instead of a guess.
        uint256 gained = after90d - start;
        console.log("carry on 100k USDC over 90 days (USDC units):", gained);
        console.log("implied APR bps:", (gained * 10_000 * 365) / (100_000 * USDC_ONE * 90));
    }

    // -------------------------------------------------------------------------------------------
    // ADP-R2: exact withdrawal, and the illiquidity revert
    // -------------------------------------------------------------------------------------------

    function test_unpark_returnsExactlyTheRequestedAmount() public {
        _park(10_000 * USDC_ONE);
        vm.warp(block.timestamp + 7 days);

        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);
        uint256 parkedBefore = adapter.parkedBalance(USDC);
        uint256 amount = 1_234_567; // 1.234567 USDC, deliberately not round

        vm.prank(vault);
        adapter.unpark(USDC, amount);

        assertEq(IERC20(USDC).balanceOf(vault) - vaultBefore, amount, "exact amount to the vault");
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "nothing stuck in the adapter");
        assertApproxEqAbs(adapter.parkedBalance(USDC), parkedBefore - amount, 1, "position reduced by exactly that");
    }

    function testFuzz_unpark_isExactForAnyAmount(uint256 amount) public {
        _park(50_000 * USDC_ONE);
        amount = bound(amount, 1, 40_000 * USDC_ONE);

        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);
        vm.prank(vault);
        adapter.unpark(USDC, amount);
        assertEq(IERC20(USDC).balanceOf(vault) - vaultBefore, amount);
    }

    function test_unpark_revertsWhenTheReserveCannotServeIt() public {
        _park(10_000 * USDC_ONE);

        // Simulated liquidity crunch: the reserve's underlying is drained while Aave's internal
        // accounting still credits us, which is what a 100 percent utilization spike looks like
        // from the withdrawer's side. The revert bubbles: illiquid, never bad debt (ADP-R2).
        deal(USDC, A_USDC, 1);

        vm.prank(vault);
        vm.expectRevert();
        adapter.unpark(USDC, 5000 * USDC_ONE);

        // The position itself is untouched: the vault can retry when liquidity returns.
        assertApproxEqAbs(adapter.parkedBalance(USDC), 10_000 * USDC_ONE, 1);
    }

    // -------------------------------------------------------------------------------------------
    // The just-in-time path, in one transaction, against live Aave
    // -------------------------------------------------------------------------------------------

    /// @notice Isolated hook path with the stub maker the issue asks for: hook fires, adapter
    ///         unparks out of live Aave, the maker pays the taker, all in one transaction.
    function test_jit_stubVault_hookUnparkTransferInOneTx() public {
        StubMakerVault stub = new StubMakerVault(USDC);
        StubJitRouter stubRouter = new StubJitRouter();
        AaveV3Adapter stubAdapter = new AaveV3Adapter(IAavePool(AAVE_POOL), address(stub), USDC, IERC20(A_USDC));
        stub.initialize(ICarryAdapter(address(stubAdapter)), address(stubRouter));

        deal(USDC, address(stub), 1000 * USDC_ONE);
        stub.park(950 * USDC_ONE); // 50 USDC hot buffer, 950 earning

        address taker = makeAddr("taker");
        uint256 fill = 300 * USDC_ONE;

        uint256 gasBefore = gasleft();
        stubRouter.settle(stub, USDC, taker, fill);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(IERC20(USDC).balanceOf(taker), fill, "taker paid");
        assertEq(IERC20(USDC).balanceOf(address(stub)), 0, "buffer spent");
        // Tolerance is Aave's own scaled-balance rounding across the supply and the withdraw, a
        // couple of USDC units on 950, not a behaviour of ours.
        assertApproxEqAbs(stubAdapter.parkedBalance(USDC), 700 * USDC_ONE, 3, "only the shortfall left Aave");
        console.log("stub JIT settle gas (hook + Aave withdraw + transfer):", gasUsed);
    }

    /// @notice Same path through the real PartyVault, which is stronger than a stub: real share
    ///         accounting, real hook gating, real strategy bookkeeping, real Aave.
    function test_jit_realVault_againstLiveAave() public {
        (PartyVault partyVault, MockAqua aqua, MockSwapVMRouter router, AaveV3Adapter vaultAdapter, address manager) =
            _deployRealVault();

        _seedVault(partyVault, manager, 1000 * USDC_ONE);

        vm.prank(manager);
        partyVault.parkUsdc(950 * USDC_ONE); // 50 USDC hot buffer

        bytes32 strategyHash = _shipBand(partyVault, manager, 500 * USDC_ONE);

        address taker = makeAddr("taker");
        uint256 amountOut = 300 * USDC_ONE;
        // Price the fill off the live feed the way the band does: the vault pays USDC and receives
        // WETH worth 5 percent more, which is what "buying the dip below spot" means in numbers.
        uint256 amountIn = _wethForUsdcAtDiscount(amountOut, 500);
        deal(WETH, taker, amountIn);
        vm.prank(taker);
        IERC20(WETH).approve(address(router), amountIn);

        uint256 navBefore = partyVault.totalAssets();

        vm.prank(taker);
        vm.expectEmit(true, true, false, true, address(partyVault));
        emit PartyVault.JitUnparked(USDC, 250 * USDC_ONE, strategyHash);
        router.settle(address(partyVault), strategyHash, WETH, USDC, amountIn, amountOut);

        assertEq(IERC20(USDC).balanceOf(taker), amountOut, "taker paid from the vault");
        assertEq(IERC20(WETH).balanceOf(address(partyVault)), amountIn, "vault holds the bought WETH");
        assertApproxEqAbs(vaultAdapter.parkedBalance(USDC), 700 * USDC_ONE, 3, "exact shortfall unparked");
        assertGe(partyVault.totalAssets(), navBefore, "NAV must not fall on a fill at oracle price");

        (uint248 remaining,) = aqua.rawBalances(address(partyVault), address(router), strategyHash, USDC);
        assertEq(remaining, 200 * USDC_ONE, "Aqua virtual balance decremented by the pull");
    }

    /// @notice The gas note for the PR: what a fill costs when the hot buffer covers it versus when
    ///         it has to reach into Aave. The delta is the minimum-fill economics input.
    function test_gasNote_jitOverheadPerFill() public {
        uint256 withoutJit = _measureFillGas({ bufferCovers: true });
        uint256 withJit = _measureFillGas({ bufferCovers: false });

        console.log("fill gas, buffer covers (no Aave touch):", withoutJit);
        console.log("fill gas, JIT withdraw from Aave:       ", withJit);
        console.log("JIT overhead per fill (gas):            ", withJit - withoutJit);

        assertGt(withJit, withoutJit, "the Aave leg must be visible in the trace");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @dev WETH amount whose live Chainlink value is `usdcAmount` marked up by `discountBps`, i.e.
    ///      the WETH a maker buying `discountBps` below spot receives for that USDC.
    function _wethForUsdcAtDiscount(uint256 usdcAmount, uint256 discountBps) private view returns (uint256) {
        (, int256 answer,,,) = IPriceFeed(ETH_USD_FEED).latestRoundData();
        require(answer > 0, "feed");
        // 1e20 = 10 ** (feed 8 decimals + WETH 18 decimals - USDC 6 decimals)
        return (usdcAmount * 1e20 * 10_000) / (uint256(answer) * (10_000 - discountBps));
    }

    function _park(uint256 amount) private {
        deal(USDC, vault, amount);
        vm.prank(vault);
        IERC20(USDC).approve(address(adapter), amount);
        vm.prank(vault);
        adapter.park(USDC, amount);
    }

    function _hasSelector(string memory signature) private view returns (bool ok) {
        (ok,) = address(adapter).staticcall(abi.encodeWithSignature(signature, address(0), uint256(0)));
    }

    function _deployRealVault()
        private
        returns (
            PartyVault partyVault,
            MockAqua aqua,
            MockSwapVMRouter router,
            AaveV3Adapter vaultAdapter,
            address manager
        )
    {
        manager = makeAddr("manager");
        aqua = new MockAqua();
        router = new MockSwapVMRouter(aqua);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vaultAdapter = new AaveV3Adapter(IAavePool(AAVE_POOL), predicted, USDC, IERC20(A_USDC));
        partyVault = new PartyVault(
            IERC20(USDC),
            IERC20(WETH),
            IAqua(address(aqua)),
            address(router),
            ICarryAdapter(address(vaultAdapter)),
            IPriceFeed(ETH_USD_FEED),
            manager,
            1_000_000 * USDC_ONE
        );
        assertEq(address(partyVault), predicted, "vault address prediction");
        assertEq(vaultAdapter.VAULT(), address(partyVault), "adapter bound to the vault");
    }

    function _seedVault(PartyVault partyVault, address manager, uint256 amount) private {
        deal(USDC, manager, amount);
        vm.prank(manager);
        IERC20(USDC).approve(address(partyVault), amount);
        vm.prank(manager);
        partyVault.deposit(amount);
    }

    function _shipBand(PartyVault partyVault, address manager, uint256 usdcAmount)
        private
        returns (bytes32 strategyHash)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0; // PRG-R2: both tokens registered, empty side at 0

        vm.prank(manager);
        strategyHash = partyVault.execShip(bytes("active-reserve-band"), tokens, amounts);
    }

    function _measureFillGas(bool bufferCovers) private returns (uint256 gasUsed) {
        (PartyVault partyVault,, MockSwapVMRouter router,, address manager) = _deployRealVault();
        _seedVault(partyVault, manager, 1000 * USDC_ONE);

        // Same fill size either way; only the hot buffer differs.
        uint256 amountOut = 300 * USDC_ONE;
        vm.prank(manager);
        partyVault.parkUsdc(bufferCovers ? 600 * USDC_ONE : 950 * USDC_ONE);

        bytes32 strategyHash = _shipBand(partyVault, manager, 500 * USDC_ONE);

        address taker = makeAddr("gasTaker");
        uint256 amountIn = WETH_ONE / 10;
        deal(WETH, taker, amountIn);
        vm.prank(taker);
        IERC20(WETH).approve(address(router), amountIn);

        vm.prank(taker);
        uint256 gasBefore = gasleft();
        router.settle(address(partyVault), strategyHash, WETH, USDC, amountIn, amountOut);
        gasUsed = gasBefore - gasleft();
    }
}
