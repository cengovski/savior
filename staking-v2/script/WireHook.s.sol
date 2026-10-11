// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";

interface ISaviorHook {
    function owner() external view returns (address);
    function stakingContract() external view returns (address);
    function setStakingContract(address) external;
}

/// Prints and simulates (eth_call, from = hook owner) the hook re-wiring call. Does NOT broadcast.
///   STAKING_V2=0x... forge script script/WireHook.s.sol --rpc-url arc_mainnet
/// The hook proxy (UUPS) already exposes setStakingContract(address) 0x9dd373b9 (onlyOwner = deployer),
/// so no new hook implementation is needed.
contract WireHook is Script {
    function run() external {
        address v2 = vm.envAddress("STAKING_V2");
        ISaviorHook hook = ISaviorHook(A.SAVIOR_HOOK);
        console2.log("hook owner", hook.owner());
        console2.log("current stakingContract", hook.stakingContract());
        bytes memory data = abi.encodeCall(ISaviorHook.setStakingContract, (v2));
        console2.log("to", A.SAVIOR_HOOK);
        console2.logBytes(data);
        vm.prank(hook.owner());
        (bool ok,) = A.SAVIOR_HOOK.call(data);
        require(ok, "simulation failed");
        console2.log("simulated stakingContract", hook.stakingContract());
    }
}
