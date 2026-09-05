// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fee-on-transfer: delivers 90% of requested amount.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("FeeOnTransfer", "FOT") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 10;
        _transfer(msg.sender, address(0xdead), fee);
        _transfer(msg.sender, to, amount - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = amount / 10;
        _transfer(from, address(0xdead), fee);
        _transfer(from, to, amount - fee);
        return true;
    }
}

/// @dev Returns false from transfer/transferFrom.
contract FalseReturnERC20 is ERC20 {
    constructor() ERC20("FalseReturn", "FALSE") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev No return data from transfer/transferFrom (USDT-style).
contract NoReturnERC20 {
    string public name = "NoReturn";
    string public symbol = "NORTN";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        totalSupply = 1_000_000_000 ether;
        balanceOf[msg.sender] = totalSupply;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Reenters an arbitrary target with calldata during transferFrom.
contract ReentrantTransferFromERC20 is ERC20 {
    address public target;
    bytes public data;
    bool public armed;

    constructor() ERC20("Reentrant", "REENT") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok,) = target.call(data);
            ok; // ignore
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Reverts on transferFrom (blacklist style).
contract BlacklistERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blacklist", "BLKL") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blocked[from] && !blocked[to], "blocked");
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Configurable decimals; decimals() may revert.
contract WeirdDecimalsERC20 is ERC20 {
    uint8 private _dec;
    bool public decimalsReverts;

    constructor(uint8 dec) ERC20("WeirdDec", "WDEC") {
        _dec = dec;
        _mint(msg.sender, 1_000_000_000 * (10 ** uint256(dec)));
    }

    function setDecimalsReverts(bool v) external {
        decimalsReverts = v;
    }

    function decimals() public view override returns (uint8) {
        if (decimalsReverts) revert("decimals-boom");
        return _dec;
    }
}

/// @dev Over-delivers on transferFrom (+1 wei minted to recipient).
contract OverDeliverERC20 is ERC20 {
    constructor() ERC20("OverDeliver", "OVER") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        _mint(to, 1);
        return true;
    }
}
