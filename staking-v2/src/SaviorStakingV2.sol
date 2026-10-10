// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey, SwapParams, IPoolManagerMinimal, IUnlockCallback, TickMathBounds} from "./IV4Minimal.sol";

/// @title SaviorStakingV2
/// @notice Drop-in replacement for the lock/claim part of the live SaviorStaking
///         (0xBCA651C0A0540a1fCDef066B5476d714431fa525, Arc 5042). Interface reconstructed
///         from on-chain bytecode: claim(uint256) 0x379607f5, getLocks(address) 0x719f3089,
///         globalUnlock() 0x06aec0ef, emergencyUnlockAll() 0xe20cc079, rescue(address,uint256) 0x7a4e4ecf,
///         errors Locked() 0x0f2e5b6c / NotOwner() replaced by OZ OwnableUnauthorizedAccount.
///         Lock duration: pseudo-random 5 to 10 days like v1, but the seed no longer contains a caller-chosen
///         value (audit D-1): keccak256(blockhash(n-1), user, msg.sender, userLockNonce[user], globalLockNonce).
///         Buy/sell flow (unlockCallback 0x91dd7346) reproduces v1 as observed on an
///         Arc fork trace: pull tokenIn -> PoolManager.unlock -> swap exact-in -> sync/transfer/settle -> take;
///         0.3% of output to treasury; on buy the net SAVIOR is split 50% to buyer / 50% locked 5-10 days;
///         selling in the same block as your last buy reverts SameBlock(); slippage/zero reverts Bad().
///         Unlike v1, swapExactIn takes a 4th `deadline` argument (audit D-3), selector differs from v1's 0x1d2105ba.
///         stake/stakeFor require at least MIN_STAKE (1 SAVIOR) to prevent dust-lock spam (audit D-2).
/// @dev No proxy, no upgrade path. Owner set in constructor (Ownable2Step) instead of a hardcoded deployer.
contract SaviorStakingV2 is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    struct Lock {
        uint128 amount;
        uint64 unlockAt;
    }

    uint64 public constant LOCK_DURATION = 5 days; // minimum lock
    uint64 public constant MAX_EXTRA_LOCK = 5 days; // + up to 5 days pseudo-random (v1 parity)
    /// @notice Minimum SAVIOR (6 decimals) accepted by stake/stakeFor = 1 SAVIOR. Blocks dust-lock spam
    ///         (anyone can stakeFor any user). Buys are not subject to it (their lock is half the swap output).
    uint256 public constant MIN_STAKE = 1e6;
    uint256 public constant TREASURY_FEE_BPS = 30; // 0.3%, matches v1 trace

    IERC20 public immutable savior;
    IPoolManagerMinimal public immutable poolManager;
    address public immutable treasury;

    // pool key (immutable, so keySet() is always true)
    address internal immutable _c0;
    address internal immutable _c1;
    uint24 internal immutable _fee;
    int24 internal immutable _tickSpacing;
    address internal immutable _hooks;
    bool internal immutable _saviorIsCurrency1;

    mapping(address => uint64) public lastBuyBlock;
    /// @notice per-user / global counters mixed into the lock-duration seed (audit D-1)
    mapping(address => uint256) public userLockNonce;
    uint256 public globalLockNonce;

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
    error SameBlock();
    error Bad();
    error OnlyPoolManager();
    error BadPoolKey();
    error Expired();
    error BelowMinStake();

    event Swapped(
        address indexed user, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 fee, uint256 locked
    );

    constructor(
        address initialOwner,
        IERC20 saviorToken,
        IPoolManagerMinimal poolManager_,
        address treasury_,
        PoolKey memory key_
    ) Ownable(initialOwner) {
        if (address(saviorToken) == address(0) || address(poolManager_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (key_.currency0 >= key_.currency1) revert BadPoolKey();
        if (key_.currency0 != address(saviorToken) && key_.currency1 != address(saviorToken)) revert BadPoolKey();
        savior = saviorToken;
        poolManager = poolManager_;
        treasury = treasury_;
        _c0 = key_.currency0;
        _c1 = key_.currency1;
        _fee = key_.fee;
        _tickSpacing = key_.tickSpacing;
        _hooks = key_.hooks;
        _saviorIsCurrency1 = key_.currency1 == address(saviorToken);
    }

    // ---------------------------------------------------------------- pool views (v1-compatible)

    function key()
        public
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        return (_c0, _c1, _fee, _tickSpacing, _hooks);
    }

    /// @notice v1 compat (0x788499c0). Key is fixed at construction.
    function keySet() external pure returns (bool) {
        return true;
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey(_c0, _c1, _fee, _tickSpacing, _hooks);
    }

    // ---------------------------------------------------------------- buy & lock / sell

    /// @notice Exact-input swap through the SAVIOR v4 pool.
    ///         Buy (tokenIn = quote, tokenOut = SAVIOR): net SAVIOR split 50% to caller, 50% locked for 5-10 days.
    ///         Sell (tokenIn = SAVIOR): net quote token to caller. 0.3% of output goes to treasury.
    /// @param zeroForOne v4 direction (currency0 -> currency1). On the live pool currency0 = USDC, so true = buy.
    /// @param minOut minimum net output (after treasury fee) the caller accepts.
    /// @param deadline unix timestamp after which the swap reverts with Expired().
    function swapExactIn(bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 net)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert Bad();
        bool isBuy = (zeroForOne == _saviorIsCurrency1);
        if (isBuy) {
            lastBuyBlock[msg.sender] = uint64(block.number);
        } else if (lastBuyBlock[msg.sender] == block.number) {
            revert SameBlock();
        }
        (uint256 received, uint256 out) = _pullAndSwap(zeroForOne, amountIn);
        address tokenOut = zeroForOne ? _c1 : _c0;

        uint256 fee = out * TREASURY_FEE_BPS / 10_000;
        net = out - fee;
        if (net == 0 || net < minOut) revert Bad();
        if (fee != 0) IERC20(tokenOut).safeTransfer(treasury, fee);

        uint256 locked = isBuy ? _payBuy(tokenOut, net) : _paySell(tokenOut, net);
        emit Swapped(msg.sender, zeroForOne, received, out, fee, locked);
    }

    /// @dev pull tokenIn, swap through PoolManager.unlock, refund unswapped input; returns (received, gross out)
    function _pullAndSwap(bool zeroForOne, uint256 amountIn) internal returns (uint256 received, uint256 out) {
        address tokenIn = zeroForOne ? _c0 : _c1;
        address tokenOut = zeroForOne ? _c1 : _c0;

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        received = IERC20(tokenIn).balanceOf(address(this)) - inBefore;
        if (received == 0) revert Bad();

        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));
        poolManager.unlock(abi.encode(zeroForOne, received));
        out = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        // refund any unswapped input (price-limit partial fill)
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this)) - inBefore;
        if (leftover != 0) IERC20(tokenIn).safeTransfer(msg.sender, leftover);
    }

    function _paySell(address tokenOut, uint256 net) internal returns (uint256) {
        IERC20(tokenOut).safeTransfer(msg.sender, net);
        return 0;
    }

    /// @dev buy: lock half of the net SAVIOR for the caller, send the rest
    function _payBuy(address tokenOut, uint256 net) internal returns (uint256 locked) {
        locked = net / 2;
        if (locked != 0) {
            if (locked > type(uint128).max) revert AmountTooLarge();
            uint64 unlockAt = _nextUnlockAt(msg.sender);
            uint256 index = _locks[msg.sender].length;
            _locks[msg.sender].push(Lock(uint128(locked), unlockAt));
            totalLocked += locked;
            emit Staked(msg.sender, index, locked, unlockAt);
        }
        IERC20(tokenOut).safeTransfer(msg.sender, net - locked);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (bool zeroForOne, uint256 amountIn) = abi.decode(data, (bool, uint256));
        int256 delta = poolManager.swap(
            _poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMathBounds.MIN_SQRT_PRICE + 1 : TickMathBounds.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        (address cIn, address cOut) = zeroForOne ? (_c0, _c1) : (_c1, _c0);
        (int128 dIn, int128 dOut) = zeroForOne ? (d0, d1) : (d1, d0);
        if (dIn > 0 || dOut <= 0) revert Bad();
        uint256 pay = uint256(uint128(-dIn));
        poolManager.sync(cIn);
        IERC20(cIn).safeTransfer(address(poolManager), pay);
        poolManager.settle();
        poolManager.take(cOut, address(this), uint256(uint128(dOut)));
        return "";
    }

    /// @notice Lock `amount` (>= MIN_STAKE) SAVIOR for 5-10 days (same pseudo-random schedule as buys).
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
        if (amount < MIN_STAKE) revert BelowMinStake();
        uint256 before = savior.balanceOf(address(this));
        savior.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = savior.balanceOf(address(this)) - before; // fee-on-transfer safe
        if (received < MIN_STAKE) revert BelowMinStake();
        if (received > type(uint128).max) revert AmountTooLarge();
        uint64 unlockAt = _nextUnlockAt(user);
        index = _locks[user].length;
        _locks[user].push(Lock(uint128(received), unlockAt));
        totalLocked += received;
        emit Staked(user, index, received, unlockAt);
    }

    /// @dev 5-10 days. Seed has no caller-chosen value (amount removed, audit D-1); the nonces change with every
    ///      lock, so one caller cannot cheaply re-roll within a block. Still not secure randomness: a block producer,
    ///      or a caller who simulates and only submits in a favourable block, can bias it within the 5-10 day range.
    function _nextUnlockAt(address user) internal returns (uint64) {
        uint256 un = userLockNonce[user]++;
        uint256 gn = globalLockNonce++;
        uint256 r = uint256(keccak256(abi.encode(blockhash(block.number - 1), user, msg.sender, un, gn)))
            % (uint256(MAX_EXTRA_LOCK) + 1);
        return uint64(block.timestamp + LOCK_DURATION + r);
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
