// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
/// Test-only stand-in for Arc's native-USDC ERC-20 on an anvil fork (Arc precompiles are not available locally).
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function decimals() external pure returns (uint8) { return 6; }
    function symbol() external pure returns (string memory) { return "USDC"; }
    function setBalance(address a, uint256 v) external { balanceOf[a] = v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; emit Approval(msg.sender, s, v); return true; }
    function transfer(address to, uint256 v) external returns (bool) { _t(msg.sender, to, v); return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) { require(a >= v, "allowance"); allowance[f][msg.sender] = a - v; }
        _t(f, to, v); return true;
    }
    function _t(address f, address to, uint256 v) internal { require(balanceOf[f] >= v, "balance"); balanceOf[f] -= v; balanceOf[to] += v; emit Transfer(f, to, v); }
}
