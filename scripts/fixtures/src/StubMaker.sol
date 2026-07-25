// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * Stand-in for the carry adapter (POO-1060 builds the real Aave v3 one). Holds the parked
 * sleeve and releases it only to its owning vault, which is exactly ADP-R1.
 *
 * NOT FOR DEPLOYMENT. Fork fixture only.
 */
contract StubAdapter {
    address public immutable VAULT;
    address public immutable TOKEN;

    error OnlyVault();

    constructor(address vault, address token) {
        VAULT = vault;
        TOKEN = token;
    }

    function parkedBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// ADP-R2: withdraw exactly `amount`. The real adapter withdraws from Aave here.
    function unpark(address token, uint256 amount) external {
        if (msg.sender != VAULT) revert OnlyVault();
        IERC20(token).transfer(VAULT, amount);
    }
}

/**
 * Minimal stand-in for PartyVault, used only by the POO-1058 fork rehearsal to prove that
 * the maker's `preTransferOut` hook fires BEFORE Aqua pulls the maker's tokens.
 *
 * That ordering is the entire premise of the 90/10 design: if the hook runs first, a vault
 * holding only a small hot buffer can top itself up from the carry adapter inside the
 * settlement transaction and still honour a fill larger than the buffer.
 *
 * The hook signature below is MEASURED, not assumed. The published SwapVM ABI does not
 * document it; the rehearsal captured the raw calldata the router sends and matched the
 * selector 0x5a394f80 to this exact signature.
 *
 * NOT FOR DEPLOYMENT. Fork fixture only: no access control beyond the router check, no
 * share accounting, and a sweep function the real vault must never have (ADP-R5).
 */
contract StubMaker {
    event PreTransferOutFired(
        address token, uint256 amount, uint256 liquidBefore, uint256 parkedBefore
    );
    event JitUnpark(address token, uint256 amount);

    address public immutable ROUTER;
    address public immutable AQUA;

    StubAdapter public adapter;

    /// Recorded so the rehearsal asserts on state rather than reading a trace by eye.
    bool public hookFired;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public liquidAtHook;
    uint256 public jitUnparked;
    uint256 public hookCalls;

    error OnlyRouter();

    constructor(address router, address aqua) {
        ROUTER = router;
        AQUA = aqua;
    }

    function setAdapter(StubAdapter newAdapter) external {
        adapter = newAdapter;
    }

    function approveAqua(address token, uint256 amount) external {
        IERC20(token).approve(AQUA, amount);
    }

    /**
     * Stand-in for the vault's execShip/execDock: lets the rehearsal drive ship and dock
     * with the CONTRACT as maker. The real vault restricts this to an owner and to
     * allowlisted routers and tokens (VLT-R7); the fixture does not, on purpose.
     */
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /**
     * The maker hook the AquaSwapVMRouter actually calls, selector 0x5a394f80.
     *
     * `tokenOut` is what the maker owes the taker, so it is the token this vault must be
     * holding by the time Aqua pulls, and `amountOut` is how much. Everything else is
     * context the real vault will want for accounting and for the keeper log.
     */
    function preTransferOut(
        address, /* maker */
        address, /* taker */
        address, /* tokenIn */
        address tokenOut,
        uint256, /* amountIn */
        uint256 amountOut,
        bytes32, /* orderHash */
        bytes calldata, /* makerHookData */
        bytes calldata /* takerHookData */
    ) external {
        if (msg.sender != ROUTER) revert OnlyRouter();

        uint256 liquid = IERC20(tokenOut).balanceOf(address(this));
        uint256 parkedBefore =
            address(adapter) == address(0) ? 0 : adapter.parkedBalance(tokenOut);

        hookCalls += 1;
        hookFired = true;
        lastToken = tokenOut;
        lastAmount = amountOut;
        liquidAtHook = liquid;
        emit PreTransferOutFired(tokenOut, amountOut, liquid, parkedBefore);

        if (liquid >= amountOut) return;

        // VLT-R9: unpark only the shortfall beyond the hot buffer, never the whole sleeve.
        uint256 shortfall = amountOut - liquid;
        adapter.unpark(tokenOut, shortfall);
        jitUnparked += shortfall;
        emit JitUnpark(tokenOut, shortfall);
    }

    /// Escape hatch for the fixture; the real vault has no such function (ADP-R5).
    function sweep(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}
