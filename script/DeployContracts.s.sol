// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ERC1967Proxy}  from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SaviorToken}   from "../contracts/SaviorToken.sol";
import {SaviorHook}    from "../contracts/SaviorHook.sol";
import {SaviorStaking} from "../contracts/SaviorStaking.sol";

/// @notice Quick deploy: Token + Hook + Staking (no pool init).
///         Use admin.html to initialize pool and add liquidity after deploy.
contract DeployContracts is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TREASURY     = 0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787;
    address constant USDC         = 0x3600000000000000000000000000000000000000;
    // CREATE2_FACTORY inherited from forge-std/Base.sol

    // Hook flags: beforeInitialize(0)+afterInitialize(1)+beforeSwap(6)+afterSwap(7) = 0xC3
    uint160 constant HOOK_FLAGS = 0xC3;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1. SaviorToken
        SaviorToken tokenImpl = new SaviorToken();
        address token = address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(SaviorToken.initialize, (deployer))
        ));
        console.log("TOKEN:", token);

        // 2. SaviorHook impl + CREATE2 proxy
        SaviorHook hookImpl = new SaviorHook();
        console.log("HOOK_IMPL:", address(hookImpl));

        bytes memory hookInit = abi.encodeWithSignature(
            "initialize(address,address,address,bool)",
            POOL_MANAGER, address(0), deployer, false
        );
        bytes memory proxyCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(address(hookImpl), hookInit)
        );
        bytes32 codeHash = keccak256(proxyCode);

        uint256 salt;
        address hook;
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(i), codeHash)
            ))));
            if (uint160(predicted) & 0x3FFF == HOOK_FLAGS) {
                salt = i; hook = predicted; break;
            }
        }
        require(hook != address(0), "No salt found for hook flags");
        console.log("HOOK_SALT:", salt);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(bytes32(salt), proxyCode));
        require(ok, "CREATE2 hook deploy failed");
        console.log("HOOK:", hook);

        // 3. SaviorStaking
        SaviorStaking stakingImpl = new SaviorStaking();
        address staking = address(new ERC1967Proxy(
            address(stakingImpl),
            abi.encodeWithSignature(
                "initialize(address,address,address,address,address)",
                token, USDC, POOL_MANAGER, TREASURY, deployer
            )
        ));
        console.log("STAKING:", staking);

        // 4. Wire hook → staking
        SaviorHook(payable(hook)).setStakingContract(staking);
        console.log("HOOK_WIRED");

        // 5. Mint 1B SAVIOR (6 dec)
        SaviorToken(token).mint(deployer, 1_000_000_000 * 1e6);
        console.log("MINTED 1B SAVIOR");

        vm.stopBroadcast();
        console.log("=== DONE ===");
    }
}
