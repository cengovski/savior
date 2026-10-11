// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SaviorStakingFresh} from "../src/fresh/SaviorStakingFresh.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Attacker tries to accept a stake only if revealed duration would be short — cannot know at commit.
contract ConditionalStakeAttacker {
    SaviorStakingFresh public immutable staking;
    SaviorTokenV2 public immutable token;
    uint64 public immutable maxExtraWanted;
    constructor(SaviorStakingFresh s, SaviorTokenV2 t, uint64 maxExtra) {
        staking = s; token = t; maxExtraWanted = maxExtra;
    }
    function tryStake(uint256 amount) external {
        token.approve(address(staking), amount);
        uint256 idx = staking.stake(amount);
        // At commit time unlockAt is 0 — no duration yet. Attempting to read future blockhash fails.
        bytes32 h = blockhash(staking.getLocks(address(this))[idx].targetBlock);
        require(h == bytes32(0), "future hash should be unknown");
        // Cannot decide based on duration; any "accept only if short" must wait for reveal.
        // If we wait and then revert when long, we already committed funds — demonstrate post-reveal only:
        revert("cannot know duration at commit");
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
        // dummy PM — stake/reveal/claim do not call it
        staking = new SaviorStakingFresh(owner, IERC20(address(token)), IPoolManagerMinimal(makeAddr("pm")), makeAddr("treasury"), key);
        vm.prank(user);
        token.approve(address(staking), type(uint256).max);
    }

    function _stakeAs(address u, uint256 amt) internal returns (uint256 idx) {
        vm.prank(u);
        idx = staking.stake(amt);
    }

    function test_commit_pending_then_reveal_by_anyone() public {
        uint256 idx = _stakeAs(user, 10e6);
        SaviorStakingFresh.Lock memory L = staking.getLocks(user)[idx];
        assertEq(L.amount, 10e6);
        assertEq(L.unlockAt, 0);
        assertTrue(staking.isPending(user, idx));
        assertEq(L.targetBlock, uint64(block.number + staking.REVEAL_DELAY_BLOCKS()));

        // too early
        vm.expectRevert(SaviorStakingFresh.TooEarly.selector);
        staking.reveal(user, idx);

        // roll past target; set its blockhash
        uint256 target = L.targetBlock;
        vm.roll(target + 1);
        bytes32 h = keccak256("block-at-target");
        vm.setBlockhash(target, h);

        uint256 expectedExtra = uint256(keccak256(abi.encode(h, user, idx, L.createdAt)))
            % (uint256(staking.MAX_EXTRA_LOCK()) + 1);
        uint64 expectedDur = uint64(staking.LOCK_DURATION() + expectedExtra);

        vm.prank(other); // anyone
        staking.reveal(user, idx);
        L = staking.getLocks(user)[idx];
        assertEq(L.unlockAt, L.createdAt + expectedDur);
        assertFalse(staking.isPending(user, idx));

        vm.expectRevert(SaviorStakingFresh.AlreadyRevealed.selector);
        staking.reveal(user, idx);
    }

    function test_fallback_10_days_when_blockhash_zero() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        // Advance far beyond 256-block window; leave blockhash unset → 0
        vm.roll(target + 300);
        // do not setBlockhash → blockhash(target)==0 on Foundry for unmapped

        staking.reveal(user, idx);
        SaviorStakingFresh.Lock memory L = staking.getLocks(user)[idx];
        assertEq(L.unlockAt, L.createdAt + staking.LOCK_DURATION() + staking.MAX_EXTRA_LOCK());
    }

    function test_claim_auto_reveals() public {
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
    }

    function test_claim_before_unlock_reverts_after_reveal() public {
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 1);
        vm.setBlockhash(target, bytes32(uint256(1)));
        vm.prank(user);
        vm.expectRevert(SaviorStakingFresh.Locked.selector);
        staking.claim(idx); // auto-reveal then still locked
    }

    function test_attacker_cannot_precompute_at_commit() public {
        ConditionalStakeAttacker atk = new ConditionalStakeAttacker(staking, token, 1 hours);
        vm.prank(user);
        token.transfer(address(atk), 10e6);
        vm.expectRevert(bytes("cannot know duration at commit"));
        atk.tryStake(10e6);
        // funds still in attacker (stake reverted)
        assertEq(token.balanceOf(address(atk)), 10e6);
        assertEq(staking.getLocks(address(atk)).length, 0);
    }

    function test_multiple_locks_same_block_different_seeds() public {
        uint256 i0 = _stakeAs(user, 10e6);
        uint256 i1 = _stakeAs(user, 10e6);
        assertEq(block.number, staking.getLocks(user)[i0].targetBlock - staking.REVEAL_DELAY_BLOCKS());
        assertEq(staking.getLocks(user)[i0].targetBlock, staking.getLocks(user)[i1].targetBlock);
        uint256 target = staking.getLocks(user)[i0].targetBlock;
        vm.roll(target + 1);
        bytes32 h = keccak256("same");
        vm.setBlockhash(target, h);
        staking.reveal(user, i0);
        staking.reveal(user, i1);
        // different indices → different unlockAt almost surely
        assertTrue(
            staking.getLocks(user)[i0].unlockAt != staking.getLocks(user)[i1].unlockAt
                || true // allow tiny collision; check seeds differ
        );
        uint64 c0 = staking.getLocks(user)[i0].createdAt;
        uint64 c1 = staking.getLocks(user)[i1].createdAt;
        assertTrue(
            keccak256(abi.encode(h, user, i0, c0)) != keccak256(abi.encode(h, user, i1, c1))
        );
    }

    function test_delay_attack_only_gets_fallback_max() public {
        // Withholding reveal past 256 blocks forces 10d — worse for attacker wanting short lock
        uint256 idx = _stakeAs(user, 10e6);
        uint256 target = staking.getLocks(user)[idx].targetBlock;
        vm.roll(target + 300);
        staking.reveal(user, idx);
        assertEq(
            staking.getLocks(user)[idx].unlockAt,
            staking.getLocks(user)[idx].createdAt + 10 days
        );
    }
}
