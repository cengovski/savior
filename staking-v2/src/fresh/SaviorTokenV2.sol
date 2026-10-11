// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fresh-start plan prototype: fixed-supply ERC20, no proxy, no mint after ctor, optional burn.
/// @dev NOT for mainnet as-is — plan review first. No Ownable rescue of this token.
contract SaviorTokenV2 {
    string public constant name = "SAVIOR";
    string public constant symbol = "SAVIOR";
    uint8 public constant decimals = 6;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e6; // 1B

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address recipient) {
        require(recipient != address(0), "zero");
        totalSupply = TOTAL_SUPPLY;
        balanceOf[recipient] = TOTAL_SUPPLY;
        emit Transfer(address(0), recipient, TOTAL_SUPPLY);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allow");
            unchecked { allowance[from][msg.sender] = a - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        uint256 bal = balanceOf[msg.sender];
        require(bal >= amount, "bal");
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "bal");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
