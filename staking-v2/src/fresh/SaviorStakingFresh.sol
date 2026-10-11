// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey, SwapParams, IPoolManagerMinimal, IUnlockCallback, TickMathBounds} from "../IV4Minimal.sol";

/// @title SaviorStakingFresh
/// @notice Fresh-start staking for the new SAVIOR token. Lock duration uses user-driven commit-reveal
///         (no server/bot): at buy/stake, unlockAt defaults to createdAt+10d with isPending=true;
///         targetBlock = block.number+REVEAL_DELAY_BLOCKS; revealDeadlineBlock = targetBlock+256
///         (last height where blockhash(target) is still available). Anyone may reveal while
///         block.number > targetBlock && blockhash(target) != 0; duration = 5d + keccak(...) % (5d+1);
///         unlockAt = min(current, createdAt+duration) (never lengthens); isPending=false.
///         After the window, 10d stands (claim may finalize pending). Claim auto-reveals if still in window.
///         Buy/sell via PoolManager.unlock; 0.3% treasury; buy 50/50 lock; SameBlock sell guard;
///         swapExactIn deadline; MIN_STAKE on stake/stakeFor.
/// @dev No proxy. Ownable2Step; renounceOwnership disabled. Does NOT replace deployed SaviorStakingV2.
///      Arc ~0.5s blocks ⇒ 256-block reveal window ≈ ~2 minutes — site should prompt a second reveal tx
///      right after buy/stake confirms (no server/bot; user wallet signs).
contract SaviorStakingFresh is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @dev Storage layout for each lock.
    struct Lock {
        uint128 amount;
        uint64 unlockAt; // set immediately to createdAt+10d; may shorten on reveal
        uint64 createdAt;
        uint64 targetBlock;
        uint64 revealDeadlineBlock; // targetBlock + BLOCKHASH_WINDOW
        bool pending; // true until successful reveal (or optional finalize after window)
    }

    /// @notice ABI-friendly view of a lock (includes computed revealableNow).
    struct LockView {
        uint128 amount;
        uint64 createdAt;
        uint64 unlockAt;
        bool isPending;
        uint64 targetBlock;
        uint64 revealDeadlineBlock;
        bool revealableNow;
    }

    uint64 public constant LOCK_DURATION = 5 days; // minimum after reveal
    uint64 public constant MAX_EXTRA_LOCK = 5 days; // + up to 5 days → max 10d default
    uint64 public constant DEFAULT_LOCK = 10 days; // unlockAt at commit (= LOCK_DURATION + MAX_EXTRA_LOCK)
    /// @dev Blocks to wait before reveal. Arc sub-second finality / no reorgs → 3 is enough.
    uint64 public constant REVEAL_DELAY_BLOCKS = 3;
    /// @dev EVM retains blockhash for the 256 most recent blocks; last usable height is target+256.
    uint64 public constant BLOCKHASH_WINDOW = 256;
    /// @notice Minimum SAVIOR (6 decimals) accepted by stake/stakeFor = 1 SAVIOR.
    uint256 public constant MIN_STAKE = 1e6;
    uint256 public constant TREASURY_FEE_BPS = 30; // 0.3%

    IERC20 public immutable savior;
    IPoolManagerMinimal public immutable poolManager;
    address public immutable treasury;

    address internal immutable _c0;
    address internal immutable _c1;
    uint24 internal immutable _fee;
    int24 internal immutable _tickSpacing;
    address internal immutable _hooks;
    bool internal immutable _saviorIsCurrency1;

    mapping(address => uint64) public lastBuyBlock;

    bool public globalUnlock;
    uint256 public totalLocked;

    mapping(address => Lock[]) private _locks;

    event Staked(
        address indexed user,
        uint256 indexed index,
        uint256 amount,
        uint64 createdAt,
        uint64 unlockAt,
        uint64 targetBlock,
        uint64 revealDeadlineBlock
    );
    event LockRevealed(
        address indexed user, uint256 indexed index, uint64 unlockAt, uint64 duration, bool shortened
    );
    event LockRevealFinalized(address indexed user, uint256 indexed index, uint64 unlockAt);
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
    error TooEarly();
    error AlreadyRevealed();
    error RevealWindowClosed();
    error StillRevealable();
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

    function key()
        public
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
    {
        return (_c0, _c1, _fee, _tickSpacing, _hooks);
    }

    function keySet() external pure returns (bool) {
        return true;
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey(_c0, _c1, _fee, _tickSpacing, _hooks);
    }

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
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this)) - inBefore;
        if (leftover != 0) IERC20(tokenIn).safeTransfer(msg.sender, leftover);
    }

    function _paySell(address tokenOut, uint256 net) internal returns (uint256) {
        IERC20(tokenOut).safeTransfer(msg.sender, net);
        return 0;
    }

    function _payBuy(address tokenOut, uint256 net) internal returns (uint256 locked) {
        locked = net / 2;
        if (locked != 0) {
            if (locked > type(uint128).max) revert AmountTooLarge();
            _pushPending(msg.sender, uint128(locked));
        }
        IERC20(tokenOut).safeTransfer(msg.sender, net - locked);
    }

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

    function stake(uint256 amount) external nonReentrant returns (uint256 index) {
        return _stake(msg.sender, amount);
    }

    function stakeFor(address user, uint256 amount) external nonReentrant returns (uint256 index) {
        if (user == address(0)) revert ZeroAddress();
        return _stake(user, amount);
    }

    function _stake(address user, uint256 amount) internal returns (uint256 index) {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_STAKE) revert BelowMinStake();
        uint256 before = savior.balanceOf(address(this));
        savior.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = savior.balanceOf(address(this)) - before;
        if (received < MIN_STAKE) revert BelowMinStake();
        if (received > type(uint128).max) revert AmountTooLarge();
        index = _pushPending(user, uint128(received));
    }

    function _pushPending(address user, uint128 amount) internal returns (uint256 index) {
        index = _locks[user].length;
        uint64 createdAt = uint64(block.timestamp);
        uint64 unlockAt = createdAt + DEFAULT_LOCK; // 10 days immediately
        uint64 target = uint64(block.number + REVEAL_DELAY_BLOCKS);
        uint64 deadline = target + BLOCKHASH_WINDOW;
        _locks[user].push(Lock({
            amount: amount,
            unlockAt: unlockAt,
            createdAt: createdAt,
            targetBlock: target,
            revealDeadlineBlock: deadline,
            pending: true
        }));
        totalLocked += amount;
        emit Staked(user, index, amount, createdAt, unlockAt, target, deadline);
    }

    /// @notice True if lock still awaits a successful reveal (may still be true after window with 10d final).
    function isPending(address user, uint256 i) public view returns (bool) {
        Lock[] storage ls = _locks[user];
        if (i >= ls.length) return false;
        return ls[i].amount != 0 && ls[i].pending;
    }

    /// @notice True if reveal can succeed now (pending, past target, blockhash available).
    function revealableNow(address user, uint256 i) public view returns (bool) {
        Lock[] storage ls = _locks[user];
        if (i >= ls.length) return false;
        Lock storage l = ls[i];
        if (l.amount == 0 || !l.pending) return false;
        if (block.number <= l.targetBlock) return false;
        return blockhash(l.targetBlock) != bytes32(0);
    }

    /// @notice True if pending and the EVM blockhash window for targetBlock has closed.
    function revealWindowClosed(address user, uint256 i) public view returns (bool) {
        Lock[] storage ls = _locks[user];
        if (i >= ls.length) return false;
        Lock storage l = ls[i];
        if (l.amount == 0 || !l.pending) return false;
        if (block.number <= l.targetBlock) return false;
        return blockhash(l.targetBlock) == bytes32(0);
    }

    /// @notice Reveal while blockhash(target) is available. Callable by anyone (user-driven; no bot).
    ///         Shortens unlockAt via min(...); never lengthens. Sets pending=false.
    function reveal(address user, uint256 i) public {
        Lock[] storage ls = _locks[user];
        if (i >= ls.length) revert BadIndex();
        Lock storage l = ls[i];
        if (l.amount == 0) revert NothingToClaim();
        if (!l.pending) revert AlreadyRevealed();
        if (block.number <= l.targetBlock) revert TooEarly();

        bytes32 h = blockhash(l.targetBlock);
        if (h == bytes32(0)) revert RevealWindowClosed();

        uint256 r = uint256(keccak256(abi.encode(h, user, i, l.createdAt))) % (uint256(MAX_EXTRA_LOCK) + 1);
        uint64 duration = LOCK_DURATION + uint64(r);
        uint64 candidate = l.createdAt + duration;
        bool shortened = candidate < l.unlockAt;
        if (shortened) {
            l.unlockAt = candidate;
        }
        l.pending = false;
        emit LockRevealed(user, i, l.unlockAt, duration, shortened);
    }

    /// @notice After window closes, clear pending while keeping the default 10d unlockAt. Anyone.
    function finalizeExpired(address user, uint256 i) public {
        Lock[] storage ls = _locks[user];
        if (i >= ls.length) revert BadIndex();
        Lock storage l = ls[i];
        if (l.amount == 0) revert NothingToClaim();
        if (!l.pending) revert AlreadyRevealed();
        if (block.number <= l.targetBlock) revert TooEarly();
        if (blockhash(l.targetBlock) != bytes32(0)) revert StillRevealable();
        l.pending = false;
        emit LockRevealFinalized(user, i, l.unlockAt);
    }

    /// @notice Claim lock `i`. Auto-reveals if still in window; else finalizes 10d if window closed.
    function claim(uint256 i) external nonReentrant {
        Lock[] storage ls = _locks[msg.sender];
        if (i >= ls.length) revert BadIndex();
        Lock storage l = ls[i];
        uint256 amt = l.amount;
        if (amt == 0) revert NothingToClaim();
        if (l.pending) {
            if (block.number > l.targetBlock) {
                bytes32 h = blockhash(l.targetBlock);
                if (h != bytes32(0)) {
                    reveal(msg.sender, i);
                } else {
                    // window closed → keep 10d
                    l.pending = false;
                    emit LockRevealFinalized(msg.sender, i, l.unlockAt);
                }
            }
            // if still before targetBlock, leave pending; unlockAt is already 10d
        }
        if (!globalUnlock && block.timestamp < l.unlockAt) revert Locked();
        l.amount = 0;
        l.pending = false;
        totalLocked -= amt;
        savior.safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, i, amt);
    }

    /// @notice Locks for `user` with pending / revealableNow computed for UI.
    function getLocks(address user) external view returns (LockView[] memory out) {
        Lock[] storage ls = _locks[user];
        uint256 n = ls.length;
        out = new LockView[](n);
        for (uint256 i = 0; i < n; i++) {
            Lock storage l = ls[i];
            bool pending = l.amount != 0 && l.pending;
            bool canReveal = pending && block.number > l.targetBlock && blockhash(l.targetBlock) != bytes32(0);
            out[i] = LockView({
                amount: l.amount,
                createdAt: l.createdAt,
                unlockAt: l.unlockAt,
                isPending: pending,
                targetBlock: l.targetBlock,
                revealDeadlineBlock: l.revealDeadlineBlock,
                revealableNow: canReveal
            });
        }
    }

    function emergencyUnlockAll() external onlyOwner {
        globalUnlock = true;
        emit EmergencyUnlockAll(msg.sender);
    }

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

    function renounceOwnership() public view override onlyOwner {
        revert("renounce disabled");
    }
}
