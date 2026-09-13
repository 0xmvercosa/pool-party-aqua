// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice ABI-only declarations matching SwapVM v1.0.2 (32c687c), with no upstream implementation vendored.
library CashPlusTypes {
    struct Order {
        address maker;
        uint256 traits;
        bytes data;
    }

    struct ProgramParameters {
        uint64 policyVersion;
        uint64 deadline;
        bytes32 salt;
        uint256 usdcVirtualBalance;
        uint256 secondaryVirtualBalance;
    }

    struct Policy {
        uint256 depositCap;
        uint256 minDeposit;
        uint16 maxFillBps;
        uint16 dailyBudgetBps;
        uint16 secondaryTargetBps;
        uint16 secondaryCapBps;
        uint16 baseSpreadBps;
        uint16 maxSurchargeBps;
        uint16 hotUsdcBps;
        uint16 hotSecondaryBps;
    }

    struct Config {
        address usdc;
        address secondary;
        address aqua;
        address router;
        address pool;
        address usdcAToken;
        address secondaryAToken;
        address usdcFeed;
        address secondaryFeed;
        address sequencerFeed;
        uint32 usdcMaxAge;
        uint32 secondaryMaxAge;
        uint32 maxFeedSkew;
        uint32 sequencerGrace;
        uint16 pegDeviationBps;
        address governance;
        address keeper;
        address guardian;
        uint256 hardDepositCap;
    }

    struct Status {
        bool initialized;
        bool depositsPaused;
        bool tradingPaused;
        bool emergencyMode;
        bool rebalanceRequired;
        bool valuationAvailable;
        uint8 settlementState;
        uint64 policyVersion;
        uint256 depositCap;
        uint256 minDeposit;
        uint256 assetsUsdc;
        uint256 shares;
        uint256 dailyBaselineUsdc;
        uint256 dailyVolumeUsdc;
        uint256 dailyRemainingUsdc;
        uint64 budgetDay;
    }

    struct InventoryItem {
        address token;
        address adapter;
        address receiptToken;
        uint8 decimals;
        uint256 walletBalance;
        uint256 adapterIdleBalance;
        uint256 lendingBalance;
        uint256 valueUsdc;
    }
}

struct SwapQuery {
    bytes32 orderHash;
    address maker;
    address taker;
    address tokenIn;
    address tokenOut;
    bool isExactIn;
}

struct SwapRegisters {
    uint256 balanceIn;
    uint256 balanceOut;
    uint256 amountIn;
    uint256 amountOut;
    uint256 amountNetPulled;
}

interface ICashPlusQuote {
    function quoteTrade(
        bytes32 orderHash,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64 version
    ) external view returns (uint256 amountOut);
}

interface ICashPlusRouter {
    function AQUA() external view returns (address);
    function hash(CashPlusTypes.Order calldata order) external view returns (bytes32);
    function quote(
        CashPlusTypes.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external view returns (uint256, uint256, bytes32);
    function swap(
        CashPlusTypes.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external returns (uint256, uint256, bytes32);
}
