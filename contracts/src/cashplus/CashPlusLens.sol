// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { CashPlusTypes as T } from "./CashPlusTypes.sol";
import { CashPlusAaveAdapter } from "./CashPlusAaveAdapter.sol";
import { CashPlusOracle } from "./CashPlusOracle.sol";

interface ICashPlusViews {
    function initialized() external view returns (bool);
    function depositsPaused() external view returns (bool);
    function tradingPaused() external view returns (bool);
    function emergencyMode() external view returns (bool);
    function rebalanceRequired() external view returns (bool);
    function settlementState() external view returns (uint8);
    function policyVersion() external view returns (uint64);
    function policy() external view returns (T.Policy memory);
    function totalShares() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function dailyBaselineUsdc() external view returns (uint256);
    function dailyVolumeUsdc() external view returns (uint256);
    function budgetDay() external view returns (uint64);
    function USDC() external view returns (IERC20);
    function SECONDARY_STABLE() external view returns (IERC20);
    function USDC_ADAPTER() external view returns (CashPlusAaveAdapter);
    function SECONDARY_ADAPTER() external view returns (CashPlusAaveAdapter);
    function ORACLE() external view returns (CashPlusOracle);
}
/// @notice Immutable read-only projection, separated to keep custody contract within EIP-170.

contract CashPlusLens {
    ICashPlusViews public immutable VAULT;

    constructor(address vault) {
        VAULT = ICashPlusViews(vault);
    }

    function status() external view returns (T.Status memory s) {
        ICashPlusViews v = VAULT;
        T.Policy memory p = v.policy();
        s.initialized = v.initialized();
        s.depositsPaused = v.depositsPaused();
        s.tradingPaused = v.tradingPaused();
        s.emergencyMode = v.emergencyMode();
        s.rebalanceRequired = v.rebalanceRequired();
        s.settlementState = v.settlementState();
        s.policyVersion = v.policyVersion();
        s.depositCap = p.depositCap;
        s.minDeposit = p.minDeposit;
        s.shares = v.totalShares();
        s.dailyBaselineUsdc = v.dailyBaselineUsdc();
        s.dailyVolumeUsdc = v.dailyVolumeUsdc();
        s.budgetDay = v.budgetDay();
        try v.totalAssets() returns (uint256 a) {
            s.assetsUsdc = a;
            s.valuationAvailable = true;
        } catch { }
        uint256 limit = Math.mulDiv(s.dailyBaselineUsdc, p.dailyBudgetBps, 10_000);
        s.dailyRemainingUsdc = limit > s.dailyVolumeUsdc ? limit - s.dailyVolumeUsdc : 0;
    }

    function checkpointData()
        external
        view
        returns (uint256 assets, uint256 index0, uint256 index1, bool valued, bool rebalance)
    {
        ICashPlusViews v = VAULT;
        try v.totalAssets() returns (uint256 a) {
            assets = a;
            valued = true;
            T.InventoryItem[] memory items = this.inventory();
            T.Policy memory p = v.policy();
            rebalance = items[1].valueUsdc > Math.mulDiv(a, p.secondaryCapBps, 10_000);
        } catch { }
        index0 = v.USDC_ADAPTER().lendingIndex();
        CashPlusAaveAdapter secondary = v.SECONDARY_ADAPTER();
        if (address(secondary) != address(0)) index1 = secondary.lendingIndex();
    }

    function inventory() external view returns (T.InventoryItem[] memory items) {
        ICashPlusViews v = VAULT;
        CashPlusOracle oracle = v.ORACLE();
        uint256 p0;
        uint256 p1;
        try oracle.prices() returns (uint256 a, uint256 b) {
            p0 = a;
            p1 = b;
        } catch { }
        items = new T.InventoryItem[](2);
        for (uint256 i; i < 2; ++i) {
            IERC20 token = i == 0 ? v.USDC() : v.SECONDARY_STABLE();
            CashPlusAaveAdapter a = i == 0 ? v.USDC_ADAPTER() : v.SECONDARY_ADAPTER();
            items[i].token = address(token);
            items[i].adapter = address(a);
            items[i].decimals = i == 0 ? 6 : oracle.SECONDARY_DECIMALS();
            items[i].walletBalance = token.balanceOf(address(v));
            if (address(a) != address(0)) {
                items[i].receiptToken = address(a.A_TOKEN());
                items[i].adapterIdleBalance = a.idleBalance();
                items[i].lendingBalance = a.parkedBalance();
            }
            uint256 holdings = items[i].walletBalance + items[i].adapterIdleBalance + items[i].lendingBalance;
            if (p0 != 0) items[i].valueUsdc = i == 0 ? holdings : oracle.valueSecondary(holdings, p0, p1);
        }
    }
}
