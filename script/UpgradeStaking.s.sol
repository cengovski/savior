// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SaviorStaking} from "../contracts/SaviorStaking.sol";

contract UpgradeStaking is Script {
    function run() external {
        address proxy = vm.envAddress("STAKING_PROXY");
        uint256 pk    = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        SaviorStaking newImpl = new SaviorStaking();
        console.log("New impl:", address(newImpl));

        SaviorStaking(payable(proxy)).upgradeToAndCall(address(newImpl), "");
        console.log("Upgraded proxy:", proxy);

        vm.stopBroadcast();
    }
}
