// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Brute-force a CREATE2 salt so the hook address has exactly `flags` in its low 14 bits.
///         Expected ~16384 tries (1 / 2^14). Pure; usable from scripts/tests (and eth_call).
library HookMiner {
    uint160 internal constant MASK = uint160((1 << 14) - 1);

    function find(address deployer, uint160 flags, bytes32 initCodeHash, uint256 start, uint256 maxLoop)
        internal
        pure
        returns (bytes32 salt, address hookAddr)
    {
        for (uint256 i = start; i < start + maxLoop; ++i) {
            salt = bytes32(i);
            hookAddr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(hookAddr) & MASK == flags) return (salt, hookAddr);
        }
        revert("HookMiner: not found");
    }
}
