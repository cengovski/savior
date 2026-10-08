// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ERC1967Proxy}   from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SaviorToken}    from "../contracts/SaviorToken.sol";
import {SaviorHook}     from "../contracts/SaviorHook.sol";
import {SaviorStaking}  from "../contracts/SaviorStaking.sol";
import {IPoolManager}   from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}        from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}       from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks}         from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract Deploy is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDC         = 0x3600000000000000000000000000000000000000;
    address constant TREASURY     = 0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787;

    uint24  constant POOL_FEE       = 10_000;
    int24   constant TICK_SPACING   = 200;
    uint160 constant SQRT_PRICE_X96 = 35_431_911_422_859_141_528_926_554_161_152;

    int24 constant B1L = 120_000; int24 constant B1U = 120_200;
    int24 constant B2L = 119_800; int24 constant B2U = 120_000;
    int24 constant B3L = 119_600; int24 constant B3U = 119_800;
    int24 constant B4L = 119_400; int24 constant B4U = 119_600;
    int24 constant B5L = 119_200; int24 constant B5U = 119_400;

    uint160 constant HOOK_FLAGS = 0xC3;

    function run() external {
        uint256 pk       = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        address token;
        address payable hook;
        address payable staking;

        // 1. Token
        {
            SaviorToken impl = new SaviorToken();
            token = address(new ERC1967Proxy(address(impl),
                abi.encodeWithSignature("initialize(address)", deployer)));
            console.log("TOKEN:", token);
        }

        // 2. Hook (CREATE2)
        {
            SaviorHook impl2 = new SaviorHook();
            bytes memory initData = abi.encodeWithSignature(
                "initialize(address,address,address,bool)",
                POOL_MANAGER, address(0), deployer, false);
            bytes memory proxyCode = abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(address(impl2), initData));
            bytes32 codeHash = keccak256(proxyCode);
            uint256 salt;
            address payable predicted;
            for (uint256 i = 0; i < 500_000; i++) {
                predicted = payable(address(uint160(uint256(keccak256(abi.encodePacked(
                    bytes1(0xff), CREATE2_FACTORY, bytes32(i), codeHash))))));
                if (uint160(address(predicted)) & 0x3FFF == HOOK_FLAGS) { salt = i; break; }
            }
            require(uint160(address(predicted)) & 0x3FFF == HOOK_FLAGS, "No salt");
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(bytes32(salt), proxyCode));
            require(ok, "CREATE2 failed");
            hook = predicted;
            console.log("HOOK:", hook);
        }

        // 3. Staking
        {
            SaviorStaking impl3 = new SaviorStaking();
            staking = payable(address(new ERC1967Proxy(address(impl3),
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,address)",
                    token, USDC, POOL_MANAGER, TREASURY, deployer))));
            console.log("STAKING:", staking);
        }

        // 4. Wire + pool init + approve
        SaviorHook(hook).setStakingContract(staking);
        SaviorToken(token).mint(deployer, 1_000_000_000 * 1e6);

        PoolKey memory pkey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(token),
            fee:       POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks:     IHooks(hook)
        });
        IPoolManager(POOL_MANAGER).initialize(pkey, SQRT_PRICE_X96);
        SaviorStaking(staking).setPoolKey(USDC, token, POOL_FEE, TICK_SPACING, address(hook));
        SaviorToken(token).approve(staking, type(uint256).max);

        // 5. Seed liquidity (5 bands)
        uint128 L = 1_000_000_000_000_000;
        SaviorStaking(staking).addLiquidity(B1L, B1U, L);
        SaviorStaking(staking).addLiquidity(B2L, B2U, L);
        SaviorStaking(staking).addLiquidity(B3L, B3U, L);
        SaviorStaking(staking).addLiquidity(B4L, B4U, L);
        SaviorStaking(staking).addLiquidity(B5L, B5U, L);

        vm.stopBroadcast();
        console.log("=== DEPLOY COMPLETE ===");
    }
}
