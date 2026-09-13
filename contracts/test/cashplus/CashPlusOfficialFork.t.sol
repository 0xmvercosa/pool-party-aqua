// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CashPlusVault } from "../../src/cashplus/CashPlusVault.sol";
import { CashPlusTypes as T, ICashPlusRouter } from "../../src/cashplus/CashPlusTypes.sol";

/// @notice Execute real deployed SwapVM v1.0.2, Aqua, USD₮0 and Aave; never a mock-router certification.
contract CashPlusOfficialForkTest is Test {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant SECONDARY = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    CashPlusVault v;
    address investor = address(0x1111);
    address taker = address(0x2222);

    function setUp() public {
        string memory rpc = vm.envOr("CASH_PLUS_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        T.Config memory c = T.Config(
            USDC,
            SECONDARY,
            AQUA,
            ROUTER,
            0x794a61358D6845594F94dc1DB02A252b5b4814aD,
            0x724dc807b04555b71ed48a6896b6F41593b8C637,
            0x6ab707Aca953eDAeFBc4fD23bA73294241490620,
            0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3,
            0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7,
            0xFdB631F5EE196F0ed6FAa767959853A9F217697D,
            90_000,
            90_000,
            90_000,
            3600,
            50,
            address(this),
            address(this),
            address(this),
            1_000_000e6
        );
        T.Policy memory p = T.Policy(1_000_000e6, 1e6, 100, 2000, 1000, 2000, 5, 10, 500, 0);
        v = new CashPlusVault{ salt: keccak256("cashplus-official-v1-fork-rehearsal") }(c, p);
        deal(USDC, address(v), 1000e6);
        v.initialize(address(this), 1000e6);
        deal(USDC, investor, 9000e6);
        vm.startPrank(investor);
        IERC20(USDC).approve(address(v), 9000e6);
        v.deposit(9000e6, 9000e18, uint64(block.timestamp + 300), 1);
        vm.stopPrank();
        deal(SECONDARY, address(v), 1000e6);
        deal(USDC, taker, 1000e6);
        deal(SECONDARY, taker, 1000e6);
        vm.startPrank(taker);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        IERC20(SECONDARY).approve(ROUTER, type(uint256).max);
        vm.stopPrank();
        v.setAllowedTaker(taker, true);
    }

    function _ship(uint256 nonce) internal returns (T.Order memory order, bytes32 hash) {
        T.ProgramParameters memory p =
            T.ProgramParameters(1, uint64(block.timestamp + 300), bytes32(nonce), 9999e6, 999e6);
        order = v.PROGRAM_FACTORY().build(p);
        hash = v.shipCanonical(p);
        assertEq(ICashPlusRouter(ROUTER).hash(order), hash);
        assertEq(keccak256(abi.encode(order)), hash);
    }

    function _traits(bool first, bool exactIn, uint256 minimum) internal view returns (bytes memory) {
        // Official 22-byte TakerTraits header: threshold ends32, receiver omitted, deadline ends37, other slices empty.
        uint160 offsets = uint160(32) | (uint160(32) << 16);
        for (uint256 i = 2; i < 10; ++i) {
            offsets |= uint160(uint256(37) << (16 * i));
        }
        return abi.encodePacked(
            offsets, uint16((exactIn ? 1 : 0) | (first ? 0x20 : 0) | 0x40), minimum, uint40(block.timestamp + 300)
        );
    }

    function testFork_officialQuoteSwapAaveJitAndCashExit() public {
        v.park(SECONDARY, 1000e6);
        v.park(USDC, 9000e6);
        (T.Order memory order, bytes32 hash) = _ship(1);
        vm.prank(taker);
        (uint256 input, uint256 out, bytes32 quotedHash) =
            ICashPlusRouter(ROUTER).quote(order, USDC, SECONDARY, 100e6, _traits(true, true, 1));
        assertEq(input, 100e6);
        assertEq(quotedHash, hash);
        assertGt(out, 99e6);
        assertLt(out, 100e6);
        uint256 parkedBefore = v.SECONDARY_ADAPTER().parkedBalance();
        uint256 navBefore = v.totalAssets();
        uint256 takerBefore = IERC20(SECONDARY).balanceOf(taker);
        vm.prank(taker);
        (uint256 filledIn, uint256 filledOut,) =
            ICashPlusRouter(ROUTER).swap(order, USDC, SECONDARY, 100e6, _traits(true, true, out));
        assertEq(filledIn, input);
        assertEq(filledOut, out);
        assertEq(IERC20(SECONDARY).balanceOf(taker) - takerBefore, out);
        assertApproxEqAbs(parkedBefore - v.SECONDARY_ADAPTER().parkedBalance(), out, 1);
        assertEq(IERC20(SECONDARY).balanceOf(address(v)), 0);
        assertEq(v.dailyVolumeUsdc(), 100e6);
        assertGt(v.totalAssets(), navBefore);
        assertEq(IERC20(SECONDARY).allowance(address(v), AQUA), 0);
        vm.prank(investor);
        uint256 redeemed = v.redeemAll(9000e6, uint64(block.timestamp + 300), 1);
        assertGt(redeemed, 9000e6);
        assertEq(v.sharesOf(investor), 0);
        assertEq(v.totalShares(), 1000e18);
    }

    function testFork_outputFirstAndOversizedRejected() public {
        (T.Order memory order,) = _ship(1);
        vm.prank(taker);
        vm.expectRevert(CashPlusVault.HookSequence.selector);
        ICashPlusRouter(ROUTER).swap(order, USDC, SECONDARY, 1e6, _traits(false, true, 1));
        vm.prank(taker);
        vm.expectRevert(CashPlusVault.FillLimit.selector);
        ICashPlusRouter(ROUTER).quote(order, USDC, SECONDARY, 1000e6, _traits(true, true, 1));
        assertEq(v.dailyVolumeUsdc(), 0);
    }

    function testFork_aTokenProportionalTransfers() public {
        v.park(USDC, 9000e6);
        v.park(SECONDARY, 1000e6);
        uint256 q = v.sharesOf(investor);
        uint256[] memory expected = v.previewProportional(q);
        vm.prank(investor);
        v.redeemProportional(q, expected, uint64(block.timestamp + 300));
        assertApproxEqAbs(IERC20(address(v.USDC_ADAPTER().A_TOKEN())).balanceOf(investor), expected[2], 1);
        assertApproxEqAbs(IERC20(address(v.SECONDARY_ADAPTER().A_TOKEN())).balanceOf(investor), expected[3], 1);
        assertEq(v.sharesOf(investor), 0);
    }

    function testFork_AaveWithdrawalFailureRollsBackOfficialInput() public {
        v.park(SECONDARY, 1000e6);
        (T.Order memory order,) = _ship(99);
        address pool = address(v.SECONDARY_ADAPTER().POOL());
        uint256 beforeBalance = IERC20(USDC).balanceOf(taker);
        // Selector-wide outage represents a reserve that refuses the requested withdrawal.
        vm.mockCallRevert(
            pool,
            abi.encodeWithSignature("withdraw(address,uint256,address)"),
            abi.encodeWithSignature("ReserveUnavailable()")
        );
        vm.prank(taker);
        vm.expectRevert(bytes4(keccak256("ReserveUnavailable()")));
        ICashPlusRouter(ROUTER).swap(order, USDC, SECONDARY, 100e6, _traits(true, true, 1));
        assertEq(IERC20(USDC).balanceOf(taker), beforeBalance);
        assertEq(v.dailyVolumeUsdc(), 0);
        assertEq(uint256(v.settlementState()), 0);
        vm.clearMockedCalls();
    }
}
