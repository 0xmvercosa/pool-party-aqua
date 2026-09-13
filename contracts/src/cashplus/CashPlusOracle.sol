// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";
import { CashPlusTypes } from "./CashPlusTypes.sol";

/// @notice Immutable two-stablecoin Chainlink valuation with freshness, peg, skew and L2 sequencer checks.
contract CashPlusOracle {
    IPriceFeed public immutable USDC_FEED;
    IPriceFeed public immutable SECONDARY_FEED;
    IPriceFeed public immutable SEQUENCER_FEED;
    uint256 public immutable USDC_FEED_SCALE;
    uint256 public immutable SECONDARY_FEED_SCALE;
    uint256 public immutable SECONDARY_SCALE;
    uint8 public immutable SECONDARY_DECIMALS;
    uint32 public immutable USDC_MAX_AGE;
    uint32 public immutable SECONDARY_MAX_AGE;
    uint32 public immutable MAX_FEED_SKEW;
    uint32 public immutable SEQUENCER_GRACE;
    uint16 public immutable PEG_DEVIATION_BPS;

    error InvalidConfiguration();
    error InvalidOracle(address feed);
    error StaleOracle(address feed);
    error PegDeviation(address feed);
    error FeedSkew();
    error SequencerUnavailable();

    constructor(CashPlusTypes.Config memory c) {
        uint8 d0 = IPriceFeed(c.usdcFeed).decimals();
        uint8 d1 = IPriceFeed(c.secondaryFeed).decimals();
        uint8 ds = IERC20Metadata(c.secondary).decimals();
        if (
            IERC20Metadata(c.usdc).decimals() != 6 || d0 > 18 || d1 > 18 || ds > 18 || c.usdcMaxAge == 0
                || c.secondaryMaxAge == 0 || c.pegDeviationBps > 50 || c.maxFeedSkew == 0 || c.pegDeviationBps == 0
        ) revert InvalidConfiguration();
        USDC_FEED = IPriceFeed(c.usdcFeed);
        SECONDARY_FEED = IPriceFeed(c.secondaryFeed);
        SEQUENCER_FEED = IPriceFeed(c.sequencerFeed);
        USDC_FEED_SCALE = 10 ** (18 - d0);
        SECONDARY_FEED_SCALE = 10 ** (18 - d1);
        SECONDARY_SCALE = 10 ** ds;
        SECONDARY_DECIMALS = ds;
        USDC_MAX_AGE = c.usdcMaxAge;
        SECONDARY_MAX_AGE = c.secondaryMaxAge;
        MAX_FEED_SKEW = c.maxFeedSkew;
        SEQUENCER_GRACE = c.sequencerGrace;
        PEG_DEVIATION_BPS = c.pegDeviationBps;
    }

    function prices() public view returns (uint256 p0, uint256 p1) {
        if (address(SEQUENCER_FEED) != address(0)) {
            (, int256 answer, uint256 since, uint256 updated,) = SEQUENCER_FEED.latestRoundData();
            if (
                answer != 0 || since == 0 || since > block.timestamp || updated > block.timestamp
                    || block.timestamp - since <= SEQUENCER_GRACE
            ) revert SequencerUnavailable();
        }
        uint256 t0;
        uint256 t1;
        (p0, t0) = _read(USDC_FEED, USDC_FEED_SCALE, USDC_MAX_AGE);
        (p1, t1) = _read(SECONDARY_FEED, SECONDARY_FEED_SCALE, SECONDARY_MAX_AGE);
        if ((t0 > t1 ? t0 - t1 : t1 - t0) > MAX_FEED_SKEW) revert FeedSkew();
    }

    function valueSecondary(uint256 amount, uint256 p0, uint256 p1) public view returns (uint256) {
        return Math.mulDiv(amount, p1 * 1e6, p0 * SECONDARY_SCALE);
    }
    /// @notice Stable exact-input conversion with a bounded surcharge on pre-trade inventory.

    function priceTrade(CashPlusTypes.Policy calldata p, bool usdcIn, uint256 amount, uint256[4] calldata x)
        external
        view
        returns (uint256)
    {
        uint256 secondaryValue = valueSecondary(x[1], x[2], x[3]);
        uint256 weight = Math.mulDiv(usdcIn ? x[0] : secondaryValue, 10_000, x[0] + secondaryValue);
        uint256 target = usdcIn ? 10_000 - p.secondaryTargetBps : p.secondaryTargetBps;
        uint256 surcharge = weight > target ? Math.mulDiv(weight - target, p.maxSurchargeBps, 10_000 - target) : 0;
        uint256 fair =
            usdcIn ? Math.mulDiv(amount, x[2] * SECONDARY_SCALE, x[3] * 1e6) : valueSecondary(amount, x[2], x[3]);
        return Math.mulDiv(fair, 10_000 - p.baseSpreadBps - surcharge, 10_000);
    }

    error InvalidAmount();
    error FillLimit();
    error DailyBudget();
    error InsufficientCash();
    error InventoryLimit();
    /// @notice Stateless aggregate-risk math shared by quotes and hooks; x = in,out,h0,h1,p0,p1,dayBaseline,dayUsed.

    function validateTrade(CashPlusTypes.Policy calldata p, bool usdcIn, uint256[8] calldata x)
        external
        view
        returns (uint256 inputValue, uint256 outputValue)
    {
        if (x[1] == 0) revert InvalidAmount();
        inputValue = usdcIn ? x[0] : valueSecondary(x[0], x[4], x[5]);
        outputValue = usdcIn ? valueSecondary(x[1], x[4], x[5]) : x[1];
        uint256 h0 = x[2];
        uint256 h1 = x[3];
        uint256 nav = h0 + valueSecondary(h1, x[4], x[5]);
        if (inputValue > Math.mulDiv(nav, p.maxFillBps, 10_000)) revert FillLimit();
        if (x[7] + inputValue > Math.mulDiv(x[6], p.dailyBudgetBps, 10_000)) revert DailyBudget();
        if (usdcIn) {
            if (h1 < x[1]) revert InsufficientCash();
            h0 += x[0];
            h1 -= x[1];
        } else {
            if (h0 < x[1]) revert InsufficientCash();
            h0 -= x[1];
            h1 += x[0];
        }
        uint256 secondaryValue = valueSecondary(h1, x[4], x[5]);
        uint256 afterNav = h0 + secondaryValue;
        if (!usdcIn && secondaryValue > Math.mulDiv(afterNav, p.secondaryCapBps, 10_000)) revert InventoryLimit();
        uint256 buffer = Math.mulDiv(afterNav, usdcIn ? p.hotSecondaryBps : p.hotUsdcBps, 10_000);
        if (usdcIn) buffer = Math.mulDiv(buffer, x[4] * SECONDARY_SCALE, x[5] * 1e6, Math.Rounding.Ceil);
        if ((usdcIn ? h1 : h0) < buffer) revert InsufficientCash();
    }

    function _read(IPriceFeed feed, uint256 scale, uint256 maxAge) private view returns (uint256 p, uint256 at) {
        (uint80 round, int256 answer, uint256 started, uint256 updated, uint80 answered) = feed.latestRoundData();
        if (
            answer <= 0 || round == 0 || answered < round || updated == 0 || updated > block.timestamp
                || started > updated
        ) revert InvalidOracle(address(feed));
        if (block.timestamp - updated > maxAge) revert StaleOracle(address(feed));
        p = uint256(answer) * scale;
        uint256 diff = p > 1e18 ? p - 1e18 : 1e18 - p;
        if (diff > uint256(PEG_DEVIATION_BPS) * 1e14) revert PegDeviation(address(feed));
        at = updated;
    }
}
