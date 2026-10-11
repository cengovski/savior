// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Fresh-start SAVIOR: fixed supply, no mint after ctor, burn, Ownable2Step rescue
///         of foreign ERC-20/native only (never own token). logoURI owner-updatable.
/// @dev Prototype for feature/fresh-start — audit before mainnet.
///      Owner powers: setLogoURI + foreign ERC-20/native rescue ONLY. renounceOwnership disabled.
contract SaviorTokenV2 is Ownable2Step {
    string public constant name = "SAVIOR";
    string public constant symbol = "SAVIOR";
    uint8 public constant decimals = 6;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e6; // 1B

    /// @notice Wallet/metadata logo. Owner may update via {setLogoURI}.
    ///         Prefer `ipfs://…` or HTTPS; on-chain `data:image/svg+xml;base64,…` OK if small (~3KB).
    string public logoURI;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event LogoURIUpdated(string logoURI);

    error ZeroAddress();
    error CannotRescueOwnToken();
    error RenounceDisabled();

    constructor(address recipient, address initialOwner, string memory logoURI_) Ownable(initialOwner) {
        if (recipient == address(0) || initialOwner == address(0)) revert ZeroAddress();
        logoURI = logoURI_;
        emit LogoURIUpdated(logoURI_);
        totalSupply = TOTAL_SUPPLY;
        balanceOf[recipient] = TOTAL_SUPPLY;
        emit Transfer(address(0), recipient, TOTAL_SUPPLY);
    }

    /// @notice Update logo URI. Only owner.
    function setLogoURI(string calldata newLogoURI) external onlyOwner {
        logoURI = newLogoURI;
        emit LogoURIUpdated(newLogoURI);
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
            unchecked {
                allowance[from][msg.sender] = a - amount;
            }
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

    /// @notice Rescue foreign ERC-20 or native USDC gas token. Cannot rescue this SAVIOR.
    /// @param token `address(0)` = native; otherwise ERC-20. Must not be `address(this)`.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(this)) revert CannotRescueOwnToken();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native");
        } else {
            SafeERC20.safeTransfer(IERC20(token), to, amount); // audit B-3: non-bool tokens
        }
        emit Rescued(token, to, amount);
    }

    /// @notice Ownership can only be transferred (2-step), never renounced.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    receive() external payable {}

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
