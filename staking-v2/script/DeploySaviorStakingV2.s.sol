// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SaviorStakingV2} from "../src/SaviorStakingV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";

/// NOT executed in this PR. Owner = deployer 0x7185…20e7 (Ownable2Step).
/// Dry run (no broadcast):  forge script script/DeploySaviorStakingV2.s.sol --rpc-url arc_mainnet
/// Real deploy is meant to be signed by the deployer wallet via the admin panel wizard, or:
///   forge script ... --rpc-url arc_mainnet --account <keystore> --broadcast \
///     --verify --verifier blockscout --verifier-url https://explorer.arc.io/api/
contract DeploySaviorStakingV2 is Script {
    function run() external returns (SaviorStakingV2 st) {
        require(block.chainid == A.CHAIN_ID, "not Arc mainnet");
        vm.startBroadcast();
        st = new SaviorStakingV2(
            A.DEPLOYER,
            IERC20(A.SAVIOR_TOKEN),
            IPoolManagerMinimal(A.POOL_MANAGER),
            A.TREASURY,
            PoolKey(A.USDC, A.SAVIOR_TOKEN, A.POOL_FEE, A.POOL_TICK_SPACING, A.SAVIOR_HOOK)
        );
        vm.stopBroadcast();
        console2.log("SaviorStakingV2", address(st));
        console2.log("next: hook.setStakingContract(v2) from deployer, see script/WireHook.s.sol");
    }
}
