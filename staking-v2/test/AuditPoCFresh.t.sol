// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SaviorStakingFresh} from "../src/fresh/SaviorStakingFresh.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {ArcAddresses} from "../src/ArcAddresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPMInit {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

/// Non-bool-returning ERC20 (USDT style) for B-3.
contract NoBoolToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external { balanceOf[msg.sender] -= a; balanceOf[to] += a; }
}

/// Auditor PoCs (/workspace/audit-fresh) adapted to prove the fixes.
contract AuditPoCFresh is Test {
    SaviorTokenV2 token;
    SaviorStakingFresh st;
    address owner = address(0xA11CE0);
    address user = address(0xB0B0);
    address attacker = address(0xBAD0);
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    function setUp() public {
        token = new SaviorTokenV2(user, owner, "ipfs://x");
        PoolKey memory key = PoolKey(ArcAddresses.USDC, address(token), 10000, 200, address(0x1234));
        if (address(token) < ArcAddresses.USDC) key = PoolKey(address(token), ArcAddresses.USDC, 10000, 200, address(0x1234));
        st = new SaviorStakingFresh(owner, IERC20(address(token)), IPoolManagerMinimal(address(0xBEEF)), address(0x7EA5), key);
        vm.prank(user);
        token.transfer(attacker, 500_000_000e6);
        vm.prank(user);
        token.approve(address(st), type(uint256).max);
        vm.prank(attacker);
        token.approve(address(st), type(uint256).max);
    }

    /// Y-1 (accepted, documented): hook-free pool remains possible; token has no transfer gate by design.
    function test_poc_fork_hooklessPoolBypass_documented() public {
        vm.skip(!vm.envOr("ARC_FORK", false));
        vm.createSelectFork("arc_mainnet");
        SaviorTokenV2 t2 = new SaviorTokenV2(attacker, owner, "x");
        (address c0, address c1) = address(t2) < ArcAddresses.USDC
            ? (address(t2), ArcAddresses.USDC) : (ArcAddresses.USDC, address(t2));
        vm.prank(attacker);
        IPMInit(ArcAddresses.POOL_MANAGER).initialize(PoolKey(c0, c1, 3000, 60, address(0)), 79228162514264337593543950336);
    }

    /// B-1: unchanged (Arc has 2935); without history code the window falls back to 256.
    function test_poc_noHistoryCode_finalizeAfter256() public {
        vm.etch(HISTORY, "");
        vm.prank(user);
        uint256 idx = st.stake(10e6);
        vm.roll(block.number + 3 + 257);
        assertFalse(st.revealableNow(user, idx));
        vm.prank(attacker);
        st.finalizeExpired(user, idx);
        SaviorStakingFresh.LockView memory L = st.getLocks(user)[idx];
        assertEq(L.unlockAt, L.createdAt + 10 days);
    }

    function testFuzz_revealNeverWorseThanNonReveal(bytes32 h) public {
        vm.assume(h != bytes32(0));
        vm.prank(user);
        uint256 idx = st.stake(10e6);
        uint256 tb = block.number + 3;
        vm.roll(tb + 1);
        vm.setBlockhash(tb, h);
        vm.prank(attacker);
        st.reveal(user, idx);
        SaviorStakingFresh.LockView memory L = st.getLocks(user)[idx];
        assertLe(L.unlockAt, L.createdAt + 10 days);
        assertGe(L.unlockAt, L.createdAt + 5 days);
    }

    /// O-1 FIX: emergency unlock is no longer instant — 48h timelock, users see it coming.
    function test_fix_ownerEmergencyUnlockTimelocked() public {
        vm.prank(user);
        uint256 idx = st.stake(10e6);
        vm.prank(owner);
        vm.expectRevert(SaviorStakingFresh.NotScheduled.selector);
        st.executeEmergencyUnlock();
        vm.prank(owner);
        st.scheduleEmergencyUnlock();
        vm.prank(owner);
        vm.expectRevert(SaviorStakingFresh.TimelockActive.selector);
        st.executeEmergencyUnlock();
        vm.prank(user);
        vm.expectRevert(SaviorStakingFresh.Locked.selector);
        st.claim(idx); // still locked same block
    }

    /// O-2 FIX: dust stakeFor below MIN_STAKE_FOR reverts; paginated views bounded.
    function test_fix_stakeForSpam() public {
        vm.prank(attacker);
        vm.expectRevert(SaviorStakingFresh.BelowMinStake.selector);
        st.stakeFor(user, 1e6);
        // even at MIN_STAKE_FOR, 2000 locks cost 2000*100k SAVIOR; pages stay bounded
        vm.startPrank(attacker);
        for (uint256 i; i < 2000; i++) st.stakeFor(user, st.MIN_STAKE_FOR());
        vm.stopPrank();
        uint256 g = gasleft();
        SaviorStakingFresh.LockView[] memory page = st.getLocks(user, 1800, 1000);
        uint256 used1 = g - gasleft();
        g = gasleft();
        st.pendingRevealable(user, 0, 200);
        uint256 used2 = g - gasleft();
        assertEq(page.length, 200); // MAX_PAGE cap
        assertEq(st.lockCount(user), 2000);
        console2.log("getLocks page(200) gas:", used1);
        console2.log("pendingRevealable page(200) gas:", used2);
        assertLt(used1, 3_000_000);
        assertLt(used2, 3_000_000);
    }

    /// D-2 FIX: minOut == 0 rejected.
    function test_fix_zeroMinOutRejected() public {
        vm.expectRevert(SaviorStakingFresh.ZeroMinOut.selector);
        st.swapExactIn(true, 1e6, 0, block.timestamp);
    }

    /// B-3 FIX: token rescue works with non-bool tokens.
    function test_fix_rescueNonBoolToken() public {
        NoBoolToken nb = new NoBoolToken();
        nb.mint(address(token), 5);
        vm.prank(owner);
        token.rescue(address(nb), owner, 5);
        assertEq(nb.balanceOf(owner), 5);
    }

    /// B-2 (accepted): own token sent to the token contract stays stuck.
    function test_poc_ownTokenStuckInTokenContract() public {
        vm.prank(user);
        token.transfer(address(token), 5e6);
        vm.prank(owner);
        vm.expectRevert(SaviorTokenV2.CannotRescueOwnToken.selector);
        token.rescue(address(token), owner, 5e6);
    }
}
