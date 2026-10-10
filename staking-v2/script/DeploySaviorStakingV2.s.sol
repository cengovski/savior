// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SaviorStakingV2} from "../src/SaviorStakingV2.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";

/// NOT executed in this PR. Example (owner must review first):
///   OWNER=0x... forge script script/DeploySaviorStakingV2.s.sol --rpc-url arc_mainnet --account <keystore> --broadcast \
///     --verify --verifier blockscout --verifier-url https://explorer.arc.io/api/
contract DeploySaviorStakingV2 is Script {
    function run() external returns (SaviorStakingV2 st) {
        address owner = vm.envAddress("OWNER");
        require(block.chainid == A.CHAIN_ID, "not Arc mainnet");
        vm.startBroadcast();
        st = new SaviorStakingV2(owner, IERC20(A.SAVIOR_TOKEN));
        vm.stopBroadcast();
        console2.log("SaviorStakingV2", address(st));
    }
}
