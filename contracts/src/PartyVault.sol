// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IAqua } from "./interfaces/IAqua.sol";
import { ICarryAdapter } from "./interfaces/ICarryAdapter.sol";
import { IMakerHooks } from "./interfaces/IMakerHooks.sol";
import { IPriceFeed } from "./interfaces/IPriceFeed.sol";

/// @title PartyVault
/// @notice Pooled-custody maker for Active Reserve: it holds investor USDC, keeps the idle sleeve
///         earning in a carry venue, quotes a buy band on 1inch Aqua, and withdraws from the venue
///         inside the settlement transaction when a fill lands.
/// @dev Scope is the approved 20-hour demo minimum of rules VLT-R1..R11
///      (`docs/01_BUSINESS_RULES.md`, VLT window-cut note):
///
///      IN: ERC-4626 conversion math with a +3 decimals offset (VLT-R1), manager seeds first
///      (VLT-R2), internal non-transferable share ledger with 4626-shaped views and events
///      (VLT-R3), `totalAssets` over the USDC buffer plus the parked sleeve plus WETH at Chainlink
///      (VLT-R4 without the in-vault staleness gate), USDC-only redemption gated by
///      `InsufficientLiquidUsdc` (VLT-R5), `execShip`/`execDock` under a single owner (VLT-R7
///      reduced), the pre-transfer-out settlement hook restricted to the canonical router
///      (VLT-R9), `maxTvl` (VLT-R10 reduced), `dockAll` (VLT-R11).
///
///      OUT, by decision, and named in the README as designed but not shipped in the window: the
///      in-vault Chainlink staleness gate (the status script reads the feed off chain), lockup
///      (VLT-R6), the separate keeper role (VLT-R7 split), the high-water-mark performance fee
///      (VLT-R8), `maxPerShip`, and the token allowlist. In-window capital is the manager's own
///      seed of 50 to 200 USD under `maxTvl`, which is what makes those cuts acceptable.
///
///      Custody: funds only ever leave through `redeem` to the share holder, through Aqua
///      settlement against a strategy the owner shipped, or into the carry adapter. There is no
///      path that sends an arbitrary amount to an arbitrary address, no upgradability, and no
///      pause-and-take. Emergency stop is `dockAll()` plus `revokeAquaApproval()`.
contract PartyVault is IMakerHooks, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Anti-inflation decimals offset applied to the internal share ledger (VLT-R1).
    /// @dev Same defense as OpenZeppelin ERC4626's `_decimalsOffset`: shares carry three more
    ///      decimals than the asset, so a first-depositor donation cannot round a later depositor
    ///      down to zero shares.
    uint8 public constant DECIMALS_OFFSET = 3;

    /// @notice Virtual share supply implied by {DECIMALS_OFFSET}.
    uint256 private constant _VIRTUAL_SHARES = 10 ** uint256(DECIMALS_OFFSET);

    /// @notice The deposit asset and the only redemption asset (VLT-R1, VLT-R5).
    IERC20 public immutable USDC;

    /// @notice The second token the Aqua strategies register, acquired when the band fills.
    IERC20 public immutable WETH;

    /// @notice The Aqua shared-liquidity registry this vault ships strategies to (gen 2).
    IAqua public immutable AQUA;

    /// @notice The SwapVM router that is the Aqua "app" for every strategy, and the only address
    ///         allowed to call the settlement hook (gen 2).
    address public immutable ROUTER;

    /// @notice Venue that holds the idle USDC sleeve.
    ICarryAdapter public immutable ADAPTER;

    /// @notice Chainlink ETH/USD feed used to value the WETH leg of `totalAssets`.
    IPriceFeed public immutable PRICE_FEED;

    /// @notice Single privileged address for the window: seeds the vault, ships, docks, and moves
    ///         the sleeve in and out of the carry venue. Immutable, so there is no ownership
    ///         transfer or renounce surface; key rotation means a new deployment.
    address public immutable OWNER;

    /// @notice Decimals of the internal share unit, asset decimals plus {DECIMALS_OFFSET}.
    uint8 public immutable shareDecimals;

    /// @dev `10 ** (feedDecimals + wethDecimals - usdcDecimals)`, precomputed WETH to USDC scale.
    uint256 private immutable _WETH_TO_USDC_DENOM;

    /// @notice Total internal shares outstanding.
    uint256 public totalShares;

    /// @notice Deposit cap expressed in USDC, checked against post-deposit `totalAssets` (VLT-R10).
    uint256 public maxTvl;

    /// @notice True once the manager seed deposit landed (VLT-R2).
    bool public seeded;

    /// @dev Internal, non-transferable share ledger. No ERC-20 interface by design (VLT-R3).
    mapping(address investor => uint256 shares) private _sharesOf;

    /// @dev Bookkeeping for docking: Aqua requires the full token list of a strategy at dock time.
    struct StrategyRecord {
        address[] tokens;
        uint256 indexPlusOne;
    }

    /// @dev strategyHash => record. `indexPlusOne == 0` means "not active".
    mapping(bytes32 strategyHash => StrategyRecord record) private _strategies;

    /// @dev Active strategy hashes, iterated by {dockAll}.
    bytes32[] private _activeStrategies;

    /// @notice Emitted on every deposit (VLT-R3).
    event Deposited(address indexed investor, uint256 assets, uint256 shares);

    /// @notice Emitted on every redemption (VLT-R3).
    event Redeemed(address indexed investor, uint256 assets, uint256 shares);

    /// @notice Emitted when the deposit cap changes.
    event MaxTvlUpdated(uint256 maxTvl);

    /// @notice Emitted when a strategy is shipped to Aqua.
    event StrategyShipped(bytes32 indexed strategyHash, address[] tokens, uint256[] amounts);

    /// @notice Emitted when a strategy is docked.
    event StrategyDocked(bytes32 indexed strategyHash);

    /// @notice Emitted when the owner moves USDC into the carry venue.
    event Parked(address indexed token, uint256 amount);

    /// @notice Emitted when the owner pulls USDC back out of the carry venue.
    event Unparked(address indexed token, uint256 amount);

    /// @notice Emitted when the settlement hook withdrew from the carry venue inside a fill.
    /// @dev This is the just-in-time event: it appears in the same transaction as Aqua's `Pulled`.
    event JitUnparked(address indexed token, uint256 amount, bytes32 indexed strategyHash);

    /// @notice Emitted when the Aqua allowance for a token is set.
    event AquaApprovalSet(address indexed token, uint256 amount);

    /// @notice Caller is not {OWNER}.
    error NotOwner(address caller);
    /// @notice Settlement hook called by something other than {ROUTER}.
    error NotRouter(address caller);
    /// @notice Settlement hook invoked for an order whose maker is not this vault.
    error NotOurOrder(address maker);
    /// @notice Zero amount passed where a positive amount is required.
    error ZeroAmount();
    /// @notice Deposit would round down to zero shares.
    error ZeroShares();
    /// @notice Redemption would round down to zero assets.
    error ZeroAssets();
    /// @notice A non-manager tried to deposit before the manager seed (VLT-R2).
    error NotSeeded();
    /// @notice Deposit would push `totalAssets` above {maxTvl} (VLT-R1, VLT-R10).
    error MaxTvlExceeded(uint256 resultingAssets, uint256 cap);
    /// @notice Redeemer does not hold that many shares.
    error InsufficientShares(uint256 requested, uint256 held);
    /// @notice Buffer plus parked USDC cannot cover the redemption (VLT-R5).
    error InsufficientLiquidUsdc(uint256 requested, uint256 available);
    /// @notice `tokens` and `amounts` disagree, or are empty.
    error InvalidShipArrays();
    /// @notice Strategy hash is already tracked as active.
    error StrategyAlreadyActive(bytes32 strategyHash);
    /// @notice Strategy hash is not tracked as active.
    error StrategyNotActive(bytes32 strategyHash);
    /// @notice Chainlink returned a non-positive answer.
    error InvalidPrice(int256 answer);
    /// @notice Constructor argument was the zero address.
    error ZeroAddress();

    /// @dev Single-owner gate. The window cut collapses MANAGER and KEEPER into this one role.
    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        _;
    }

    /// @param usdc Deposit and redemption asset.
    /// @param weth Second token registered by the strategies.
    /// @param aqua Aqua registry (gen 2 per `docs/VERIFIED.md`).
    /// @param router SwapVM router used as the Aqua app and trusted as the hook caller (gen 2).
    /// @param adapter Carry venue adapter implementing the frozen {ICarryAdapter}.
    /// @param priceFeed Chainlink ETH/USD feed.
    /// @param owner_ Manager address, immutable for the lifetime of the vault.
    /// @param maxTvl_ Initial deposit cap in USDC units.
    constructor(
        IERC20 usdc,
        IERC20 weth,
        IAqua aqua,
        address router,
        ICarryAdapter adapter,
        IPriceFeed priceFeed,
        address owner_,
        uint256 maxTvl_
    ) {
        if (
            address(usdc) == address(0) || address(weth) == address(0) || address(aqua) == address(0)
                || router == address(0) || address(adapter) == address(0) || address(priceFeed) == address(0)
                || owner_ == address(0)
        ) {
            revert ZeroAddress();
        }

        USDC = usdc;
        WETH = weth;
        AQUA = aqua;
        ROUTER = router;
        ADAPTER = adapter;
        PRICE_FEED = priceFeed;
        OWNER = owner_;
        maxTvl = maxTvl_;

        uint8 usdcDecimals = IERC20Metadata(address(usdc)).decimals();
        uint8 wethDecimals = IERC20Metadata(address(weth)).decimals();
        uint8 feedDecimals = priceFeed.decimals();

        shareDecimals = usdcDecimals + DECIMALS_OFFSET;
        _WETH_TO_USDC_DENOM = 10 ** (uint256(feedDecimals) + uint256(wethDecimals) - uint256(usdcDecimals));

        emit MaxTvlUpdated(maxTvl_);
    }

    // -------------------------------------------------------------------------------------------
    // Investor surface
    // -------------------------------------------------------------------------------------------

    /// @notice Deposits USDC and credits internal shares to the caller.
    /// @dev VLT-R1 (4626 math, rounding down, cap), VLT-R2 (manager seeds first). Shares are priced
    ///      against `totalAssets` measured BEFORE the incoming transfer, matching ERC-4626.
    /// @param assets USDC amount to deposit.
    /// @return shares Shares credited to the caller.
    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        if (!seeded) {
            if (msg.sender != OWNER) revert NotSeeded();
            seeded = true;
        }

        uint256 assetsBefore = totalAssets();
        uint256 resultingAssets = assetsBefore + assets;
        if (resultingAssets > maxTvl) revert MaxTvlExceeded(resultingAssets, maxTvl);

        shares = _convertToShares(assets, assetsBefore);
        if (shares == 0) revert ZeroShares();

        _sharesOf[msg.sender] += shares;
        totalShares += shares;

        USDC.safeTransferFrom(msg.sender, address(this), assets);

        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burns shares and pays the caller in USDC only.
    /// @dev VLT-R5. Pulls the shortfall out of the carry venue first; reverts with
    ///      {InsufficientLiquidUsdc} when buffer plus parked cannot cover the payout, which is the
    ///      honest "temporarily illiquid" state, never a partial or in-kind payout.
    /// @param shares Shares to burn.
    /// @return assets USDC paid out.
    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        uint256 held = _sharesOf[msg.sender];
        if (shares > held) revert InsufficientShares(shares, held);

        assets = _convertToAssets(shares, totalAssets());
        if (assets == 0) revert ZeroAssets();

        _sharesOf[msg.sender] = held - shares;
        totalShares -= shares;

        uint256 buffer = USDC.balanceOf(address(this));
        if (assets > buffer) {
            uint256 shortfall = assets - buffer;
            uint256 parked = ADAPTER.parkedBalance(address(USDC));
            if (shortfall > parked) revert InsufficientLiquidUsdc(assets, buffer + parked);
            ADAPTER.unpark(address(USDC), shortfall);
            emit Unparked(address(USDC), shortfall);
        }

        USDC.safeTransfer(msg.sender, assets);

        emit Redeemed(msg.sender, assets, shares);
    }

    // -------------------------------------------------------------------------------------------
    // Views (ERC-4626 shaped, no ERC-20 share token by design)
    // -------------------------------------------------------------------------------------------

    /// @notice Internal share balance of `investor` (VLT-R3).
    /// @param investor Address to query.
    /// @return Shares held.
    function sharesOf(address investor) external view returns (uint256) {
        return _sharesOf[investor];
    }

    /// @notice Net asset value in USDC: USDC buffer, plus the parked sleeve, plus WETH at Chainlink.
    /// @dev VLT-R4 without the in-vault staleness gate (deferred by the window cut; `pnpm
    ///      aqua:status` reads the feed off chain). A non-positive answer still reverts.
    /// @return Vault assets denominated in USDC units.
    function totalAssets() public view returns (uint256) {
        uint256 assets = USDC.balanceOf(address(this)) + ADAPTER.parkedBalance(address(USDC));
        uint256 wethBalance = WETH.balanceOf(address(this));
        if (wethBalance != 0) assets += _wethToUsdc(wethBalance);
        return assets;
    }

    /// @notice Shares a deposit of `assets` would mint at the current share price, rounded down.
    /// @param assets USDC amount.
    /// @return Shares.
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets, totalAssets());
    }

    /// @notice Assets `shares` are worth at the current share price, rounded down.
    /// @param shares Share amount.
    /// @return USDC amount.
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares, totalAssets());
    }

    /// @notice USDC that could be paid out right now: buffer plus the parked sleeve (VLT-R5).
    /// @return Liquid USDC.
    function liquidUsdc() external view returns (uint256) {
        return USDC.balanceOf(address(this)) + ADAPTER.parkedBalance(address(USDC));
    }

    /// @notice Strategy hashes currently active on Aqua.
    /// @return Active strategy hashes.
    function activeStrategies() external view returns (bytes32[] memory) {
        return _activeStrategies;
    }

    /// @notice Token list a strategy was shipped with, which Aqua requires again at dock time.
    /// @param strategyHash Hash returned by {execShip}.
    /// @return Tokens registered by the strategy.
    function strategyTokens(bytes32 strategyHash) external view returns (address[] memory) {
        return _strategies[strategyHash].tokens;
    }

    /// @notice Whether a strategy hash is tracked as active by this vault.
    /// @param strategyHash Hash returned by {execShip}.
    /// @return True when active.
    function isStrategyActive(bytes32 strategyHash) external view returns (bool) {
        return _strategies[strategyHash].indexPlusOne != 0;
    }

    // -------------------------------------------------------------------------------------------
    // Settlement hook (VLT-R9): the just-in-time path
    // -------------------------------------------------------------------------------------------

    /// @inheritdoc IMakerHooks
    /// @dev Fires inside the taker's fill, immediately before `AQUA.pull` moves `tokenOut` out of
    ///      this vault. It tops the buffer up to exactly `amountOut` by withdrawing the shortfall
    ///      from the carry venue, so capital earns until the block it is spent. Guards:
    ///      only {ROUTER} may call, and the order's maker must be this vault, otherwise any third
    ///      party could point a hook at us and force our sleeve out of the venue. If the venue
    ///      cannot serve the withdrawal the adapter's revert bubbles and the fill fails, which is
    ///      "temporarily illiquid", never bad debt (ADP-R2). `makerData` and `takerData` are
    ///      ignored; `takerData` is taker controlled and must never be trusted.
    function preTransferOut(
        address maker,
        address,
        address,
        address tokenOut,
        uint256,
        uint256 amountOut,
        bytes32 orderHash,
        bytes calldata,
        bytes calldata
    ) external {
        if (msg.sender != ROUTER) revert NotRouter(msg.sender);
        if (maker != address(this)) revert NotOurOrder(maker);

        uint256 buffer = IERC20(tokenOut).balanceOf(address(this));
        if (buffer >= amountOut) return;

        uint256 shortfall = amountOut - buffer;
        ADAPTER.unpark(tokenOut, shortfall);
        emit JitUnparked(tokenOut, shortfall, orderHash);
    }

    // -------------------------------------------------------------------------------------------
    // Owner surface: strategy lifecycle
    // -------------------------------------------------------------------------------------------

    /// @notice Ships a compiler-built order to Aqua and records it for docking.
    /// @dev VLT-R7 (reduced to a single owner). The Aqua app is forced to the immutable {ROUTER}, so
    ///      the owner cannot point vault liquidity at an arbitrary app. Aqua's `pull` transfers from
    ///      this vault, so the registry allowance is topped up here. `strategyHash` is
    ///      `keccak256(order)` and is dead forever once docked, which is why every roll must change
    ///      the program salt (PRG-R10).
    /// @param order ABI-encoded SwapVM order bytes produced by the program compiler (PRG-R9).
    /// @param tokens Every token the strategy registers, including a side shipped at amount 0.
    /// @param amounts Virtual balance per token, index-aligned with `tokens`.
    /// @return strategyHash Hash Aqua assigned to the strategy.
    function execShip(bytes calldata order, address[] calldata tokens, uint256[] calldata amounts)
        external
        onlyOwner
        returns (bytes32 strategyHash)
    {
        uint256 count = tokens.length;
        if (count == 0 || count != amounts.length) revert InvalidShipArrays();

        for (uint256 i; i < count; ++i) {
            if (amounts[i] != 0) _ensureAquaAllowance(tokens[i], amounts[i]);
        }

        strategyHash = AQUA.ship(ROUTER, order, tokens, amounts);

        StrategyRecord storage record = _strategies[strategyHash];
        if (record.indexPlusOne != 0) revert StrategyAlreadyActive(strategyHash);
        record.tokens = tokens;
        _activeStrategies.push(strategyHash);
        record.indexPlusOne = _activeStrategies.length;

        emit StrategyShipped(strategyHash, tokens, amounts);
    }

    /// @notice Docks one strategy, zeroing its Aqua balances.
    /// @dev Accounting only: no tokens move. VLT-R7 reduced to a single owner.
    /// @param strategyHash Hash returned by {execShip}.
    function execDock(bytes32 strategyHash) external onlyOwner {
        _dock(strategyHash);
    }

    /// @notice Docks every active strategy. Emergency stop (VLT-R11).
    /// @dev Accounting only, so it can never fail for lack of liquidity. Pair it with
    ///      {revokeAquaApproval} to make the vault fully inert.
    function dockAll() external onlyOwner {
        uint256 remaining = _activeStrategies.length;
        while (remaining != 0) {
            _dock(_activeStrategies[remaining - 1]);
            --remaining;
        }
    }

    // -------------------------------------------------------------------------------------------
    // Owner surface: sleeve and caps
    // -------------------------------------------------------------------------------------------

    /// @notice Moves USDC from the buffer into the carry venue.
    /// @dev Manual in the window: the re-park keeper is cut, so the manager keeps the buffer at
    ///      target from the CLI. The adapter pulls the exact approved amount.
    /// @param amount USDC to park.
    function parkUsdc(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        USDC.forceApprove(address(ADAPTER), amount);
        ADAPTER.park(address(USDC), amount);
        emit Parked(address(USDC), amount);
    }

    /// @notice Pulls USDC out of the carry venue back into the buffer.
    /// @param amount USDC to withdraw from the venue.
    function unparkUsdc(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        ADAPTER.unpark(address(USDC), amount);
        emit Unparked(address(USDC), amount);
    }

    /// @notice Updates the deposit cap (VLT-R10).
    /// @param newMaxTvl New cap in USDC units.
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        maxTvl = newMaxTvl;
        emit MaxTvlUpdated(newMaxTvl);
    }

    /// @notice Sets this vault's ERC-20 allowance for the Aqua registry.
    /// @dev Second half of the emergency stop: `dockAll()` then `revokeAquaApproval(USDC)` leaves
    ///      Aqua unable to move anything even if a stale strategy were somehow still active.
    /// @param token Token whose allowance to change.
    /// @param amount New allowance. Zero revokes.
    function revokeAquaApproval(IERC20 token, uint256 amount) external onlyOwner {
        token.forceApprove(address(AQUA), amount);
        emit AquaApprovalSet(address(token), amount);
    }

    // -------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------

    /// @dev OpenZeppelin ERC4626 `_convertToShares` with virtual shares and virtual assets, floored.
    function _convertToShares(uint256 assets, uint256 assetsBefore) private view returns (uint256) {
        return Math.mulDiv(assets, totalShares + _VIRTUAL_SHARES, assetsBefore + 1, Math.Rounding.Floor);
    }

    /// @dev OpenZeppelin ERC4626 `_convertToAssets` with virtual shares and virtual assets, floored.
    function _convertToAssets(uint256 shares, uint256 assetsNow) private view returns (uint256) {
        return Math.mulDiv(shares, assetsNow + 1, totalShares + _VIRTUAL_SHARES, Math.Rounding.Floor);
    }

    /// @dev Values WETH in USDC units at the Chainlink answer.
    function _wethToUsdc(uint256 wethAmount) private view returns (uint256) {
        (, int256 answer,,,) = PRICE_FEED.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        return Math.mulDiv(wethAmount, uint256(answer), _WETH_TO_USDC_DENOM);
    }

    /// @dev Tops the Aqua allowance up to unlimited when it cannot cover a new ship.
    function _ensureAquaAllowance(address token, uint256 amount) private {
        if (IERC20(token).allowance(address(this), address(AQUA)) >= amount) return;
        IERC20(token).forceApprove(address(AQUA), type(uint256).max);
        emit AquaApprovalSet(token, type(uint256).max);
    }

    /// @dev Docks one strategy and drops it from the active set.
    function _dock(bytes32 strategyHash) private {
        StrategyRecord storage record = _strategies[strategyHash];
        uint256 indexPlusOne = record.indexPlusOne;
        if (indexPlusOne == 0) revert StrategyNotActive(strategyHash);

        address[] memory tokens = record.tokens;

        uint256 lastIndex = _activeStrategies.length - 1;
        if (indexPlusOne - 1 != lastIndex) {
            bytes32 moved = _activeStrategies[lastIndex];
            _activeStrategies[indexPlusOne - 1] = moved;
            _strategies[moved].indexPlusOne = indexPlusOne;
        }
        _activeStrategies.pop();
        record.indexPlusOne = 0;

        AQUA.dock(ROUTER, strategyHash, tokens);

        emit StrategyDocked(strategyHash);
    }
}
