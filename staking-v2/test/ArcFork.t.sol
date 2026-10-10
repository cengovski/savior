// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SaviorStakingV2} from "../src/SaviorStakingV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";
import {ArcPrecompiles} from "./utils/ArcPrecompiles.sol";

interface IStakingV1 {
    function globalUnlock() external view returns (bool);
    function keySet() external view returns (bool);
    function owner() external view returns (address);
    function emergencyUnlockAll() external;
    function swapExactIn(bool, uint256, uint256) external;
    function claim(uint256) external;
}

interface ISaviorHook {
    function owner() external view returns (address);
    function stakingContract() external view returns (address);
    function setStakingContract(address) external;
    function poolManager() external view returns (address);
}

/// End-to-end tests on a LOCAL fork of Arc Mainnet. Nothing is broadcast; pranks only exist in the fork.
/// Run: ARC_FORK=true forge test --match-contract ArcFork -vv
/// Arc native-USDC precompiles are mocked locally (see test/utils/ArcPrecompiles.sol).
contract ArcForkTest is Test {
    bool forked;
    SaviorStakingV2 st;
    IERC20 usdc = IERC20(A.USDC);
    IERC20 sav = IERC20(A.SAVIOR_TOKEN);
    ISaviorHook hook = ISaviorHook(A.SAVIOR_HOOK);
    address user = makeAddr("user");
    address user2 = makeAddr("user2");

    function setUp() public {
        if (!vm.envOr("ARC_FORK", false)) return;
        vm.createSelectFork("arc_mainnet");
        ArcPrecompiles.install(vm);
        forked = true;
        st = new SaviorStakingV2(
            A.DEPLOYER,
            sav,
            IPoolManagerMinimal(A.POOL_MANAGER),
            A.TREASURY,
            PoolKey(A.USDC, A.SAVIOR_TOKEN, A.POOL_FEE, A.POOL_TICK_SPACING, A.SAVIOR_HOOK)
        );
        vm.deal(user, 1_000 ether); // 1000 USDC native (18 dec) == 1000e6 via ERC-20 view
        vm.deal(user2, 1_000 ether);
        vm.prank(user);
        usdc.approve(address(st), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(st), type(uint256).max);
    }

    function _wireHook() internal {
        vm.prank(A.DEPLOYER);
        hook.setStakingContract(address(st));
        assertEq(hook.stakingContract(), address(st));
    }

    function _buy(address who, uint256 usdcIn) internal returns (uint256 net) {
        vm.prank(who);
        net = st.swapExactIn(true, usdcIn, 0);
    }

    // ------------------------------------------------------------- on-chain facts

    function test_fork_chainAndCode() public view {
        if (!forked) return;
        assertEq(block.chainid, A.CHAIN_ID);
        assertGt(A.STAKING_V1.code.length, 0);
        assertGt(A.POOL_MANAGER.code.length, 0);
        assertGt(A.POSITION_MANAGER.code.length, 0);
        assertGt(A.UNIVERSAL_ROUTER.code.length, 0);
        assertGt(A.PERMIT2.code.length, 0);
        assertEq(IERC20Metadata(A.SAVIOR_TOKEN).decimals(), 6);
    }

    function test_fork_hookState() public view {
        if (!forked) return;
        assertEq(hook.owner(), A.DEPLOYER);
        assertEq(hook.stakingContract(), A.STAKING_V1);
        assertEq(hook.poolManager(), A.POOL_MANAGER);
        // ERC-1967 implementation slot
        bytes32 impl = vm.load(A.SAVIOR_HOOK, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(address(uint160(uint256(impl))), 0xaee9227Ff2C17Ec2e72Ab2e23091c85ae38c2Bd9);
        // plain storage: slot0 = poolManager, slot1 = stakingContract
        assertEq(address(uint160(uint256(vm.load(A.SAVIOR_HOOK, bytes32(uint256(1)))))), A.STAKING_V1);
    }

    function test_fork_v1State() public view {
        if (!forked) return;
        IStakingV1 v1 = IStakingV1(A.STAKING_V1);
        assertEq(v1.owner(), address(0));
        assertFalse(v1.globalUnlock());
    }

    function test_fork_v1EmergencyUnlockGatedByDeployer() public {
        if (!forked) return;
        IStakingV1 v1 = IStakingV1(A.STAKING_V1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes4(0x30cd7471)); // NotOwner()
        v1.emergencyUnlockAll();
        vm.prank(A.DEPLOYER);
        v1.emergencyUnlockAll();
        assertTrue(v1.globalUnlock());
    }

    // ------------------------------------------------------------- hook wiring

    function test_fork_setStakingContractOnlyHookOwner() public {
        if (!forked) return;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        hook.setStakingContract(address(st));
    }

    function test_fork_hookGatesSwapsToStakingContract() public {
        if (!forked) return;
        // hook.beforeSwap reverts OnlyStaking() (0x3d704762, wrapped by v4 WrappedError) unless sender == stakingContract
        vm.prank(user);
        vm.expectRevert();
        st.swapExactIn(true, 10e6, 0);
        _wireHook();
        _buy(user, 10e6);
        // after re-wiring, v1 can no longer swap (claims still work)
        vm.startPrank(user2);
        usdc.approve(A.STAKING_V1, type(uint256).max);
        vm.expectRevert();
        IStakingV1(A.STAKING_V1).swapExactIn(true, 10e6, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- end-to-end

    function test_fork_e2e_buyLockClaimSell() public {
        if (!forked) return;
        _wireHook();
        uint256 treBefore = sav.balanceOf(A.TREASURY);
        uint256 usdcBefore = usdc.balanceOf(user);

        uint256 net = _buy(user, 10e6);
        assertEq(usdcBefore - usdc.balanceOf(user), 10e6);
        uint256 locked = net / 2;
        assertEq(sav.balanceOf(user), net - locked, "50% to buyer");
        SaviorStakingV2.Lock[] memory ls = st.getLocks(user);
        assertEq(ls.length, 1);
        assertEq(ls[0].amount, locked, "50% locked");
        assertGe(ls[0].unlockAt, block.timestamp + 5 days);
        assertLe(ls[0].unlockAt, block.timestamp + 10 days);
        assertEq(st.totalLocked(), locked);
        uint256 fee = sav.balanceOf(A.TREASURY) - treBefore;
        assertApproxEqAbs(fee, (net + fee) * 30 / 10_000, 1, "0.3% treasury fee");
        assertEq(st.lastBuyBlock(user), block.number);
        console2.log("buy 10 USDC -> net SAVIOR", net, "locked", locked);

        // same-block sell blocked
        vm.startPrank(user);
        sav.approve(address(st), type(uint256).max);
        vm.expectRevert(SaviorStakingV2.SameBlock.selector);
        st.swapExactIn(false, 1e6, 0);

        // lock enforced
        vm.expectRevert(SaviorStakingV2.Locked.selector);
        st.claim(0);

        // claim after lock
        vm.warp(ls[0].unlockAt - 1);
        vm.expectRevert(SaviorStakingV2.Locked.selector);
        st.claim(0);
        vm.warp(ls[0].unlockAt);
        st.claim(0);
        assertEq(sav.balanceOf(user), net);
        assertEq(st.totalLocked(), 0);

        // sell everything
        vm.roll(block.number + 1);
        uint256 u0 = usdc.balanceOf(user);
        uint256 out = st.swapExactIn(false, net, 0);
        vm.stopPrank();
        assertEq(usdc.balanceOf(user) - u0, out);
        assertEq(sav.balanceOf(user), 0);
        assertGt(out, 9e6, "round trip loses < 10% (pool fee 1% x2 + 0.3% x2 + impact)");
        console2.log("sell back -> USDC", out);
        assertEq(usdc.balanceOf(address(st)), 0, "no USDC stuck");
        assertEq(sav.balanceOf(address(st)), st.totalLocked(), "no SAVIOR surplus");
    }

    function test_fork_e2e_slippage() public {
        if (!forked) return;
        _wireHook();
        vm.prank(user);
        vm.expectRevert(SaviorStakingV2.Bad.selector);
        st.swapExactIn(true, 10e6, type(uint256).max);
    }

    function test_fork_e2e_matchesV1() public {
        if (!forked) return;
        // v1 buy on the untouched fork state
        uint256 snap = vm.snapshotState();
        vm.startPrank(user);
        usdc.approve(A.STAKING_V1, type(uint256).max);
        IStakingV1(A.STAKING_V1).swapExactIn(true, 10e6, 0);
        vm.stopPrank();
        uint256 v1Got = sav.balanceOf(user);
        (bool ok, bytes memory ret) = A.STAKING_V1.staticcall(abi.encodeWithSignature("getLocks(address)", user));
        require(ok);
        SaviorStakingV2.Lock[] memory v1Locks = abi.decode(ret, (SaviorStakingV2.Lock[]));
        vm.revertToState(snap);
        _wireHook();
        uint256 net = _buy(user, 10e6);
        assertEq(net - net / 2, v1Got, "v2 buyer share == v1 buyer share");
        SaviorStakingV2.Lock[] memory v2Locks = st.getLocks(user);
        assertEq(v2Locks[0].amount, v1Locks[0].amount, "same locked amount");
        assertEq(v2Locks[0].unlockAt, v1Locks[0].unlockAt, "same pseudo-random unlockAt as v1");
    }

    function test_fork_e2e_emergencyUnlockAll() public {
        if (!forked) return;
        _wireHook();
        _buy(user, 10e6);
        _buy(user2, 20e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        st.emergencyUnlockAll();
        vm.prank(A.DEPLOYER);
        st.emergencyUnlockAll();
        assertTrue(st.globalUnlock());
        uint256 l1 = st.getLocks(user)[0].amount;
        uint256 b1 = sav.balanceOf(user);
        vm.prank(user);
        st.claim(0);
        assertEq(sav.balanceOf(user) - b1, l1);
        vm.prank(user2);
        st.claim(0);
        assertEq(st.totalLocked(), 0);
    }

    function test_fork_e2e_rescueCannotTouchLocked() public {
        if (!forked) return;
        _wireHook();
        _buy(user, 50e6);
        uint256 locked = st.totalLocked();
        assertGt(locked, 0);
        vm.startPrank(A.DEPLOYER);
        vm.expectRevert(SaviorStakingV2.ExceedsSurplus.selector);
        st.rescue(A.SAVIOR_TOKEN, 1);
        vm.stopPrank();
        // accidental USDC sent to contract can be rescued
        vm.prank(user);
        usdc.transfer(address(st), 1e6);
        uint256 d0 = usdc.balanceOf(A.DEPLOYER);
        vm.prank(A.DEPLOYER);
        st.rescue(A.USDC, 1e6);
        assertEq(usdc.balanceOf(A.DEPLOYER) - d0, 1e6);
        assertEq(sav.balanceOf(address(st)), locked);
    }

    function test_fork_migration_claimOldStakeNew() public {
        if (!forked) return;
        // user has a v1 lock, deployer unlocks v1, user claims and restakes into v2
        vm.startPrank(user);
        usdc.approve(A.STAKING_V1, type(uint256).max);
        IStakingV1(A.STAKING_V1).swapExactIn(true, 10e6, 0);
        vm.stopPrank();
        vm.prank(A.DEPLOYER);
        IStakingV1(A.STAKING_V1).emergencyUnlockAll();
        uint256 b0 = sav.balanceOf(user);
        vm.prank(user);
        IStakingV1(A.STAKING_V1).claim(0);
        uint256 claimed = sav.balanceOf(user) - b0;
        assertGt(claimed, 0);
        _wireHook();
        vm.startPrank(user);
        sav.approve(address(st), claimed);
        st.stake(claimed);
        vm.stopPrank();
        assertEq(st.getLocks(user)[0].amount, claimed);
    }
}
