// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SaviorStakingFresh} from "../src/fresh/SaviorStakingFresh.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Attacker tries to accept a stake only if duration would be short — cannot know at commit.
contract ConditionalStakeAttacker {
    SaviorStakingFresh public immutable staking;
    SaviorTokenV2 public immutable token;

    constructor(SaviorStakingFresh s, SaviorTokenV2 t) {
        staking = s;
        token = t;
    }

    function tryStake(uint256 amount) external {
        token.approve(address(staking), amount);
        uint256 idx = staking.stake(amount);
        SaviorStakingFresh.LockView memory L = staking.getLocks(address(this))[idx];
        // Default 10d already set; future target hash unknown → cannot decide to keep/revert based on short duration.
        bytes32 h = blockhash(L.targetBlock);
        require(h == bytes32(0), "future hash should be unknown");
        require(L.isPending && L.unlockAt == L.createdAt + 10 days, "default 10d pending");
        revert("cannot know shortened duration at commit");
    }
}

contract CommitRevealLockTest is Test {
    SaviorTokenV2 token;
    SaviorStakingFresh staking;
    address owner = address(this);
    address user = makeAddr("user");
    address other = makeAddr("other");

    string constant LOGO = "ipfs://test";

    function setUp() public {
        token = new SaviorTokenV2(user, owner, LOGO);
        PoolKey memory key = PoolKey({
            currency0: address(0x3600000000000000000000000000000000000000),
            currency1: address(token),
            fee: 10000,
            tickSpacing: 200,
            hooks: makeAddr("hook")
        });
        staking = new SaviorStakingFresh(
            owner, IERC20(address(token)), IPoolManagerMinimal(makeAddr("pm")), makeAddr("treasury"), key
        );
        vm.prank(user);
        token.approve(address(staking), type(uint256).max);
    }

    function _stakeAs(address u, uint256 amt) internal returns (uint256 idx) {
        vm.prank(u);
        idx = staking.stake(amt);
    }

    function test_default_10d_pending_on_commit() public {
        uint256 idx = _stakeAs(user, 10e6);
        SaviorStakingFresh.LockView memory L = staking.getLocks(user)[idx];
        assertEq(L.amount, 10e6);
        assertEq(L.unlockAt, L.createdAt + 10 days);
        assertEq(L.unlockAt, L.createdAt + staking.DEFAULT_LOCK());
        assertTrue(L.isPending);
        assertTrue(staking.isPending(user, idx));
        assertEq(L.targetBlock, uint64(block.number + staking.REVEAL_DELAY_BLOCKS()));
        assertEq(L.revealDeadlineBlock, L.targetBlock + staking.BLOCKHASH_WINDOW());
        assertFalse(L.revealableNow);
        assertFalse(staking.revealableNow(user, idx));
    }

    function test_reveal_by_anyone_shortens_never_lengthens() public {
        uint256 idx = _stakeAs(user, 10e6);
        SaviorStakingFresh.LockView memory L = staking.getLocks(user)[idx];
        uint64 defaultUnlock = L.unlockAt;

        vm.expectRevert(SaviorStakingFresh.TooEarly.selector);
        staking.reveal(user, idx);

        uint256 target = L.targetBlock;
        vm.roll(target + 1);
        // Force a hash that yields a short extra (search a few)
        bytes32 h;
        uint64 expectedDur;
        for (uint256 salt = 1; salt < 500; salt++) {
            h = keccak256(abi.encode("h", salt));
            uint256 extra = uint256(keccak256(abi.encode(h, user, idx, L.createdAt)))
                % (uint256(staking.MAX_EXTRA_LOCK()) + 1);
            expectedDur = uint64(staking.LOCK_DURATION() + extra);
            if (expectedDur < 10 days) break;
        }
        vm.setBlockhash(target, h);

        assertTrue(staking.revealableNow(user, idx));
        assertTrue(staking.getLocks(user)[idx].revealableNow);

        vm.prank(other);
        staking.reveal(user, idx);

        L = staking.getLocks(user)[idx];
        assertFalse(L.isPending);
        assertEq(L.unlockAt, L.createdAt + expectedDur);
        assertTrue(L.unlockAt <= defaultUnlock); // never lengthens
        assertEq(L.unlockAt, defaultUnlock < L.createdAt + expectedDur ? defaultUnlock : L.createdAt + expectedDur);

        vm.expectRevert(SaviorStakingFresh.AlreadyRevealed.selector);
        staking.reveal(user, idx);
    }

    function test_reveal_never_lengthens() public {
        // For many seeds, unlockAt after reveal is always <= default 10d
        for (uint256 n = 0; n < 8; n++) {
            address u = makeAddr(string(abi.encodePacked("u", n)));
            vm.prank(user);
            token.transfer(u, 10e6);
            vm.prank(u);
            token.approve(address(staking), 10e6);
            vm.prank(u);
            uint256 idx = staking.stake(10e6);
            uint64 before = staking.getLocks(u)[idx].unlockAt;
            uint256 target = staking.getLocks(u)[idx].targetBlock;
            vm.roll(target + 1);
            vm.setBlockhash(target, keccak256(abi.encode("seed", n)));
            staking.reveal(u, idx);
            assertLe(staking.getLocks(u)[idx].unlockAt, before);
            assertFalse(staking.isPending(u, idx));
            // advance so next stake gets a fresh target relative to chain tip
            vm.roll(block.number + 1);
        }
    }

    function test_window_expiry_keeps_10d_reveal_reverts() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint64 created = staking.getLocks(user)[idx].createdAt;
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        // Beyond 256-block window; leave hash unset → 0
        vm.roll(target + 300);

        assertTrue(staking.isPending(user, idx));
        assertTrue(staking.revealWindowClosed(user, idx));
        assertFalse(staking.revealableNow(user, idx));

        vm.expectRevert(SaviorStakingFresh.RevealWindowClosed.selector);
        staking.reveal(user, idx);

        // still default 10d
        assertEq(staking.getLocks(user)[idx].unlockAt, created + 10 days);

        staking.finalizeExpired(user, idx);
        assertFalse(staking.isPending(user, idx));
        assertEq(staking.getLocks(user)[idx].unlockAt, created + 10 days);
    }

    function test_claim_auto_reveals_in_window() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        uint64 created = staking.getLocks(user)[idx].createdAt;
        vm.roll(target + 1);
        bytes32 h = keccak256("auto");
        vm.setBlockhash(target, h);
        uint256 extra = uint256(keccak256(abi.encode(h, user, idx, created)))
            % (uint256(staking.MAX_EXTRA_LOCK()) + 1);
        uint64 unlockAt = created + uint64(staking.LOCK_DURATION() + extra);
        vm.warp(unlockAt + 1);

        uint256 before = token.balanceOf(user);
        vm.prank(user);
        staking.claim(idx);
        assertEq(token.balanceOf(user), before + 10e6);
        assertEq(staking.getLocks(user)[idx].amount, 0);
        assertFalse(staking.getLocks(user)[idx].isPending);
    }

    function test_claim_after_window_uses_10d_no_reveal() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint64 created = staking.getLocks(user)[idx].createdAt;
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 300);
        vm.warp(created + 10 days + 1);

        uint256 before = token.balanceOf(user);
        vm.prank(user);
        staking.claim(idx);
        assertEq(token.balanceOf(user), before + 10e6);
    }

    function test_claim_before_unlock_reverts() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(SaviorStakingFresh.Locked.selector);
        staking.claim(idx);
    }

    function test_attacker_cannot_precompute_at_commit() public {
        ConditionalStakeAttacker atk = new ConditionalStakeAttacker(staking, token);
        vm.prank(user);
        token.transfer(address(atk), 10e6);
        vm.expectRevert(bytes("cannot know shortened duration at commit"));
        atk.tryStake(10e6);
        assertEq(token.balanceOf(address(atk)), 10e6);
        assertEq(staking.getLocks(address(atk)).length, 0);
    }

    function test_multiple_locks_same_block_different_seeds() public {
        uint256 i0 = _stakeAs(user, 10e6);
        uint256 i1 = _stakeAs(user, 10e6);
        assertEq(staking.getLocks(user)[i0].targetBlock, staking.getLocks(user)[i1].targetBlock);
        uint256 target = staking.getLocks(user)[i0].targetBlock;
        vm.roll(target + 1);
        bytes32 h = keccak256("same");
        vm.setBlockhash(target, h);
        staking.reveal(user, i0);
        staking.reveal(user, i1);
        uint64 c0 = staking.getLocks(user)[i0].createdAt;
        uint64 c1 = staking.getLocks(user)[i1].createdAt;
        assertTrue(keccak256(abi.encode(h, user, i0, c0)) != keccak256(abi.encode(h, user, i1, c1)));
    }

    function test_getLocks_revealable_flag() public {
        uint256 idx = _stakeAs(user, 10e6);
        assertFalse(staking.getLocks(user)[idx].revealableNow);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("x"));
        assertTrue(staking.getLocks(user)[idx].revealableNow);
        staking.reveal(user, idx);
        assertFalse(staking.getLocks(user)[idx].revealableNow);
        assertFalse(staking.getLocks(user)[idx].isPending);
    }
}
