// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
/// @notice PoC: D20DAO VRF fee is native USDC (msg.value, 18-dec). Callback simulated via prank.
///         ARC_FORK=true forge test --match-contract D20VrfFeePoC -vv
import {Test, console2} from "forge-std/Test.sol";

interface ID20 {
    function quoteFee(uint32) external view returns (uint256);
    function quoteFeeAt(uint32, uint256) external view returns (uint256);
    function requestRandomness(bytes32, uint32, address) external payable returns (uint256);
    function pricing() external view returns (uint256 minFee, uint256 feeMultiplier, uint256 fulfillGasOverhead);
    function refundBps() external view returns (uint16);
    function rawFulfillRandomness(uint256, bytes32) external; // only on consumer; coordinator calls consumer
}

contract MiniConsumer {
    address public immutable coordinator;
    uint256 public lastId;
    bytes32 public lastWord;
    bool public fulfilled;
    constructor(address c) { coordinator = c; }
    function request(uint32 gasLimit, address refundTo) external payable returns (uint256 id) {
        id = ID20(coordinator).requestRandomness{value: msg.value}(keccak256("seed"), gasLimit, refundTo);
        lastId = id;
    }
    function rawFulfillRandomness(uint256 requestId, bytes32 randomness) external {
        require(msg.sender == coordinator, "only coord");
        lastId = requestId;
        lastWord = randomness;
        fulfilled = true;
    }
}

contract D20VrfFeePoC is Test {
    address constant C = 0xd20da057469C45928912d983F45790C41e290571;
    uint32 constant CB_GAS = 100_000;

    function test_fork_quote_and_request_native() public {
        vm.skip(!vm.envOr("ARC_FORK", false));
        vm.createSelectFork("arc_mainnet");

        (uint256 minFee, uint256 mult, uint256 overhead) = ID20(C).pricing();
        console2.log("pricing minFee", minFee);
        console2.log("pricing mult", mult);
        console2.log("pricing overhead", overhead);
        console2.log("refundBps", ID20(C).refundBps());

        uint256 at20 = ID20(C).quoteFeeAt(CB_GAS, 20 gwei);
        console2.log("quoteFeeAt(100k,20gwei)", at20);

        MiniConsumer cons = new MiniConsumer(C);
        // fund consumer with native USDC (18-dec) for the fee
        vm.deal(address(cons), at20);

        uint256 id = cons.request{value: at20}(CB_GAS, address(cons));
        console2.log("requestId", id);
        assertGt(id, 0);
        assertFalse(cons.fulfilled());

        // On a fork the keeper never delivers. Simulate coordinator callback.
        vm.prank(C);
        cons.rawFulfillRandomness(id, bytes32(uint256(0xC0FFEE)));
        assertTrue(cons.fulfilled());
        assertEq(uint256(cons.lastWord()), 0xC0FFEE);

        // Cost model at 20 gwei
        uint256 feeUsdc18 = at20;
        uint256 reqGasEst = 200_000; // rough request overhead beyond fee
        uint256 cbGasEst = 100_000;
        uint256 gasUsdc18 = (reqGasEst + cbGasEst) * 20 gwei;
        console2.log("fee USDC_18", feeUsdc18);
        console2.log("est gas USDC_18 (req+cb @20gwei)", gasUsdc18);
        console2.log("est total USDC_18", feeUsdc18 + gasUsdc18);
    }
}
