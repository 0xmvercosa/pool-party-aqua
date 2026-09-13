// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IAqua } from "../interfaces/IAqua.sol";
import { CashPlusTypes as T, ICashPlusRouter } from "./CashPlusTypes.sol";
import { CashPlusAaveAdapter } from "./CashPlusAaveAdapter.sol";
import { CashPlusOracle } from "./CashPlusOracle.sol";
import { CashPlusLens } from "./CashPlusLens.sol";
import { CashPlusPricing } from "./CashPlusPricing.sol";
import { CashPlusProgramFactory } from "./CashPlusProgramFactory.sol";

/// @notice Two-stablecoin pooled custody, nontransferable shares and bounded Aqua maker execution.
/// @dev Locked seed uses simple proportional math. Aqua virtual balances never enter NAV.
contract CashPlusVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant SEED_HOLDER = address(1);
    uint256 public constant MIN_SEED = 1000e6;
    uint256 public constant MAX_ACTIVE_ORDERS = 8;
    uint256 public constant MAX_ORDER_LIFETIME = 300;
    uint8 public constant shareDecimals = 18;
    IERC20 public immutable USDC;
    IERC20 public immutable SECONDARY_STABLE;
    IAqua public immutable AQUA;
    address public immutable ROUTER;
    address public immutable GOVERNANCE;
    address public immutable KEEPER;
    address public immutable GUARDIAN;
    address public immutable INITIALIZER;
    uint256 public immutable HARD_DEPOSIT_CAP;
    CashPlusAaveAdapter public immutable USDC_ADAPTER;
    CashPlusAaveAdapter public immutable SECONDARY_ADAPTER;
    CashPlusOracle public immutable ORACLE;
    CashPlusLens public immutable LENS;
    CashPlusPricing public immutable PRICING;
    CashPlusProgramFactory public immutable PROGRAM_FACTORY;

    T.Policy public policy;
    uint64 public policyVersion = 1;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) private depositedUsdc;
    mapping(address => uint256) private withdrawnUsdcEquivalent;
    mapping(address => bool) private hasUnvaluedExit;
    mapping(address => bool) public allowedTaker;
    bool public initialized;
    bool public depositsPaused;
    bool public tradingPaused;
    bool public emergencyMode;
    bool public rebalanceRequired;
    uint64 public budgetDay;
    uint256 public dailyBaselineUsdc;
    uint256 public dailyVolumeUsdc;

    enum SettlementState {
        IDLE,
        EXPECTING_INPUT,
        INPUT_RECEIVED,
        EXPECTING_OUTPUT
    }

    SettlementState public settlementState;

    struct Strategy {
        uint64 version;
        uint64 deadline;
        uint16 indexPlusOne;
    }

    mapping(bytes32 => Strategy) public strategies;
    bytes32[] private _activeOrders;

    struct Settlement {
        bytes32 context;
        uint256 inputBefore;
        uint256 outputBefore;
        uint256 holdings0;
        uint256 holdings1;
        uint256 price0;
        uint256 price1;
        uint256 inputValue;
        uint256 outputValue;
    }

    Settlement private _settlement;

    error Unauthorized();
    error SettlementBusy();
    error InvalidConfiguration();
    error InvalidPolicy();
    error NotInitialized();
    error PrefundedAddress();
    error Paused();
    error DeadlineExpired();
    error PolicyChanged();
    error InvalidAmount();
    error Slippage();
    error CapacityExceeded();
    error InsufficientShares();
    error InsufficientCash();
    error UnsupportedPair();
    error TransferMismatch();
    error InactiveOrder();
    error TooManyOrders();
    error FillLimit();
    error DailyBudget();
    error InventoryLimit();
    error HookSequence();
    error InvalidHookData();

    event Seeded(address indexed sponsor, uint256 assets, uint256 shares);
    event Deposited(address indexed owner, uint256 assets, uint256 shares, uint64 policyVersion);
    event Redeemed(address indexed owner, uint256 shares, uint256 usdcOut);
    event ProportionalExit(
        address indexed owner,
        uint256 shares,
        address[] tokens,
        uint256[] amounts,
        uint256 valueUsdc,
        bool valuationAvailable
    );
    event Parked(address indexed token, uint256 amount);
    event Unparked(address indexed token, uint256 amount);
    event JitUnparked(bytes32 indexed orderHash, address indexed token, uint256 amount);
    event ConversionSettled(
        bytes32 indexed orderHash,
        address indexed taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 inputValueUsdc,
        uint256 outputValueUsdc,
        uint64 policyVersion
    );
    event StrategyShipped(bytes32 indexed orderHash, uint64 policyVersion, uint64 deadline);
    event StrategyDocked(bytes32 indexed orderHash);
    event PolicyUpdated(uint64 version, bytes32 policyHash);
    event PauseUpdated(bool deposits, bool trading, bool emergency);
    event CapacityUpdated(uint256 oldCap, uint256 newCap, bytes32 reasonHash);
    event TakerUpdated(address indexed taker, bool allowed);
    event StateCheckpoint(
        uint256 totalAssetsUsdc,
        uint256 totalShares,
        uint256 usdcLendingIndex,
        uint256 secondaryLendingIndex,
        bool valuationAvailable
    );

    modifier idle() {
        if (settlementState != SettlementState.IDLE) revert SettlementBusy();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != KEEPER && msg.sender != GOVERNANCE) revert Unauthorized();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert Unauthorized();
        _;
    }

    constructor(T.Config memory c, T.Policy memory initialPolicy) {
        if (
            c.usdc == c.secondary || c.usdc.code.length == 0 || c.secondary.code.length == 0 || c.aqua.code.length == 0
                || c.router.code.length == 0 || c.governance == address(0) || c.keeper == address(0)
                || c.guardian == address(0) || c.hardDepositCap < MIN_SEED || ICashPlusRouter(c.router).AQUA() != c.aqua
        ) revert InvalidConfiguration();
        USDC = IERC20(c.usdc);
        SECONDARY_STABLE = IERC20(c.secondary);
        AQUA = IAqua(c.aqua);
        ROUTER = c.router;
        GOVERNANCE = c.governance;
        KEEPER = c.keeper;
        GUARDIAN = c.guardian;
        INITIALIZER = msg.sender;
        HARD_DEPOSIT_CAP = c.hardDepositCap;
        ORACLE = new CashPlusOracle(c);
        USDC_ADAPTER = new CashPlusAaveAdapter(address(this), c.usdc, c.pool, c.usdcAToken);
        SECONDARY_ADAPTER = c.secondaryAToken == address(0)
            ? CashPlusAaveAdapter(address(0))
            : new CashPlusAaveAdapter(address(this), c.secondary, c.pool, c.secondaryAToken);
        PRICING = new CashPlusPricing(address(this), c.router);
        PROGRAM_FACTORY = new CashPlusProgramFactory(address(this), address(PRICING));
        LENS = new CashPlusLens(address(this));
        _validatePolicy(initialPolicy);
        policy = initialPolicy;
        if (
            _holdings(0) != 0 || _holdings(1) != 0 || SECONDARY_STABLE.balanceOf(address(USDC_ADAPTER)) != 0
                || (address(SECONDARY_ADAPTER) != address(0) && USDC.balanceOf(address(SECONDARY_ADAPTER)) != 0)
        ) revert PrefundedAddress();
    }

    /// @notice Initializer is the deploying factory, which calls this within its atomic deployment transaction.
    function initialize(address sponsor, uint256 seed) external idle nonReentrant {
        if (msg.sender != INITIALIZER || initialized) revert Unauthorized();
        if (seed < MIN_SEED || seed > policy.depositCap) revert InvalidAmount();
        if (_holdings(0) != seed || _holdings(1) != 0 || USDC.balanceOf(address(this)) != seed) {
            revert PrefundedAddress();
        }
        ORACLE.prices();
        initialized = true;
        totalShares = seed * 1e12;
        sharesOf[SEED_HOLDER] = totalShares;
        emit Seeded(sponsor, seed, totalShares);
        emit PolicyUpdated(policyVersion, keccak256(abi.encode(policy)));
        _checkpoint();
    }

    function deposit(uint256 assets, uint256 minShares, uint64 deadline, uint64 version)
        external
        idle
        nonReentrant
        returns (uint256 shares)
    {
        _intent(deadline, version);
        if (depositsPaused || emergencyMode) revert Paused();
        if (assets < policy.minDeposit) revert InvalidAmount();
        uint256 beforeAssets = totalAssets();
        if (beforeAssets + assets > policy.depositCap) revert CapacityExceeded();
        shares = Math.mulDiv(assets, totalShares, beforeAssets);
        if (shares == 0 || shares < minShares) revert Slippage();
        uint256 beforeBalance = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), assets);
        if (USDC.balanceOf(address(this)) != beforeBalance + assets) revert TransferMismatch();
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        depositedUsdc[msg.sender] += assets;
        emit Deposited(msg.sender, assets, shares, policyVersion);
        _checkpoint();
    }

    function redeem(uint256 shares, uint256 minUsdcOut, uint64 deadline, uint64 version)
        external
        idle
        nonReentrant
        returns (uint256 assets)
    {
        _intent(deadline, version);
        return _redeem(shares, minUsdcOut);
    }

    function redeemAll(uint256 minUsdcOut, uint64 deadline, uint64 version)
        external
        idle
        nonReentrant
        returns (uint256 assets)
    {
        _intent(deadline, version);
        return _redeem(sharesOf[msg.sender], minUsdcOut);
    }

    function _redeem(uint256 shares, uint256 minimum) private returns (uint256 assets) {
        _ownedShares(shares);
        assets = Math.mulDiv(shares, totalAssets(), totalShares);
        if (assets == 0 || assets < minimum) revert Slippage();
        if (_holdings(0) < assets) revert InsufficientCash();
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        withdrawnUsdcEquivalent[msg.sender] += assets;
        _cash(0, assets);
        _send(USDC, msg.sender, assets);
        emit Redeemed(msg.sender, shares, assets);
        _checkpoint();
    }

    function redeemProportional(uint256 shares, uint256[] calldata minAmounts, uint64 deadline)
        external
        idle
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (!initialized) revert NotInitialized();
        if (block.timestamp > deadline) revert DeadlineExpired();
        _ownedShares(shares);
        if (minAmounts.length != 4) revert InvalidAmount();
        amounts = previewProportional(shares);
        bool positive;
        for (uint256 i; i < 4; ++i) {
            if (amounts[i] < minAmounts[i]) revert Slippage();
            if (amounts[i] != 0) positive = true;
        }
        if (!positive) revert InvalidAmount();
        uint256 value;
        bool valued;
        if (!emergencyMode) {
            (uint256 p0, uint256 p1) = ORACLE.prices();
            value = amounts[0] + amounts[2] + ORACLE.valueSecondary(amounts[1] + amounts[3], p0, p1);
            valued = true;
            withdrawnUsdcEquivalent[msg.sender] += value;
        } else {
            hasUnvaluedExit[msg.sender] = true;
        }
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        // Underlying components include idle donations in adapters; no Aave withdrawal is needed.
        _idleCash(0, amounts[0]);
        _idleCash(1, amounts[1]);
        _send(USDC, msg.sender, amounts[0]);
        _send(SECONDARY_STABLE, msg.sender, amounts[1]);
        if (amounts[2] != 0) USDC_ADAPTER.transferReceipt(msg.sender, amounts[2], minAmounts[2]);
        if (amounts[3] != 0) SECONDARY_ADAPTER.transferReceipt(msg.sender, amounts[3], minAmounts[3]);
        emit ProportionalExit(msg.sender, shares, componentTokens(), amounts, value, valued);
        _checkpoint();
    }

    function totalAssets() public view returns (uint256) {
        (uint256 p0, uint256 p1) = ORACLE.prices();
        return _nav(_holdings(0), _holdings(1), p0, p1);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        if (!initialized) revert NotInitialized();
        return Math.mulDiv(assets, totalShares, totalAssets());
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        if (!initialized) revert NotInitialized();
        return Math.mulDiv(shares, totalAssets(), totalShares);
    }

    function previewProportional(uint256 shares) public view returns (uint256[] memory amounts) {
        if (!initialized || shares > totalShares) revert InvalidAmount();
        amounts = new uint256[](4);
        amounts[0] = Math.mulDiv(_idleHoldings(0), shares, totalShares);
        amounts[1] = Math.mulDiv(_idleHoldings(1), shares, totalShares);
        amounts[2] = Math.mulDiv(USDC_ADAPTER.parkedBalance(), shares, totalShares);
        if (address(SECONDARY_ADAPTER) != address(0)) {
            amounts[3] = Math.mulDiv(SECONDARY_ADAPTER.parkedBalance(), shares, totalShares);
        }
    }

    function componentTokens() public view returns (address[] memory tokens) {
        tokens = new address[](4);
        tokens[0] = address(USDC);
        tokens[1] = address(SECONDARY_STABLE);
        tokens[2] = address(USDC_ADAPTER.A_TOKEN());
        tokens[3] = address(SECONDARY_ADAPTER) == address(0) ? address(0) : address(SECONDARY_ADAPTER.A_TOKEN());
    }

    function accountCashflows(address owner)
        external
        view
        returns (uint256 deposited, uint256 withdrawnValue, bool incomplete)
    {
        return (depositedUsdc[owner], withdrawnUsdcEquivalent[owner], hasUnvaluedExit[owner]);
    }

    function status() external view returns (T.Status memory) {
        _readLens();
    }

    function inventory() external view returns (T.InventoryItem[] memory) {
        _readLens();
    }

    function _readLens() private view {
        address target = address(LENS);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := staticcall(gas(), target, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(ok) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }

    /// @notice Canonical order lifecycle. Virtual allocations are bounded by actual holdings but are not NAV.
    function shipCanonical(T.ProgramParameters calldata params)
        external
        onlyKeeper
        idle
        nonReentrant
        returns (bytes32 hash)
    {
        _intent(params.deadline, params.policyVersion);
        if (tradingPaused || emergencyMode) revert Paused();
        if (params.deadline > block.timestamp + MAX_ORDER_LIFETIME) revert InvalidAmount();
        if (_activeOrders.length >= MAX_ACTIVE_ORDERS) revert TooManyOrders();
        if (
            params.usdcVirtualBalance > _holdings(0) || params.secondaryVirtualBalance > _holdings(1)
                || params.usdcVirtualBalance > type(uint248).max || params.secondaryVirtualBalance > type(uint248).max
                || params.usdcVirtualBalance + params.secondaryVirtualBalance == 0
        ) revert InvalidAmount();
        ORACLE.prices();
        bytes memory encoded = PROGRAM_FACTORY.encode(params);
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(SECONDARY_STABLE);
        uint256[] memory balances = new uint256[](2);
        balances[0] = params.usdcVirtualBalance;
        balances[1] = params.secondaryVirtualBalance;
        hash = AQUA.ship(ROUTER, encoded, tokens, balances);
        if (hash != keccak256(encoded) || strategies[hash].indexPlusOne != 0) revert InvalidConfiguration();
        _activeOrders.push(hash);
        strategies[hash] = Strategy(policyVersion, params.deadline, uint16(_activeOrders.length));
        emit StrategyShipped(hash, policyVersion, params.deadline);
        _checkpoint();
    }

    function activeStrategies() external view returns (bytes32[] memory) {
        return _activeOrders;
    }

    function dock(bytes32 hash) external onlyKeeper idle nonReentrant {
        Strategy memory s = strategies[hash];
        if (s.indexPlusOne == 0) revert InactiveOrder();
        uint256 last = _activeOrders.length - 1;
        if (s.indexPlusOne - 1 != last) {
            bytes32 moved = _activeOrders[last];
            _activeOrders[s.indexPlusOne - 1] = moved;
            strategies[moved].indexPlusOne = s.indexPlusOne;
        }
        _activeOrders.pop();
        delete strategies[hash];
        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(SECONDARY_STABLE);
        AQUA.dock(ROUTER, hash, tokens);
        emit StrategyDocked(hash);
    }

    function park(address token, uint256 amount) external onlyKeeper idle nonReentrant {
        uint256 i = _index(token);
        if (!initialized || amount == 0 || emergencyMode) revert InvalidAmount();
        CashPlusAaveAdapter adapter = _adapter(i);
        if (address(adapter) == address(0)) revert InvalidConfiguration();
        (uint256 p0, uint256 p1) = ORACLE.prices();
        uint256 target = _buffer(i, _nav(_holdings(0), _holdings(1), p0, p1), p0, p1);
        if (_token(i).balanceOf(address(this)) < amount + target) revert InsufficientCash();
        _token(i).forceApprove(address(adapter), amount);
        adapter.park(amount);
        _token(i).forceApprove(address(adapter), 0);
        emit Parked(token, amount);
        _checkpoint();
    }

    function unpark(address token, uint256 amount) external onlyKeeper idle nonReentrant {
        if (!initialized || amount == 0) revert InvalidAmount();
        CashPlusAaveAdapter adapter = _adapter(_index(token));
        if (address(adapter) == address(0)) revert InvalidConfiguration();
        adapter.unpark(amount);
        emit Unparked(token, amount);
        _checkpoint();
    }

    function lowerDepositCap(uint256 cap) external onlyKeeper idle nonReentrant {
        _lowerCap(cap, bytes32(0));
    }

    function lowerDepositCapWithReason(uint256 cap, bytes32 reason) external onlyKeeper idle nonReentrant {
        _lowerCap(cap, reason);
    }

    function _lowerCap(uint256 cap, bytes32 reason) private {
        if (cap > policy.depositCap) revert InvalidPolicy();
        uint256 old = policy.depositCap;
        policy.depositCap = cap;
        emit CapacityUpdated(old, cap, reason);
    }

    function setPolicy(T.Policy calldata next) external onlyGovernance idle nonReentrant {
        _validatePolicy(next);
        ORACLE.prices();
        policy = next;
        ++policyVersion;
        emit PolicyUpdated(policyVersion, keccak256(abi.encode(next)));
        _checkpoint();
    }

    function setAllowedTaker(address taker, bool allowed) external onlyGovernance idle nonReentrant {
        if (taker == address(0)) revert InvalidConfiguration();
        allowedTaker[taker] = allowed;
        emit TakerUpdated(taker, allowed);
    }

    function setPause(bool deposits, bool trading) external idle nonReentrant {
        if (msg.sender != GOVERNANCE && msg.sender != KEEPER && msg.sender != GUARDIAN) revert Unauthorized();
        if (msg.sender != GOVERNANCE && ((!deposits && depositsPaused) || (!trading && tradingPaused))) {
            revert Unauthorized();
        }
        if (emergencyMode && (!deposits || !trading)) revert Paused();
        if (!deposits || !trading) ORACLE.prices();
        depositsPaused = deposits;
        tradingPaused = trading;
        if (trading) _revokeAqua();
        emit PauseUpdated(deposits, trading, emergencyMode);
    }

    function setEmergencyMode(bool enabled) external idle nonReentrant {
        if (msg.sender != GOVERNANCE && (msg.sender != GUARDIAN || !enabled)) revert Unauthorized();
        if (!enabled) ORACLE.prices();
        emergencyMode = enabled;
        if (enabled) {
            depositsPaused = true;
            tradingPaused = true;
            _revokeAqua();
        }
        emit PauseUpdated(depositsPaused, tradingPaused, enabled);
    }

    /// @notice Exact-input pricing plus global budgets, independent of per-order virtual accounting.
    function quoteTrade(
        bytes32 hash,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint64 version
    ) external view returns (uint256 amountOut) {
        if (settlementState != SettlementState.IDLE) revert SettlementBusy();
        _tradeAllowed(hash, taker, version);
        (uint256 p0, uint256 p1) = ORACLE.prices();
        amountOut = _price(tokenIn, tokenOut, amountIn, p0, p1);
        _risk(tokenIn, amountIn, amountOut, _holdings(0), _holdings(1), p0, p1);
    }

    function preTransferIn(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 hash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external idle nonReentrant {
        _hookAuth(maker, makerData, takerData);
        _tradeAllowed(hash, taker, strategies[hash].version);
        (uint256 p0, uint256 p1) = ORACLE.prices();
        if (amountOut != _price(tokenIn, tokenOut, amountIn, p0, p1)) revert Slippage();
        uint256 h0 = _holdings(0);
        uint256 h1 = _holdings(1);
        _rollDay(_nav(h0, h1, p0, p1));
        (uint256 inputValue, uint256 outputValue) = _risk(tokenIn, amountIn, amountOut, h0, h1, p0, p1);
        _settlement =
            Settlement(_context(), IERC20(tokenIn).balanceOf(address(this)), 0, h0, h1, p0, p1, inputValue, outputValue);
        settlementState = SettlementState.EXPECTING_INPUT;
    }

    function postTransferIn(
        address maker,
        address,
        address tokenIn,
        address,
        uint256 amountIn,
        uint256,
        bytes32,
        bytes calldata makerData,
        bytes calldata takerData
    ) external nonReentrant {
        _hookAuth(maker, makerData, takerData);
        _match(SettlementState.EXPECTING_INPUT, _context());
        if (IERC20(tokenIn).balanceOf(address(this)) != _settlement.inputBefore + amountIn) revert TransferMismatch();
        settlementState = SettlementState.INPUT_RECEIVED;
    }

    function preTransferOut(
        address maker,
        address,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 hash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external nonReentrant {
        _hookAuth(maker, makerData, takerData);
        _match(SettlementState.INPUT_RECEIVED, _context());
        Settlement memory s = _settlement;
        _risk(tokenIn, amountIn, amountOut, s.holdings0, s.holdings1, s.price0, s.price1);
        uint256 i = _index(tokenOut);
        uint256 navAfter = _nav(s.holdings0, s.holdings1, s.price0, s.price1) + s.inputValue - s.outputValue;
        uint256 required = amountOut + _buffer(i, navAfter, s.price0, s.price1);
        uint256 beforeLending = _adapterBalance(i);
        _cash(i, required);
        uint256 unparked = beforeLending - _adapterBalance(i);
        if (unparked != 0) emit JitUnparked(hash, tokenOut, unparked);
        _settlement.outputBefore = IERC20(tokenOut).balanceOf(address(this));
        // Authority exists only for this exact verified output, and is consumed by Aqua.pull.
        IERC20(tokenOut).forceApprove(address(AQUA), amountOut);
        settlementState = SettlementState.EXPECTING_OUTPUT;
    }

    function postTransferOut(
        address maker,
        address taker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 hash,
        bytes calldata makerData,
        bytes calldata takerData
    ) external nonReentrant {
        _hookAuth(maker, makerData, takerData);
        _match(SettlementState.EXPECTING_OUTPUT, _context());
        Settlement memory s = _settlement;
        if (
            IERC20(tokenOut).balanceOf(address(this)) + amountOut != s.outputBefore
                || IERC20(tokenIn).balanceOf(address(this)) != s.inputBefore + amountIn
        ) revert TransferMismatch();
        uint256 expected0 = tokenIn == address(USDC) ? s.holdings0 + amountIn : s.holdings0 - amountOut;
        uint256 expected1 = tokenIn == address(USDC) ? s.holdings1 - amountOut : s.holdings1 + amountIn;
        // Aave may round one raw receipt unit during an exact withdrawal; tolerate only that unit.
        if (!_near(_holdings(0), expected0) || !_near(_holdings(1), expected1)) revert TransferMismatch();
        IERC20(tokenOut).forceApprove(address(AQUA), 0);
        dailyVolumeUsdc += s.inputValue;
        delete _settlement;
        settlementState = SettlementState.IDLE;
        emit ConversionSettled(
            hash, taker, tokenIn, tokenOut, amountIn, amountOut, s.inputValue, s.outputValue, policyVersion
        );
        _checkpoint();
    }

    function _price(address input, address output, uint256 amount, uint256 p0, uint256 p1)
        private
        view
        returns (uint256)
    {
        uint256 i = _index(input);
        if (output != address(_token(1 - i)) || amount == 0) revert UnsupportedPair();
        uint256[4] memory x = [_holdings(0), _holdings(1), p0, p1];
        return ORACLE.priceTrade(policy, i == 0, amount, x);
    }

    function _risk(address input, uint256 amountIn, uint256 amountOut, uint256 h0, uint256 h1, uint256 p0, uint256 p1)
        private
        view
        returns (uint256 inputValue, uint256 outputValue)
    {
        bool currentDay = budgetDay == block.timestamp / 1 days;
        uint256[8] memory x = [
            amountIn,
            amountOut,
            h0,
            h1,
            p0,
            p1,
            currentDay ? dailyBaselineUsdc : _nav(h0, h1, p0, p1),
            currentDay ? dailyVolumeUsdc : 0
        ];
        return ORACLE.validateTrade(policy, _index(input) == 0, x);
    }

    function _tradeAllowed(bytes32 hash, address taker, uint64 version) private view {
        if (!initialized) revert NotInitialized();
        if (tradingPaused || emergencyMode) revert Paused();
        if (!allowedTaker[taker]) revert Unauthorized();
        Strategy memory s = strategies[hash];
        if (s.indexPlusOne == 0 || s.deadline < block.timestamp) revert InactiveOrder();
        if (version != policyVersion || s.version != version) revert PolicyChanged();
    }

    function _hookAuth(address maker, bytes calldata makerData, bytes calldata takerData) private view {
        if (msg.sender != ROUTER || maker != address(this)) revert Unauthorized();
        if (makerData.length != 0 || takerData.length != 0) revert InvalidHookData();
    }

    function _match(SettlementState expected, bytes32 context) private view {
        if (settlementState != expected || context != _settlement.context) revert HookSequence();
    }

    function _context() private pure returns (bytes32 result) {
        // Four hook selectors differ; their first seven static ABI arguments are identical.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 4, 224)
            result := keccak256(ptr, 224)
        }
    }

    function _intent(uint64 deadline, uint64 version) private view {
        if (!initialized) revert NotInitialized();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (version != policyVersion) revert PolicyChanged();
    }

    function _ownedShares(uint256 shares) private view {
        if (shares == 0 || msg.sender == SEED_HOLDER || shares > sharesOf[msg.sender]) revert InsufficientShares();
    }

    function _validatePolicy(T.Policy memory p) private view {
        if (
            p.depositCap > HARD_DEPOSIT_CAP || p.minDeposit < 1e6 || p.maxFillBps == 0 || p.maxFillBps > 100
                || p.dailyBudgetBps == 0 || p.dailyBudgetBps > 2000 || p.secondaryCapBps > 2000 || p.secondaryTargetBps == 0
                || p.secondaryTargetBps > p.secondaryCapBps || p.baseSpreadBps == 0
                || p.baseSpreadBps + p.maxSurchargeBps > 15 || p.hotUsdcBps > 1000 || p.hotSecondaryBps > p.secondaryCapBps
        ) revert InvalidPolicy();
    }

    function _checkpoint() private {
        (uint256 assets, uint256 index0, uint256 index1, bool valued, bool rebalance) = LENS.checkpointData();
        if (valued) {
            _rollDay(assets);
            rebalanceRequired = rebalance;
        }
        emit StateCheckpoint(assets, totalShares, index0, index1, valued);
    }

    function _rollDay(uint256 nav) private {
        uint64 today = uint64(block.timestamp / 1 days);
        if (budgetDay != today || dailyBaselineUsdc == 0) {
            budgetDay = today;
            dailyBaselineUsdc = nav;
            dailyVolumeUsdc = 0;
        }
    }

    function _nav(uint256 h0, uint256 h1, uint256 p0, uint256 p1) private view returns (uint256) {
        return h0 + ORACLE.valueSecondary(h1, p0, p1);
    }

    function _buffer(uint256 i, uint256 nav, uint256 p0, uint256 p1) private view returns (uint256) {
        uint256 value = Math.mulDiv(nav, i == 0 ? policy.hotUsdcBps : policy.hotSecondaryBps, 10_000);
        return i == 0 ? value : Math.mulDiv(value, p0 * ORACLE.SECONDARY_SCALE(), p1 * 1e6, Math.Rounding.Ceil);
    }

    function _token(uint256 i) private view returns (IERC20) {
        return i == 0 ? USDC : SECONDARY_STABLE;
    }

    function _adapter(uint256 i) private view returns (CashPlusAaveAdapter) {
        return i == 0 ? USDC_ADAPTER : SECONDARY_ADAPTER;
    }

    function _index(address token) private view returns (uint256) {
        if (token == address(USDC)) return 0;
        if (token == address(SECONDARY_STABLE)) return 1;
        revert UnsupportedPair();
    }

    function _adapterBalance(uint256 i) private view returns (uint256) {
        CashPlusAaveAdapter a = _adapter(i);
        return address(a) == address(0) ? 0 : a.parkedBalance();
    }

    function _idleHoldings(uint256 i) private view returns (uint256) {
        CashPlusAaveAdapter a = _adapter(i);
        return _token(i).balanceOf(address(this)) + (address(a) == address(0) ? 0 : a.idleBalance());
    }

    function _holdings(uint256 i) private view returns (uint256) {
        return _idleHoldings(i) + _adapterBalance(i);
    }

    function _idleCash(uint256 i, uint256 required) private {
        uint256 wallet = _token(i).balanceOf(address(this));
        if (wallet < required) _adapter(i).returnIdle(required - wallet);
    }

    function _cash(uint256 i, uint256 required) private {
        uint256 wallet = _token(i).balanceOf(address(this));
        if (wallet >= required) return;
        CashPlusAaveAdapter adapter = _adapter(i);
        if (address(adapter) == address(0)) revert InsufficientCash();
        uint256 idleAmount = Math.min(adapter.idleBalance(), required - wallet);
        if (idleAmount != 0) {
            adapter.returnIdle(idleAmount);
            wallet += idleAmount;
        }
        if (wallet < required) adapter.unpark(required - wallet);
        if (_token(i).balanceOf(address(this)) < required) revert InsufficientCash();
    }

    function _send(IERC20 token, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeVault = token.balanceOf(address(this));
        uint256 beforeTo = token.balanceOf(to);
        token.safeTransfer(to, amount);
        if (token.balanceOf(address(this)) + amount != beforeVault || token.balanceOf(to) != beforeTo + amount) {
            revert TransferMismatch();
        }
    }

    function _near(uint256 a, uint256 b) private pure returns (bool) {
        return a > b ? a - b <= 1 : b - a <= 1;
    }

    function _revokeAqua() private {
        USDC.forceApprove(address(AQUA), 0);
        SECONDARY_STABLE.forceApprove(address(AQUA), 0);
    }
}
