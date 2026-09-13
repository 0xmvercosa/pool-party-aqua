// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { CashPlusVault } from "../../src/cashplus/CashPlusVault.sol";
import { SwapQuery, SwapRegisters } from "../../src/cashplus/CashPlusTypes.sol";

contract CPToken is ERC20 {
    uint8 private immutable _d;
    uint256 public fee;

    constructor(uint8 d) ERC20("Fixture", "FIX") {
        _d = d;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && fee > 0 && amount > fee) {
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract CPReceipt is CPToken {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public immutable POOL;

    constructor(address t, address p, uint8 d) CPToken(d) {
        UNDERLYING_ASSET_ADDRESS = t;
        POOL = p;
    }
}

contract CPPool {
    mapping(address => CPReceipt) public receipts;
    bool public illiquid;

    error Illiquid();

    function register(address t, uint8 d) external returns (CPReceipt r) {
        r = new CPReceipt(t, address(this), d);
        receipts[t] = r;
    }

    function setIlliquid(bool b) external {
        illiquid = b;
    }

    function supply(address t, uint256 n, address to, uint16) external {
        IERC20(t).transferFrom(msg.sender, address(this), n);
        receipts[t].mint(to, n);
    }

    function withdraw(address t, uint256 n, address to) external returns (uint256) {
        if (illiquid) revert Illiquid();
        receipts[t].burn(msg.sender, n);
        IERC20(t).transfer(to, n);
        return n;
    }

    function getReserveNormalizedIncome(address) external pure returns (uint256) {
        return 1e27;
    }
}

contract CPFeed {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public round = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setRound(uint80 r, uint80 ar) external {
        round = r;
        answeredInRound = ar;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract CPAqua {
    mapping(bytes32 => mapping(address => uint248)) public balances;
    mapping(bytes32 => bool) public used;

    function ship(address, bytes calldata order, address[] calldata tokens, uint256[] calldata amounts)
        external
        returns (bytes32 h)
    {
        h = keccak256(order);
        require(!used[h]);
        used[h] = true;
        for (uint256 i; i < tokens.length; ++i) {
            balances[h][tokens[i]] = uint248(amounts[i]);
        }
    }

    function dock(address, bytes32 h, address[] calldata tokens) external {
        for (uint256 i; i < tokens.length; ++i) {
            balances[h][tokens[i]] = 0;
        }
    }

    function rawBalances(address, address, bytes32 h, address t) external view returns (uint248, uint8) {
        return (balances[h][t], 2);
    }

    function pull(address maker, address t, uint256 n, address to) external {
        IERC20(t).transferFrom(maker, to, n);
    }
}

contract CPRouter {
    address public immutable AQUA;
    uint8 public attack;
    bytes32 public nested;

    constructor(address a) {
        AQUA = a;
    }

    function setAttack(uint8 a, bytes32 h) external {
        attack = a;
        nested = h;
    }

    function quote(CashPlusVault v, bytes32 h, address input, address output, uint256 n)
        public
        view
        returns (uint256)
    {
        SwapQuery memory q = SwapQuery(h, address(v), msg.sender, input, output, true);
        SwapRegisters memory s = SwapRegisters(1e36, 1e36, n, 0, 0);
        (,, SwapRegisters memory r) = v.PRICING().extruction(true, 37, q, s, abi.encodePacked(v.policyVersion()), "");
        return r.amountOut;
    }

    function fill(CashPlusVault v, bytes32 h, address input, address output, uint256 n, bool first)
        external
        returns (uint256 out)
    {
        out = quote(v, h, input, output, n);
        if (!first) v.preTransferOut(address(v), msg.sender, input, output, n, out, h, "", "");
        v.preTransferIn(address(v), msg.sender, input, output, n, out, h, "", "");
        if (attack == 1) v.deposit(1e6, 1, uint64(block.timestamp + 1), v.policyVersion());
        if (attack == 2) v.preTransferIn(address(v), msg.sender, input, output, n, out, nested, "", "");
        IERC20(input).transferFrom(msg.sender, address(v), n);
        v.postTransferIn(address(v), msg.sender, input, output, n, out, h, "", "");
        v.preTransferOut(address(v), msg.sender, input, output, n, out, h, "", "");
        CPAqua(AQUA).pull(address(v), output, out, msg.sender);
        v.postTransferOut(address(v), msg.sender, input, output, n, out, h, "", "");
    }
}
