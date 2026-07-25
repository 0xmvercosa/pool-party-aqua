// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { PartyVault } from "../src/PartyVault.sol";
import { IAqua } from "../src/interfaces/IAqua.sol";
import { ICarryAdapter } from "../src/interfaces/ICarryAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { MockAqua } from "./mocks/MockAqua.sol";
import { MockCarryAdapter } from "./mocks/MockCarryAdapter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockPriceFeed } from "./mocks/MockPriceFeed.sol";
import { MockSwapVMRouter } from "./mocks/MockSwapVMRouter.sol";

/// @title PartyVault essentials
/// @notice Test depth targets the essentials the 20-hour window kept (POO-1059 window cut, epic
///         POO-1057): share-math and first-depositor properties, owner and hook gating under fuzz,
///         the deposit cap, the redemption liquidity gate, and the strategy lifecycle including
///         `dockAll` and the just-in-time settlement path.
contract PartyVaultTest is Test {
    uint256 private constant USDC_ONE = 1e6;
    uint256 private constant WETH_ONE = 1e18;
    int256 private constant ETH_USD = 3000e8;
    uint256 private constant MAX_TVL = 200 * USDC_ONE;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockAqua internal aqua;
    MockSwapVMRouter internal router;
    MockCarryAdapter internal adapter;
    MockPriceFeed internal feed;
    PartyVault internal vault;

    address internal owner = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal taker = makeAddr("taker");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        aqua = new MockAqua();
        router = new MockSwapVMRouter(aqua);
        feed = new MockPriceFeed(8, ETH_USD);

        // The adapter is bound to its vault for life (ADP-R1) and the vault is bound to its adapter,
        // so the deployment predicts the vault address and the vault deploy fails loudly if the
        // prediction is wrong. Same pattern the mainnet deploy script uses.
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        adapter = new MockCarryAdapter(predictedVault);
        vault = new PartyVault(
            IERC20(address(usdc)),
            IERC20(address(weth)),
            IAqua(address(aqua)),
            address(router),
            ICarryAdapter(address(adapter)),
            feed,
            owner,
            MAX_TVL
        );
        assertEq(address(vault), predictedVault, "vault address prediction");
        assertEq(adapter.vault(), address(vault), "adapter bound to vault");
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R1 / VLT-R3: share math, views, events
    // -------------------------------------------------------------------------------------------

    function test_constructor_wiresImmutablesAndShareDecimals() public view {
        assertEq(address(vault.USDC()), address(usdc));
        assertEq(address(vault.WETH()), address(weth));
        assertEq(address(vault.AQUA()), address(aqua));
        assertEq(vault.ROUTER(), address(router));
        assertEq(address(vault.ADAPTER()), address(adapter));
        assertEq(vault.OWNER(), owner);
        assertEq(vault.maxTvl(), MAX_TVL);
        assertEq(vault.DECIMALS_OFFSET(), 3);
        // asset decimals + offset
        assertEq(vault.shareDecimals(), 9);
        assertFalse(vault.seeded());
    }

    function test_seedDeposit_mintsOffsetShares() public {
        _seed(100 * USDC_ONE);

        // First deposit into an empty vault mints assets * 10 ** offset shares.
        assertEq(vault.totalShares(), 100 * USDC_ONE * 1000);
        assertEq(vault.sharesOf(owner), 100 * USDC_ONE * 1000);
        assertEq(vault.totalAssets(), 100 * USDC_ONE);
        assertTrue(vault.seeded());
        // Round trip is loss free at the seed point apart from the virtual-asset unit.
        assertApproxEqAbs(vault.convertToAssets(vault.sharesOf(owner)), 100 * USDC_ONE, 1);
    }

    function test_deposit_emitsDepositedAndCreditsLedger() public {
        _seed(50 * USDC_ONE);

        uint256 amount = 25 * USDC_ONE;
        uint256 expectedShares = vault.convertToShares(amount);
        _fund(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit PartyVault.Deposited(alice, amount, expectedShares);
        uint256 shares = vault.deposit(amount);

        assertEq(shares, expectedShares);
        assertEq(vault.sharesOf(alice), shares);
        assertEq(vault.totalAssets(), 75 * USDC_ONE);
    }

    function test_redeem_paysUsdcAndBurnsShares() public {
        _seed(100 * USDC_ONE);
        _deposit(alice, 50 * USDC_ONE);

        uint256 shares = vault.sharesOf(alice);
        uint256 expected = vault.convertToAssets(shares);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares);

        assertEq(assets, expected);
        assertEq(vault.sharesOf(alice), 0);
        assertEq(usdc.balanceOf(alice), assets);
        assertApproxEqAbs(assets, 50 * USDC_ONE, 1);
    }

    function test_totalAssets_countsBufferParkedAndWethAtOracle() public {
        _seed(100 * USDC_ONE);

        vm.prank(owner);
        vault.parkUsdc(90 * USDC_ONE);
        assertEq(usdc.balanceOf(address(vault)), 10 * USDC_ONE);
        assertEq(adapter.parkedBalance(address(usdc)), 90 * USDC_ONE);
        assertEq(vault.totalAssets(), 100 * USDC_ONE, "parking must not move NAV");

        // Carry accrual shows up immediately (ADP-R3).
        usdc.mint(address(adapter), 1 * USDC_ONE);
        adapter.accrue(address(usdc), 1 * USDC_ONE);
        assertEq(vault.totalAssets(), 101 * USDC_ONE);

        // A filled band leaves WETH in the vault; NAV must value it, not drop.
        weth.mint(address(vault), WETH_ONE / 100); // 0.01 WETH at 3000 USD = 30 USDC
        assertEq(vault.totalAssets(), 101 * USDC_ONE + 30 * USDC_ONE);
    }

    function test_totalAssets_revertsOnNonPositiveOracleAnswer() public {
        _seed(10 * USDC_ONE);
        weth.mint(address(vault), WETH_ONE);
        feed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.InvalidPrice.selector, int256(0)));
        vault.totalAssets();
    }

    function test_noErc20ShareSurface() public view {
        // VLT-R3: shares are not a token. Nothing answers the ERC-20 selectors.
        (bool okTransfer,) = address(vault).staticcall(abi.encodeWithSignature("transfer(address,uint256)", bob, 1));
        (bool okBalance,) = address(vault).staticcall(abi.encodeWithSignature("balanceOf(address)", owner));
        (bool okSupply,) = address(vault).staticcall(abi.encodeWithSignature("totalSupply()"));
        assertFalse(okTransfer, "no transfer");
        assertFalse(okBalance, "no balanceOf");
        assertFalse(okSupply, "no totalSupply");
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R2: manager seeds first
    // -------------------------------------------------------------------------------------------

    function test_deposit_revertsBeforeManagerSeed() public {
        _fund(alice, 10 * USDC_ONE);
        vm.prank(alice);
        vm.expectRevert(PartyVault.NotSeeded.selector);
        vault.deposit(10 * USDC_ONE);
    }

    function testFuzz_deposit_onlyManagerCanSeed(address caller) public {
        vm.assume(caller != owner && caller != address(0));
        _fund(caller, 10 * USDC_ONE);
        vm.prank(caller);
        vm.expectRevert(PartyVault.NotSeeded.selector);
        vault.deposit(10 * USDC_ONE);
    }

    function test_deposit_openToAllOnceSeeded() public {
        _seed(10 * USDC_ONE);
        _deposit(alice, 10 * USDC_ONE);
        assertGt(vault.sharesOf(alice), 0);
    }

    // -------------------------------------------------------------------------------------------
    // Inflation / first-depositor property (the reason for the decimals offset)
    // -------------------------------------------------------------------------------------------

    /// @notice The classic ERC-4626 donation attack must be unprofitable and must not wipe out the
    ///         victim's claim. Manager seeds first (VLT-R2), then the attacker takes the smallest
    ///         possible position, donates directly to the vault to inflate the share price, and the
    ///         victim deposits. The attacker must never end up ahead, and the victim must keep
    ///         essentially all of its deposit.
    function testFuzz_inflationAttack_isUnprofitableAndVictimKeepsValue(
        uint256 seed,
        uint256 attackerDeposit,
        uint256 donation,
        uint256 victimDeposit
    ) public {
        seed = bound(seed, USDC_ONE, 50 * USDC_ONE);
        attackerDeposit = bound(attackerDeposit, 1, 10 * USDC_ONE);
        donation = bound(donation, 0, 1000 * USDC_ONE);
        victimDeposit = bound(victimDeposit, USDC_ONE, 100 * USDC_ONE);

        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);

        _seed(seed);

        _deposit(bob, attackerDeposit); // bob is the attacker

        // The donation is a direct transfer, not a deposit: it mints no shares.
        usdc.mint(bob, donation);
        vm.prank(bob);
        usdc.transfer(address(vault), donation);

        uint256 victimShares = _deposit(alice, victimDeposit);

        // Property 1: the victim is never rounded down to nothing.
        assertGt(victimShares, 0, "victim shares must be non zero");

        // Property 2: the victim can still claim essentially its whole deposit. The bound is one
        // asset unit of rounding, not a fraction of the deposit.
        uint256 victimClaim = vault.convertToAssets(victimShares);
        assertGe(victimClaim + 1, victimDeposit, "victim claim must cover its deposit");

        // Property 3: the attack does not pay. The attacker cannot claim back more than the capital
        // it committed (deposit plus donation).
        uint256 attackerClaim = vault.convertToAssets(vault.sharesOf(bob));
        assertLe(attackerClaim, attackerDeposit + donation, "attack must not be profitable");
    }

    /// @notice Conversions must never mint value out of rounding: assets in, shares, assets back out
    ///         is monotonically non increasing.
    function testFuzz_convertRoundTrip_neverGainsValue(uint256 seedAmount, uint256 assets) public {
        seedAmount = bound(seedAmount, USDC_ONE, 100 * USDC_ONE);
        assets = bound(assets, 1, 100 * USDC_ONE);

        vm.prank(owner);
        vault.setMaxTvl(type(uint256).max);
        _seed(seedAmount);

        uint256 shares = vault.convertToShares(assets);
        assertLe(vault.convertToAssets(shares), assets, "round trip must not gain");
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R1 / VLT-R10: maxTvl
    // -------------------------------------------------------------------------------------------

    function test_deposit_revertsAboveMaxTvl() public {
        _seed(MAX_TVL);

        _fund(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.MaxTvlExceeded.selector, MAX_TVL + 1, MAX_TVL));
        vault.deposit(1);
    }

    function test_deposit_allowsExactlyMaxTvl() public {
        _seed(MAX_TVL - 10 * USDC_ONE);
        _deposit(alice, 10 * USDC_ONE);
        assertEq(vault.totalAssets(), MAX_TVL);
    }

    function test_maxTvl_countsParkedAndWethNotJustBuffer() public {
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(100 * USDC_ONE);
        assertEq(usdc.balanceOf(address(vault)), 0);

        // Buffer is empty but NAV is already at 100, and WETH pushes it to 130.
        weth.mint(address(vault), WETH_ONE / 100);
        assertEq(vault.totalAssets(), 130 * USDC_ONE);

        _fund(alice, 100 * USDC_ONE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.MaxTvlExceeded.selector, 230 * USDC_ONE, MAX_TVL));
        vault.deposit(100 * USDC_ONE);
    }

    function test_setMaxTvl_updatesCap() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(vault));
        emit PartyVault.MaxTvlUpdated(1000 * USDC_ONE);
        vault.setMaxTvl(1000 * USDC_ONE);
        assertEq(vault.maxTvl(), 1000 * USDC_ONE);
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R5: redemption liquidity gate
    // -------------------------------------------------------------------------------------------

    function test_redeem_unparksShortfallFromAdapter() public {
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(95 * USDC_ONE);

        uint256 shares = vault.sharesOf(owner);
        vm.prank(owner);
        uint256 assets = vault.redeem(shares);

        assertApproxEqAbs(assets, 100 * USDC_ONE, 1);
        assertEq(usdc.balanceOf(owner), assets);
        assertEq(adapter.parkedBalance(address(usdc)), 0);
    }

    function test_redeem_revertsWhenLiquidUsdcIsShort() public {
        _seed(100 * USDC_ONE);

        // A filled band turned USDC into WETH: NAV is intact but only WETH is left on top.
        vm.prank(owner);
        vault.parkUsdc(60 * USDC_ONE);
        vm.prank(address(vault));
        usdc.transfer(taker, 40 * USDC_ONE); // simulate the pull leg of a fill
        weth.mint(address(vault), WETH_ONE / 50); // 0.02 WETH at 3000 USD = 60 USDC

        assertEq(vault.totalAssets(), 120 * USDC_ONE);
        assertEq(vault.liquidUsdc(), 60 * USDC_ONE);

        uint256 shares = vault.sharesOf(owner);
        uint256 assets = vault.convertToAssets(shares);
        assertGt(assets, vault.liquidUsdc());

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.InsufficientLiquidUsdc.selector, assets, 60 * USDC_ONE));
        vault.redeem(shares);

        // Redeeming only what the vault can actually pay still works: illiquid, never insolvent.
        uint256 payableShares = shares / 3;
        vm.prank(owner);
        uint256 paid = vault.redeem(payableShares);
        assertGt(paid, 0);
        assertEq(usdc.balanceOf(owner), paid);
    }

    function test_redeem_bubblesAdapterRevertAsTemporarilyIlliquid() public {
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(100 * USDC_ONE);

        // Aave under utilization stress (ADP-R2): the venue reverts, the vault does not pretend.
        adapter.setUnparkShouldFail(true);
        uint256 shares = vault.sharesOf(owner);

        vm.prank(owner);
        vm.expectRevert(MockCarryAdapter.UnparkFailed.selector);
        vault.redeem(shares);
    }

    function test_redeem_revertsOnMoreSharesThanHeld() public {
        _seed(10 * USDC_ONE);
        uint256 held = vault.sharesOf(owner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.InsufficientShares.selector, held + 1, held));
        vault.redeem(held + 1);
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R7 reduced: owner gating
    // -------------------------------------------------------------------------------------------

    function testFuzz_ownerGating_everyPrivilegedEntryPoint(address caller) public {
        vm.assume(caller != owner);

        bytes32 someHash = keccak256("strategy");
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(PartyVault.setMaxTvl, (1));
        calls[1] = abi.encodeCall(PartyVault.execShip, (hex"00", tokens, amounts));
        calls[2] = abi.encodeCall(PartyVault.execDock, (someHash));
        calls[3] = abi.encodeCall(PartyVault.dockAll, ());
        calls[4] = abi.encodeCall(PartyVault.parkUsdc, (1));
        calls[5] = abi.encodeCall(PartyVault.unparkUsdc, (1));
        calls[6] = abi.encodeCall(PartyVault.revokeAquaApproval, (IERC20(address(usdc)), 0));

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            assertFalse(ok, "privileged call must revert for non owner");
            assertEq(bytes4(ret), PartyVault.NotOwner.selector, "must revert with NotOwner");
        }
    }

    function testFuzz_hookGating_onlyRouterMayCall(address caller) public {
        vm.assume(caller != address(router));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.NotRouter.selector, caller));
        vault.preTransferOut(address(vault), taker, address(weth), address(usdc), 0, 1, bytes32(0), "", "");
    }

    /// @notice Anyone can ship an order that points its maker hook at our vault. The vault must
    ///         refuse to work for a maker that is not itself, otherwise a stranger could force our
    ///         sleeve out of the carry venue at will.
    function testFuzz_hook_refusesForeignMakers(address foreignMaker) public {
        vm.assume(foreignMaker != address(vault));
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(100 * USDC_ONE);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.NotOurOrder.selector, foreignMaker));
        router.callHookOnly(address(vault), foreignMaker, address(usdc), 10 * USDC_ONE);

        assertEq(adapter.parkedBalance(address(usdc)), 100 * USDC_ONE, "sleeve untouched");
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R7 / VLT-R11: strategy lifecycle and dockAll
    // -------------------------------------------------------------------------------------------

    function test_execShip_registersStrategyAndApprovesAqua() public {
        _seed(100 * USDC_ONE);

        (bytes32 hash, address[] memory tokens,) = _ship("band-1", 10 * USDC_ONE);

        assertTrue(vault.isStrategyActive(hash));
        assertEq(vault.activeStrategies().length, 1);
        assertEq(vault.activeStrategies()[0], hash);
        assertEq(vault.strategyTokens(hash).length, 2);
        assertEq(vault.strategyTokens(hash)[0], tokens[0]);
        assertEq(vault.strategyTokens(hash)[1], tokens[1]);

        // Aqua pulls from the maker, so the registry holds the allowance, not the router.
        assertEq(usdc.allowance(address(vault), address(aqua)), type(uint256).max);
        assertEq(usdc.allowance(address(vault), address(router)), 0);

        (uint248 balance, uint8 count) = aqua.rawBalances(address(vault), address(router), hash, address(usdc));
        assertEq(balance, 10 * USDC_ONE);
        assertEq(count, 2);
    }

    function test_execShip_forcesTheCanonicalRouterAsApp() public {
        _seed(100 * USDC_ONE);
        (bytes32 hash,,) = _ship("band-1", 10 * USDC_ONE);

        // The vault never lets the owner choose the app: balances exist only under ROUTER.
        (, uint8 underRouter) = aqua.rawBalances(address(vault), address(router), hash, address(usdc));
        (, uint8 underStranger) = aqua.rawBalances(address(vault), bob, hash, address(usdc));
        assertEq(underRouter, 2);
        assertEq(underStranger, 0);
    }

    function test_execShip_revertsOnMismatchedArrays() public {
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        vm.prank(owner);
        vm.expectRevert(PartyVault.InvalidShipArrays.selector);
        vault.execShip(hex"1234", tokens, amounts);
    }

    function test_execDock_zeroesBalancesAndDropsFromActiveSet() public {
        _seed(100 * USDC_ONE);
        (bytes32 hash,,) = _ship("band-1", 10 * USDC_ONE);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(vault));
        emit PartyVault.StrategyDocked(hash);
        vault.execDock(hash);

        assertFalse(vault.isStrategyActive(hash));
        assertEq(vault.activeStrategies().length, 0);
        (uint248 balance,) = aqua.rawBalances(address(vault), address(router), hash, address(usdc));
        assertEq(balance, 0);
    }

    function test_execDock_revertsForUnknownStrategy() public {
        bytes32 unknown = keccak256("nope");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PartyVault.StrategyNotActive.selector, unknown));
        vault.execDock(unknown);
    }

    function test_dockAll_docksEveryActiveStrategy() public {
        _seed(100 * USDC_ONE);

        // Production band plus the approved demo band: one vault backing two live strategies.
        (bytes32 production,,) = _ship("production-band", 6 * USDC_ONE);
        (bytes32 demo,,) = _ship("demo-band", 4 * USDC_ONE);
        assertEq(vault.activeStrategies().length, 2);

        vm.prank(owner);
        vault.dockAll();

        assertEq(vault.activeStrategies().length, 0);
        assertFalse(vault.isStrategyActive(production));
        assertFalse(vault.isStrategyActive(demo));
        (uint248 productionBalance,) = aqua.rawBalances(address(vault), address(router), production, address(usdc));
        (uint248 demoBalance,) = aqua.rawBalances(address(vault), address(router), demo, address(usdc));
        assertEq(productionBalance, 0);
        assertEq(demoBalance, 0);

        // Accounting only: not a single token moved.
        assertEq(vault.totalAssets(), 100 * USDC_ONE);
    }

    function test_dockAll_isANoOpWhenNothingIsActive() public {
        vm.prank(owner);
        vault.dockAll();
        assertEq(vault.activeStrategies().length, 0);
    }

    function test_dockAll_handlesMiddleRemovalOrder() public {
        _seed(100 * USDC_ONE);
        (bytes32 a,,) = _ship("a", 1 * USDC_ONE);
        (bytes32 b,,) = _ship("b", 1 * USDC_ONE);
        (bytes32 c,,) = _ship("c", 1 * USDC_ONE);

        // Dock the middle one first so the swap-and-pop path is exercised, then dock the rest.
        vm.prank(owner);
        vault.execDock(b);
        assertEq(vault.activeStrategies().length, 2);
        assertTrue(vault.isStrategyActive(a));
        assertTrue(vault.isStrategyActive(c));

        vm.prank(owner);
        vault.dockAll();
        assertEq(vault.activeStrategies().length, 0);
        assertFalse(vault.isStrategyActive(a));
        assertFalse(vault.isStrategyActive(c));
    }

    function test_dockedStrategyHashIsDeadForever() public {
        _seed(100 * USDC_ONE);
        (bytes32 hash,,) = _ship("band-1", 10 * USDC_ONE);
        vm.prank(owner);
        vault.execDock(hash);

        // PRG-R10: a roll must change the salt, because Aqua refuses the same hash forever.
        address[] memory tokens = _bandTokens();
        uint256[] memory amounts = _bandAmounts(10 * USDC_ONE);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MockAqua.StrategiesMustBeImmutable.selector, address(router), hash));
        vault.execShip(bytes("band-1"), tokens, amounts);
    }

    function test_revokeAquaApproval_completesTheEmergencyStop() public {
        _seed(100 * USDC_ONE);
        _ship("band-1", 10 * USDC_ONE);
        assertEq(usdc.allowance(address(vault), address(aqua)), type(uint256).max);

        vm.prank(owner);
        vault.dockAll();
        vm.prank(owner);
        vault.revokeAquaApproval(IERC20(address(usdc)), 0);

        assertEq(usdc.allowance(address(vault), address(aqua)), 0);
    }

    // -------------------------------------------------------------------------------------------
    // VLT-R9: the just-in-time settlement path
    // -------------------------------------------------------------------------------------------

    /// @notice The money shot, in one transaction: the hook withdraws exactly the shortfall from the
    ///         carry venue, Aqua pulls the USDC out to the taker, and the taker's WETH lands in the
    ///         vault. NAV is preserved and the sleeve is only drained by what the fill needed.
    function test_jitPath_unparksExactShortfallInsideTheFill() public {
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(95 * USDC_ONE); // 5 USDC hot buffer, 95 earning

        (bytes32 hash,,) = _ship("band-1", 50 * USDC_ONE);

        uint256 amountOut = 30 * USDC_ONE; // fill much larger than the buffer
        uint256 amountIn = WETH_ONE / 100; // 0.01 WETH at 3000 USD = 30 USDC
        weth.mint(taker, amountIn);
        vm.prank(taker);
        weth.approve(address(router), amountIn);

        uint256 navBefore = vault.totalAssets();

        vm.prank(taker);
        vm.expectEmit(true, true, false, true, address(vault));
        emit PartyVault.JitUnparked(address(usdc), 25 * USDC_ONE, hash);
        router.settle(address(vault), hash, address(weth), address(usdc), amountIn, amountOut);

        // Exactly the shortfall left the venue: 30 needed, 5 in the buffer.
        assertEq(adapter.parkedBalance(address(usdc)), 70 * USDC_ONE, "only the shortfall unparked");
        assertEq(usdc.balanceOf(address(vault)), 0, "buffer spent by the fill");
        assertEq(usdc.balanceOf(taker), amountOut, "taker got USDC");
        assertEq(weth.balanceOf(address(vault)), amountIn, "vault got WETH");
        assertEq(vault.totalAssets(), navBefore, "NAV preserved at oracle price");

        (uint248 remaining,) = aqua.rawBalances(address(vault), address(router), hash, address(usdc));
        assertEq(remaining, 20 * USDC_ONE, "virtual balance decremented by the pull");
    }

    function test_jitPath_doesNotTouchTheVenueWhenTheBufferCovers() public {
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(50 * USDC_ONE);

        (bytes32 hash,,) = _ship("band-1", 50 * USDC_ONE);

        uint256 amountOut = 10 * USDC_ONE;
        uint256 amountIn = WETH_ONE / 300;
        weth.mint(taker, amountIn);
        vm.prank(taker);
        weth.approve(address(router), amountIn);

        vm.prank(taker);
        router.settle(address(vault), hash, address(weth), address(usdc), amountIn, amountOut);

        assertEq(adapter.parkedBalance(address(usdc)), 50 * USDC_ONE, "venue untouched");
        assertEq(usdc.balanceOf(address(vault)), 40 * USDC_ONE);
    }

    function test_jitPath_revertsTheFillWhenTheVenueCannotServeIt() public {
        _seed(100 * USDC_ONE);
        vm.prank(owner);
        vault.parkUsdc(95 * USDC_ONE);

        (bytes32 hash,,) = _ship("band-1", 50 * USDC_ONE);
        adapter.setUnparkShouldFail(true);

        uint256 amountIn = WETH_ONE / 100;
        weth.mint(taker, amountIn);
        vm.prank(taker);
        weth.approve(address(router), amountIn);

        // The fill fails rather than settling against liquidity the vault does not have.
        vm.prank(taker);
        vm.expectRevert(MockCarryAdapter.UnparkFailed.selector);
        router.settle(address(vault), hash, address(weth), address(usdc), amountIn, 30 * USDC_ONE);
    }

    // -------------------------------------------------------------------------------------------
    // Sleeve management
    // -------------------------------------------------------------------------------------------

    function test_parkAndUnpark_areNavNeutral() public {
        _seed(100 * USDC_ONE);
        uint256 nav = vault.totalAssets();

        vm.prank(owner);
        vault.parkUsdc(90 * USDC_ONE);
        assertEq(vault.totalAssets(), nav);
        // The park allowance is fully consumed, nothing lingers.
        assertEq(usdc.allowance(address(vault), address(adapter)), 0);

        vm.prank(owner);
        vault.unparkUsdc(40 * USDC_ONE);
        assertEq(vault.totalAssets(), nav);
        assertEq(usdc.balanceOf(address(vault)), 50 * USDC_ONE);
        assertEq(adapter.parkedBalance(address(usdc)), 50 * USDC_ONE);
    }

    function test_zeroAmountsRevert() public {
        _seed(10 * USDC_ONE);
        vm.startPrank(owner);
        vm.expectRevert(PartyVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.expectRevert(PartyVault.ZeroAmount.selector);
        vault.redeem(0);
        vm.expectRevert(PartyVault.ZeroAmount.selector);
        vault.parkUsdc(0);
        vm.expectRevert(PartyVault.ZeroAmount.selector);
        vault.unparkUsdc(0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    function _fund(address who, uint256 amount) private {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    function _seed(uint256 amount) private {
        _fund(owner, amount);
        vm.prank(owner);
        vault.deposit(amount);
    }

    function _deposit(address who, uint256 amount) private returns (uint256 shares) {
        _fund(who, amount);
        vm.prank(who);
        shares = vault.deposit(amount);
    }

    function _bandTokens() private view returns (address[] memory tokens) {
        // PRG-R2: both tokens are always registered, the empty side at amount 0.
        tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
    }

    function _bandAmounts(uint256 usdcAmount) private pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = 0;
    }

    function _ship(bytes memory order, uint256 usdcAmount)
        private
        returns (bytes32 hash, address[] memory tokens, uint256[] memory amounts)
    {
        tokens = _bandTokens();
        amounts = _bandAmounts(usdcAmount);
        vm.prank(owner);
        hash = vault.execShip(order, tokens, amounts);
    }
}
