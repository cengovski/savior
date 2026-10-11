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
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

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

    function _mockHistory(uint256 blockNumber, bytes32 h) internal {
        vm.mockCall(HISTORY, abi.encode(blockNumber), abi.encode(h));
    }

    function test_default_10d_pending_on_commit() public {
        uint256 idx = _stakeAs(user, 10e6);
        SaviorStakingFresh.LockView memory L = staking.getLocks(user)[idx];
        assertEq(L.amount, 10e6);
        assertEq(L.unlockAt, L.createdAt + 10 days);
        assertTrue(L.isPending);
        assertEq(L.targetBlock, uint64(block.number + staking.REVEAL_DELAY_BLOCKS()));
        assertEq(L.revealDeadlineBlock, L.targetBlock + staking.HISTORY_SERVE_WINDOW());
        assertEq(L.revealDeadlineBlock, L.targetBlock + 8191);
        assertFalse(L.revealableNow);
    }

    function test_reveal_by_anyone_via_native_blockhash() public {
        uint256 idx = _stakeAs(user, 10e6);
        SaviorStakingFresh.LockView memory L = staking.getLocks(user)[idx];
        uint64 defaultUnlock = L.unlockAt;
        uint256 target = L.targetBlock;

        vm.expectRevert(SaviorStakingFresh.TooEarly.selector);
        staking.reveal(user, idx);

        vm.roll(target + 1);
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

        vm.prank(other);
        staking.reveal(user, idx);
        L = staking.getLocks(user)[idx];
        assertFalse(L.isPending);
        assertEq(L.unlockAt, L.createdAt + expectedDur);
        assertTrue(L.unlockAt <= defaultUnlock);
    }

    function test_reveal_via_eip2935_after_native_window() public {
        // Roll past 256 so native blockhash is 0; EIP-2935 mock supplies the hash.
        uint256 idx = _stakeAs(user, 10e6);
        uint64 created = staking.getLocks(user)[idx].createdAt;
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        bytes32 h = keccak256("from-2935");
        uint256 extra = uint256(keccak256(abi.encode(h, user, idx, created)))
            % (uint256(staking.MAX_EXTRA_LOCK()) + 1);
        uint64 expectedDur = uint64(staking.LOCK_DURATION() + extra);

        vm.roll(target + 300); // >256 ⇒ native blockhash(target)==0 in Foundry unless set
        // ensure native is zero
        assertEq(blockhash(target), bytes32(0));
        _mockHistory(target, h);

        assertEq(staking.ringBlockHash(target), h);
        assertTrue(staking.revealableNow(user, idx));

        staking.reveal(user, idx);
        assertEq(staking.getLocks(user)[idx].unlockAt, created + expectedDur);
        assertFalse(staking.isPending(user, idx));
    }

    function test_reveal_never_lengthens() public {
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
            vm.roll(block.number + 1);
        }
    }

    function test_window_expiry_at_8192_keeps_10d() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint64 created = staking.getLocks(user)[idx].createdAt;
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        // Past HISTORY_SERVE_WINDOW; no mock ⇒ ringBlockHash == 0
        vm.roll(target + 8192);

        assertTrue(staking.isPending(user, idx));
        assertTrue(staking.revealWindowClosed(user, idx));
        assertFalse(staking.revealableNow(user, idx));

        vm.expectRevert(SaviorStakingFresh.RevealWindowClosed.selector);
        staking.reveal(user, idx);

        assertEq(staking.getLocks(user)[idx].unlockAt, created + 10 days);

        staking.finalizeExpired(user, idx);
        assertFalse(staking.isPending(user, idx));
        assertEq(staking.getLocks(user)[idx].unlockAt, created + 10 days);
    }

    function test_still_revealable_at_deadline_8191_with_2935() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        bytes32 h = keccak256("edge");
        vm.roll(target + 8191);
        assertEq(blockhash(target), bytes32(0));
        _mockHistory(target, h);
        assertTrue(staking.revealableNow(user, idx));
        staking.reveal(user, idx);
        assertFalse(staking.isPending(user, idx));
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
    }

    function test_claim_after_window_uses_10d_no_reveal() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint64 created = staking.getLocks(user)[idx].createdAt;
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 8192);
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
    }

    function test_revealBatch_mixed_skips() public {
        // i0: revealable, i1: already revealed, i2: too early (same target — make separate),
        // plus bad index and window-closed via mock absence after roll far... keep simple.
        uint256 i0 = _stakeAs(user, 10e6);
        uint256 i1 = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[i0].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("batch"));
        staking.reveal(user, i1); // already revealed

        // too-early lock: stake now at current block → new target = now+3
        uint256 i2 = _stakeAs(user, 10e6);
        assertFalse(staking.revealableNow(user, i2));

        address[] memory users = new address[](5);
        uint256[] memory idxs = new uint256[](5);
        users[0] = user; idxs[0] = i0; // ok
        users[1] = user; idxs[1] = i1; // already revealed → skip
        users[2] = user; idxs[2] = i2; // too early → skip
        users[3] = user; idxs[3] = 999; // bad index → skip
        users[4] = other; idxs[4] = 0; // no locks → skip

        vm.prank(other);
        uint256 revealed = staking.revealBatch(users, idxs);
        assertEq(revealed, 1);
        assertFalse(staking.isPending(user, i0));
        assertTrue(staking.isPending(user, i2));
    }

    function test_revealBatch_length_mismatch_and_max() public {
        address[] memory users = new address[](1);
        uint256[] memory idxs = new uint256[](2);
        users[0] = user;
        vm.expectRevert(SaviorStakingFresh.BatchLengthMismatch.selector);
        staking.revealBatch(users, idxs);

        uint256 max = staking.MAX_REVEAL_BATCH();
        address[] memory u2 = new address[](max + 1);
        uint256[] memory i2 = new uint256[](max + 1);
        vm.expectRevert(SaviorStakingFresh.BatchTooLarge.selector);
        staking.revealBatch(u2, i2);
    }

    function test_revealBatch_anyone_and_pendingRevealable() public {
        uint256 i0 = _stakeAs(user, 10e6);
        uint256 i1 = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[i0].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("pr"));
        uint256[] memory pend = staking.pendingRevealable(user);
        assertEq(pend.length, 2);
        assertEq(pend[0], i0);
        assertEq(pend[1], i1);

        address[] memory users = new address[](2);
        uint256[] memory idxs = new uint256[](2);
        users[0] = user; idxs[0] = i0;
        users[1] = user; idxs[1] = i1;
        vm.prank(other);
        assertEq(staking.revealBatch(users, idxs), 2);
        assertEq(staking.pendingRevealable(user).length, 0);
    }

    function test_revealBatch_gas_at_max() public {
        uint256 max = staking.MAX_REVEAL_BATCH();
        // fund and stake max locks for user
        uint256 need = max * 10e6;
        // user already has huge supply from token ctor
        for (uint256 k = 0; k < max; k++) {
            _stakeAs(user, 10e6);
        }
        uint256 target = staking.getLocks(user)[0].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("gasmax"));

        address[] memory users = new address[](max);
        uint256[] memory idxs = new uint256[](max);
        for (uint256 k = 0; k < max; k++) {
            users[k] = user;
            idxs[k] = k;
        }

        uint256 g0 = gasleft();
        uint256 revealed = staking.revealBatch(users, idxs);
        uint256 used = g0 - gasleft();
        assertEq(revealed, max);
        // log for report
        console2.log("MAX_REVEAL_BATCH", max);
        console2.log("gas_batch_total", used);
        console2.log("gas_per_item_approx", used / max);
    }

    function test_reveal_single_gas_baseline() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("one"));
        uint256 g0 = gasleft();
        staking.reveal(user, idx);
        uint256 used = g0 - gasleft();
        console2.log("gas_single_reveal", used);
    }

}
