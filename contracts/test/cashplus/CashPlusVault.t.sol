// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { CashPlusVault } from "../../src/cashplus/CashPlusVault.sol";
import { CashPlusOracle } from "../../src/cashplus/CashPlusOracle.sol";
import { CashPlusPricing } from "../../src/cashplus/CashPlusPricing.sol";
import { CashPlusDeploymentFactory } from "../../src/cashplus/CashPlusDeploymentFactory.sol";
import { CashPlusTypes as T, SwapQuery, SwapRegisters } from "../../src/cashplus/CashPlusTypes.sol";
import { CPToken, CPReceipt, CPPool, CPFeed, CPAqua, CPRouter } from "./CashPlusMocks.sol";

contract CashPlusVaultTest is Test {
    CashPlusVault internal v;
    CPToken internal usdc;
    CPToken internal sec;
    CPPool internal pool;
    CPReceipt internal a0;
    CPReceipt internal a1;
    CPFeed internal f0;
    CPFeed internal f1;
    CPFeed internal seq;
    CPAqua internal aqua;
    CPRouter internal router;
    address internal investor = address(0x100);
    address internal taker = address(0x200);
    address internal keeper = address(0x300);
    address internal guardian = address(0x400);
    uint256 internal saltCounter;

    function setUp() public {
        vm.warp(100 days);
        usdc = new CPToken(6);
        sec = new CPToken(18);
        pool = new CPPool();
        a0 = pool.register(address(usdc), 6);
        a1 = pool.register(address(sec), 18);
        f0 = new CPFeed(8, 1e8);
        f1 = new CPFeed(18, 1e18);
        seq = new CPFeed(0, 0);
        seq.set(0, block.timestamp - 3601);
        aqua = new CPAqua();
        router = new CPRouter(address(aqua));
        v = new CashPlusVault(_config(), _policy());
        usdc.mint(address(v), 1000e6);
        v.initialize(address(this), 1000e6);
        usdc.mint(investor, 100_000e6);
        usdc.mint(taker, 100_000e6);
        sec.mint(taker, 100_000e18);
        vm.prank(investor);
        usdc.approve(address(v), type(uint256).max);
        vm.startPrank(taker);
        usdc.approve(address(router), type(uint256).max);
        sec.approve(address(router), type(uint256).max);
        vm.stopPrank();
        v.setAllowedTaker(taker, true);
    }

    function _config() internal view returns (T.Config memory) {
        return T.Config(
            address(usdc),
            address(sec),
            address(aqua),
            address(router),
            address(pool),
            address(a0),
            address(a1),
            address(f0),
            address(f1),
            address(seq),
            90_000,
            90_000,
            90_000,
            3600,
            50,
            address(this),
            keeper,
            guardian,
            1_000_000e6
        );
    }

    function _policy() internal pure returns (T.Policy memory) {
        return T.Policy(1_000_000e6, 1e6, 100, 2000, 1000, 2000, 5, 10, 500, 0);
    }

    function _deposit(uint256 a) internal returns (uint256 q) {
        uint64 version = v.policyVersion();
        vm.prank(investor);
        q = v.deposit(a, 1, uint64(block.timestamp + 60), version);
    }

    function _params() internal returns (T.ProgramParameters memory) {
        return T.ProgramParameters(
            v.policyVersion(),
            uint64(block.timestamp + 300),
            bytes32(++saltCounter),
            usdc.balanceOf(address(v)) + a0.balanceOf(address(v.USDC_ADAPTER())),
            sec.balanceOf(address(v)) + a1.balanceOf(address(v.SECONDARY_ADAPTER()))
        );
    }

    function _ship() internal returns (bytes32) {
        return v.shipCanonical(_params());
    }

    function _fill(bytes32 h, bool usdcIn, uint256 n) internal returns (uint256) {
        vm.prank(taker);
        return router.fill(v, h, usdcIn ? address(usdc) : address(sec), usdcIn ? address(sec) : address(usdc), n, true);
    }

    function test_seedLockedAndLifetimeCashflows() public {
        assertEq(_deposit(500e6), 500e18);
        address locked = v.SEED_HOLDER();
        vm.prank(locked);
        vm.expectRevert(CashPlusVault.InsufficientShares.selector);
        v.redeem(1, 0, uint64(block.timestamp + 60), 1);
        vm.prank(investor);
        assertEq(v.redeemAll(500e6, uint64(block.timestamp + 60), 1), 500e6);
        assertEq(v.totalShares(), 1000e18);
        _deposit(100e6);
        (uint256 d, uint256 w, bool incomplete) = v.accountCashflows(investor);
        assertEq(d, 600e6);
        assertEq(w, 500e6);
        assertFalse(incomplete);
    }

    function testFuzz_roundTripSeedAndDonation(uint96 r, uint96 dr) public {
        uint256 a = bound(r, 1e6, 90_000e6);
        uint256 d = bound(dr, 0, 500_000e6);
        uint256 q = _deposit(a);
        usdc.mint(address(v), d);
        uint256 claim = v.previewRedeem(q);
        vm.prank(investor);
        assertEq(v.redeemAll(claim, uint64(block.timestamp + 60), 1), claim);
        assertEq(v.sharesOf(investor), 0);
        assertEq(v.totalShares(), 1000e18);
        assertGe(v.totalAssets(), 1000e6);
        assertLe(claim, a + d);
    }

    function test_donationSlippageAndMinimum() public {
        uint256 q = v.previewDeposit(1e6);
        usdc.mint(address(v), 500_000e6);
        vm.prank(investor);
        vm.expectRevert(CashPlusVault.Slippage.selector);
        v.deposit(1e6, q, uint64(block.timestamp + 60), 1);
        vm.prank(investor);
        vm.expectRevert(CashPlusVault.InvalidAmount.selector);
        v.deposit(1, 0, uint64(block.timestamp + 60), 1);
        assertEq(v.sharesOf(investor), 0);
    }

    function test_mixedDecimalsPricesAndDonatedAdapterCash() public {
        sec.mint(address(v), 100e18);
        f1.set(1.004e18, block.timestamp);
        assertEq(v.totalAssets(), 1100.4e6);
        v.park(address(sec), 100e18);
        assertEq(v.totalAssets(), 1100.4e6);
        sec.mint(address(v.SECONDARY_ADAPTER()), 1e18);
        assertEq(v.totalAssets(), 1101.404e6);
    }

    function test_feeTransferRollsBack() public {
        usdc.setFee(1);
        uint256 beforeBalance = usdc.balanceOf(investor);
        vm.prank(investor);
        vm.expectRevert(CashPlusVault.TransferMismatch.selector);
        v.deposit(10e6, 1, uint64(block.timestamp + 60), 1);
        assertEq(usdc.balanceOf(investor), beforeBalance);
        assertEq(v.sharesOf(investor), 0);
    }

    function test_staleOracleAndEmergencyReceiptExitDuringAaveFailure() public {
        uint256 q = _deposit(1000e6);
        v.park(address(usdc), 1800e6);
        pool.setIlliquid(true);
        vm.warp(block.timestamp + 90_001);
        T.Status memory s = v.status();
        assertFalse(s.valuationAvailable);
        assertEq(s.depositCap, 1_000_000e6);
        vm.prank(investor);
        vm.expectRevert();
        v.redeemAll(0, uint64(block.timestamp + 60), 1);
        vm.prank(guardian);
        v.setEmergencyMode(true);
        uint256[] memory mins = v.previewProportional(q);
        vm.prank(investor);
        v.redeemProportional(q, mins, uint64(block.timestamp + 60));
        assertEq(a0.balanceOf(investor), 900e6);
        assertEq(v.sharesOf(investor), 0);
        (,, bool incomplete) = v.accountCashflows(investor);
        assertTrue(incomplete);
    }

    function test_proportionalComponentsAndAccounting() public {
        uint256 q = _deposit(1000e6);
        sec.mint(address(v), 100e18);
        v.park(address(usdc), 1500e6);
        v.park(address(sec), 80e18);
        usdc.mint(address(v.USDC_ADAPTER()), 10e6);
        uint256[] memory amounts = v.previewProportional(q);
        vm.prank(investor);
        v.redeemProportional(q, amounts, uint64(block.timestamp + 60));
        assertEq(amounts[0], 255e6);
        assertEq(amounts[1], 10e18);
        assertEq(amounts[2], 750e6);
        assertEq(amounts[3], 40e18);
        (, uint256 w, bool incomplete) = v.accountCashflows(investor);
        assertEq(w, 1055e6);
        assertFalse(incomplete);
    }

    function test_priceQuoteMatchesJitSettlement() public {
        sec.mint(address(v), 100e18);
        v.park(address(sec), 100e18);
        bytes32 h = _ship();
        vm.prank(taker);
        uint256 quote = router.quote(v, h, address(usdc), address(sec), 10e6);
        uint256 nav = v.totalAssets();
        uint256 out = _fill(h, true, 10e6);
        assertEq(out, quote);
        assertEq(out, 9.995e18);
        assertEq(sec.balanceOf(address(v)), 0);
        assertEq(a1.balanceOf(address(v.SECONDARY_ADAPTER())), 100e18 - out);
        assertEq(v.dailyVolumeUsdc(), 10e6);
        assertEq(uint256(v.settlementState()), 0);
        assertEq(sec.allowance(address(v), address(aqua)), 0);
        assertEq(v.totalAssets(), nav + 5000);
    }

    function test_outputFirstAndAaveFailureRollback() public {
        sec.mint(address(v), 100e18);
        v.park(address(sec), 100e18);
        bytes32 h = _ship();
        vm.prank(taker);
        vm.expectRevert(CashPlusVault.HookSequence.selector);
        router.fill(v, h, address(usdc), address(sec), 1e6, false);
        pool.setIlliquid(true);
        uint256 beforeBalance = usdc.balanceOf(taker);
        vm.expectRevert(CPPool.Illiquid.selector);
        _fill(h, true, 10e6);
        assertEq(usdc.balanceOf(taker), beforeBalance);
        assertEq(v.dailyVolumeUsdc(), 0);
        assertEq(uint256(v.settlementState()), 0);
    }

    function test_crossOrderAndCrossFunctionReentrancy() public {
        sec.mint(address(v), 100e18);
        bytes32 h = _ship();
        bytes32 h2 = _ship();
        router.setAttack(1, h2);
        vm.expectRevert(CashPlusVault.SettlementBusy.selector);
        _fill(h, true, 1e6);
        router.setAttack(2, h2);
        vm.expectRevert(CashPlusVault.SettlementBusy.selector);
        _fill(h, true, 1e6);
        assertEq(v.dailyVolumeUsdc(), 0);
    }

    function test_dayBudgetPersistsAcrossOrdersDepositsAndCaps() public {
        T.Policy memory p = _policy();
        p.dailyBudgetBps = 100;
        v.setPolicy(p);
        sec.mint(address(v), 100e18);
        bytes32 h = _ship();
        _fill(h, true, 10e6);
        h = _ship();
        _deposit(1000e6);
        v.lowerDepositCap(3000e6);
        assertEq(v.dailyBaselineUsdc(), 1000e6);
        assertEq(v.dailyVolumeUsdc(), 10e6);
        vm.expectRevert(CashPlusVault.DailyBudget.selector);
        _fill(h, true, 1e6);
    }

    function test_aggregateInventoryAndFillLimit() public {
        sec.mint(address(v), 249e18);
        bytes32 h = _ship();
        vm.expectRevert(CashPlusVault.FillLimit.selector);
        _fill(h, false, 100e18);
        vm.expectRevert(CashPlusVault.InventoryLimit.selector);
        _fill(h, false, 2e18);
        _fill(h, true, 1e6);
    }

    function test_cashExitAllowsIncreasedConcentrationAndRiskBlocksIncrease() public {
        _deposit(1000e6);
        sec.mint(address(v), 400e18);
        bytes32 h = _ship();
        vm.prank(investor);
        v.redeemAll(1200e6, uint64(block.timestamp + 60), 1);
        assertTrue(v.rebalanceRequired());
        vm.expectRevert(CashPlusVault.InventoryLimit.selector);
        _fill(h, false, 1e18);
        _fill(h, true, 1e6);
    }

    function test_rolesPolicyAndDeadlines() public {
        vm.prank(keeper);
        vm.expectRevert(CashPlusVault.Unauthorized.selector);
        v.setAllowedTaker(investor, true);
        vm.prank(keeper);
        v.setPause(true, true);
        vm.prank(guardian);
        vm.expectRevert(CashPlusVault.Unauthorized.selector);
        v.setPause(false, false);
        v.setPause(false, false);
        T.Policy memory p = _policy();
        p.maxFillBps = 101;
        vm.expectRevert(CashPlusVault.InvalidPolicy.selector);
        v.setPolicy(p);
        vm.prank(investor);
        vm.expectRevert(CashPlusVault.PolicyChanged.selector);
        v.deposit(1e6, 1, uint64(block.timestamp + 1), 2);
        vm.prank(investor);
        vm.expectRevert(CashPlusVault.DeadlineExpired.selector);
        v.deposit(1e6, 1, uint64(block.timestamp - 1), 1);
    }

    function test_oracleGuards() public {
        f0.set(0, block.timestamp);
        vm.expectPartialRevert(CashPlusOracle.InvalidOracle.selector);
        v.totalAssets();
        f0.set(1e8, block.timestamp + 1);
        vm.expectPartialRevert(CashPlusOracle.InvalidOracle.selector);
        v.totalAssets();
        f0.set(1.006e8, block.timestamp);
        vm.expectPartialRevert(CashPlusOracle.PegDeviation.selector);
        v.totalAssets();
        f0.set(1e8, block.timestamp);
        f0.setRound(2, 1);
        vm.expectPartialRevert(CashPlusOracle.InvalidOracle.selector);
        v.totalAssets();
        f0.setRound(2, 2);
        seq.set(1, block.timestamp - 4000);
        vm.expectRevert(CashPlusOracle.SequencerUnavailable.selector);
        v.totalAssets();
        seq.set(0, block.timestamp - 3600);
        vm.expectRevert(CashPlusOracle.SequencerUnavailable.selector);
        v.totalAssets();
    }

    function test_factoryGoldenBytesAndExactOutputRejection() public {
        T.ProgramParameters memory p = _params();
        T.Order memory o = v.PROGRAM_FACTORY().build(p);
        assertEq(
            o.data,
            abi.encodePacked(
                uint8(13),
                uint8(5),
                uint40(p.deadline),
                uint8(32),
                uint8(28),
                address(v.PRICING()),
                uint64(1),
                uint8(20),
                uint8(32),
                p.salt
            )
        );
        assertEq(o.traits, (1 << 254) | (1 << 252) | (1 << 251) | (1 << 250) | (1 << 249));
        assertEq(o.data.length, 71);
        assertEq(v.PROGRAM_FACTORY().hash(p), keccak256(abi.encode(o)));
        SwapQuery memory q = SwapQuery(bytes32(0), address(v), taker, address(usdc), address(sec), false);
        SwapRegisters memory s = SwapRegisters(0, 100e18, 0, 1e18, 0);
        CashPlusPricing pricing = v.PRICING();
        vm.prank(address(router));
        vm.expectRevert(CashPlusPricing.ExactOutputUnsupported.selector);
        pricing.extruction(true, 0, q, s, abi.encodePacked(uint64(1)), "");
    }

    function test_atomicFactoryAndPrefundingFailure() public {
        CashPlusDeploymentFactory factory = new CashPlusDeploymentFactory();
        bytes memory code = abi.encodePacked(type(CashPlusVault).creationCode, abi.encode(_config(), _policy()));
        usdc.mint(address(this), 2000e6);
        usdc.approve(address(factory), 2000e6);
        address predicted = factory.predict(address(this), bytes32(uint256(1)), keccak256(code));
        address deployed = factory.deploy(code, address(usdc), 1000e6, bytes32(uint256(1)));
        assertEq(deployed, predicted);
        assertTrue(CashPlusVault(deployed).initialized());
        predicted = factory.predict(address(this), bytes32(uint256(2)), keccak256(code));
        usdc.mint(predicted, 1);
        vm.expectRevert(CashPlusDeploymentFactory.DeploymentFailed.selector);
        factory.deploy(code, address(usdc), 1000e6, bytes32(uint256(2)));
    }

    function test_receiptMinimumUsesActualReceivedBalance() public {
        uint256 shares = _deposit(1000e6);
        v.park(address(usdc), 1500e6);
        uint256[] memory minimums = v.previewProportional(shares);
        a0.setFee(1);
        vm.prank(investor);
        vm.expectRevert(bytes4(keccak256("AmountMismatch()")));
        v.redeemProportional(shares, minimums, uint64(block.timestamp + 60));
        assertEq(v.sharesOf(investor), shares);
        assertEq(a0.balanceOf(investor), 0);
    }

    function testFuzz_twoDirectionsQuoteAndActualMargin(bool usdcIn, uint64 raw) public {
        uint256 amount = bound(raw, 1e6, 10e6);
        sec.mint(address(v), 100e18);
        bytes32 hash = _ship();
        uint256 beforeNav = v.totalAssets();
        uint256 out = _fill(hash, usdcIn, usdcIn ? amount : amount * 1e12);
        assertEq(out, usdcIn ? amount * 1e12 * 9995 / 10_000 : amount * 9995 / 10_000);
        assertGe(v.totalAssets(), beforeNav);
        assertEq(v.dailyVolumeUsdc(), amount);
    }

    function test_cashLiquidityFailurePreservesSharesAndCashflows() public {
        uint256 shares = _deposit(1000e6);
        v.park(address(usdc), 1800e6);
        pool.setIlliquid(true);
        vm.prank(investor);
        vm.expectRevert(CPPool.Illiquid.selector);
        v.redeemAll(0, uint64(block.timestamp + 60), 1);
        assertEq(v.sharesOf(investor), shares);
        (, uint256 withdrawn,) = v.accountCashflows(investor);
        assertEq(withdrawn, 0);
    }

    function test_policyChangeInvalidatesOldCanonicalOrder() public {
        sec.mint(address(v), 100e18);
        bytes32 hash = _ship();
        v.setPolicy(_policy());
        vm.expectRevert(CashPlusVault.PolicyChanged.selector);
        _fill(hash, true, 1e6);
        assertEq(v.dailyVolumeUsdc(), 0);
    }
}
