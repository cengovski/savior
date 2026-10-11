// config.js, public, non-secret configuration for the SAVIOR site on Arc mainnet.
// Wiring verified on-chain: staking.key() = (USDC, token, 10000, 200, hook), hook.staking() = staking,
// staking.luckySink() = distributor, distributor.staking() = staking, distributor.nft() = nft.
window.SAVIOR_CONFIG = {
  chainId: 5042,
  rpc: "https://rpc.mainnet.arc.io",
  explorer: "https://explorer.arc.io",
  contracts: {
    token:       "0x4A939085A36B4faB5D222b196619C0CdBdd6A022", // SAVIOR token (6 decimals, 1B fixed supply)
    hook:        "0x813bdb7A1d4594B794ed9Df9Fad8A93f3873A080", // Uniswap V4 hook
    staking:     "0xFFaed084D0186FA96138d523f9292Fd4e47Dad63", // staking: swaps, locks, lock reveal
    distributor: "0x54713bd7f1B6c23eCe81A2F334E247789A569c5e", // Lucky NFT distributor (empty hides the Lucky NFT card)
    nft:         "0xf9cEdaA96278462f9b85ADfbB4ea0Bdfc38f383c", // Savior Weapons (OpenSea SeaDrop)
    deployer:    "0x5fC43F5078Ad4052E3B4A79aa0fC4BC5e5dF9b7c", // deployer of the stack above
    deployBlock: 25416100, // deploy tx receipt (start of the Staked event scan)
    poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    usdc:        "0x3600000000000000000000000000000000000000",
    treasury:    "0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787",
  },
  tokenDecimals: 6,
  usdcDecimals: 6, // ERC-20 interface of Arc USDC (native gas uses 18)
  // Buys >= this many USDC are highlighted. Override with ?bigbuy=NN
  bigBuyUsdc: Number(new URLSearchParams(location.search).get("bigbuy")) || 50,
  // Circle CCTP V2, Arc mainnet. Verified 2026-10-10 against
  // https://developers.circle.com/cctp/references/contract-addresses (Mainnet tables)
  // and the chain definition shipped in @circle-fin/bridge-kit@1.15.2. Bridge Kit uses these internally;
  // listed here for display/reference only.
  cctp: {
    domain: 26,
    tokenMessengerV2:     "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d",
    messageTransmitterV2: "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64",
    tokenMinterV2:        "0xfd78EE919681417d192449715b2594ab58f5D002",
    messageV2:            "0xec546b6B005471ECf012e5aF77FBeC07e0FD8f78",
  },
};

// Derived values. Local testing only (localhost): ?stack=token,hook,staking,distributor,deployBlock
// points the site at another deployment (e.g. an anvil fork, together with rpc.js ?rpc=).
(function (C) {
  const ok = (a) => /^0x[0-9a-fA-F]{40}$/.test(a || "") && !/^0x0{40}$/i.test(a);
  const local = /^(localhost|127\.0\.0\.1)$/.test(location.hostname);
  const q = local && new URLSearchParams(location.search).get("stack");
  if (q) { const [token, hook, staking, distributor, deployBlock] = q.split(","); Object.assign(C.contracts, { token, hook, staking, distributor, deployBlock: Number(deployBlock) || 0 }); }
  if (!ok(C.contracts.distributor)) C.contracts.distributor = "";
  // Pool ordering: currency0 is the lower address.
  C.saviorIsCurrency0 = BigInt(C.contracts.token) < BigInt(C.contracts.usdc);
  const [c0, c1] = C.saviorIsCurrency0 ? [C.contracts.token, C.contracts.usdc] : [C.contracts.usdc, C.contracts.token];
  // keccak256(abi.encode(PoolKey{currency0, currency1, fee 10000, tickSpacing 200, hook}))
  C.poolId = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"], [c0, c1, 10000, 200, C.contracts.hook]));
})(window.SAVIOR_CONFIG);
