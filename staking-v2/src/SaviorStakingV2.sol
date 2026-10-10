// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SaviorStakingV2
/// @notice Drop-in replacement for the lock/claim part of the live SaviorStaking
///         (0xBCA651C0A0540a1fCDef066B5476d714431fa525, Arc 5042). Interface reconstructed
///         from on-chain bytecode: claim(uint256) 0x379607f5, getLocks(address) 0x719f3089,
///         globalUnlock() 0x06aec0ef, emergencyUnlockAll() 0xe20cc079, rescue(address,uint256) 0x7a4e4ecf,
///         errors Locked() 0x0f2e5b6c / NotOwner() replaced by OZ OwnableUnauthorizedAccount.
///         Lock duration 432000s (5 days) = PUSH3 0x069780 in v1 runtime code.
/// @dev No proxy, no upgrade path. Owner set in constructor (Ownable2Step) instead of a hardcoded deployer.
contract SaviorStakingV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        uint128 amount;
        uint64 unlockAt;
    }

    uint64 public constant LOCK_DURATION = 5 days;

    IERC20 public immutable savior;

    /// @notice once true, every lock is claimable immediately (irreversible).
    bool public globalUnlock;
    /// @notice SAVIOR currently owed to stakers; rescue can never dip below this.
    uint256 public totalLocked;

    mapping(address => Lock[]) private _locks;

    event Staked(address indexed user, uint256 indexed index, uint256 amount, uint64 unlockAt);
    event Claimed(address indexed user, uint256 indexed index, uint256 amount);
    event EmergencyUnlockAll(address indexed by);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error Locked();
    error ZeroAmount();
    error BadIndex();
    error NothingToClaim();
    error AmountTooLarge();
    error ExceedsSurplus();
    error ZeroAddress();

    constructor(address initialOwner, IERC20 saviorToken) Ownable(initialOwner) {
        if (address(saviorToken) == address(0)) revert ZeroAddress();
        savior = saviorToken;
    }

    /// @notice Lock `amount` SAVIOR for LOCK_DURATION.
    function stake(uint256 amount) external nonReentrant returns (uint256 index) {
        return _stake(msg.sender, amount);
    }

    /// @notice Lock on behalf of `user` (funds pulled from msg.sender) - used for migration/airdrops.
    function stakeFor(address user, uint256 amount) external nonReentrant returns (uint256 index) {
        if (user == address(0)) revert ZeroAddress();
        return _stake(user, amount);
    }

    function _stake(address user, uint256 amount) internal returns (uint256 index) {
        if (amount == 0) revert ZeroAmount();
        uint256 before = savior.balanceOf(address(this));
        savior.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = savior.balanceOf(address(this)) - before; // fee-on-transfer safe
        if (received == 0) revert ZeroAmount();
        if (received > type(uint128).max) revert AmountTooLarge();
        uint64 unlockAt = uint64(block.timestamp) + LOCK_DURATION;
        index = _locks[user].length;
        _locks[user].push(Lock(uint128(received), unlockAt));
        totalLocked += received;
        emit Staked(user, index, received, unlockAt);
    }

    /// @notice Claim lock `i`. Reverts Locked() before unlockAt unless globalUnlock.
    function claim(uint256 i) external nonReentrant {
        Lock[] storage ls = _locks[msg.sender];
        if (i >= ls.length) revert BadIndex();
        Lock storage l = ls[i];
        uint256 amt = l.amount;
        if (amt == 0) revert NothingToClaim();
        if (!globalUnlock && block.timestamp < l.unlockAt) revert Locked();
        l.amount = 0;
        totalLocked -= amt;
        savior.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, i, amt);
    }

    function getLocks(address user) external view returns (Lock[] memory) {
        return _locks[user];
    }

    /// @notice Owner-only emergency switch: makes every lock claimable now. Irreversible.
    function emergencyUnlockAll() external onlyOwner {
        globalUnlock = true;
        emit EmergencyUnlockAll(msg.sender);
    }

    /// @notice Recover tokens sent by mistake. SAVIOR only above totalLocked (surplus).
    function rescue(address token, uint256 amount) external onlyOwner nonReentrant {
        _rescue(token, owner(), amount);
    }

    function rescueTo(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        _rescue(token, to, amount);
    }

    function _rescue(address token, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(savior)) {
            uint256 bal = savior.balanceOf(address(this));
            if (bal < totalLocked || amount > bal - totalLocked) revert ExceedsSurplus();
        }
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @dev Disable renounce so emergency unlock can never become unreachable (the v1 bug).
    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }
}
