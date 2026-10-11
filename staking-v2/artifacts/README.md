`SaviorStakingV2.json`: ABI, creation bytecode, runtime (`deployedBytecode`, immutables zeroed) and
`immutableReferences` (immutable name -> byte offsets, 32-byte words) so a deployed instance can be checked:
fill each offset with the expected immutable value (address/uint left-padded, int24 sign-extended, bool 0/1),
then `keccak256(runtime) == extcodehash(deployed)`. The admin wizard (feature/phase1) does exactly this before
`setStakingContract`. Regenerate with `forge build --force --ast` + the jq command in the PR description.
