// config.js, public, non-secret configuration (mirrors deployments/arc-mainnet.json on add-contracts).
window.SAVIOR_CONFIG = {
  chainId: 5042,
  rpc: "https://rpc.mainnet.arc.io",
  explorer: "https://explorer.arc.io",
  contracts: {
    token:       "0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3", // SaviorToken (UUPS proxy), 6 decimals
    hook:        "0xFfcf2eF82AA17Fb31F3618E0302F9adC92D060c0",
    staking:     "0xBCA651C0A0540a1fCDef066B5476d714431fa525", // v1 (legacy)
    stakingV2:   "0x8807DA96A254B370e1E9ae8d3cc4163d1E2939bB", // SaviorStakingV2, deploy tx 0xea39975a...5fac4
    stakingV2DeployBlock: 25311674, // from the deploy tx receipt (skips the on-chain deploy block search)
    poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    usdc:        "0x3600000000000000000000000000000000000000",
    treasury:    "0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787",
  },
  // keccak256(abi.encode(PoolKey{USDC, SAVIOR, fee 10000, tickSpacing 200, hook}))
  poolId: "0x004d7e7f668a78ea18228d753008ccf0c2b6b9e7c6c03d7a44d7cd954d072ab6",
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

// Staking v2 switch. Active only for a valid, non-zero address; otherwise the site behaves exactly as with v1 only.
// Local testing only (localhost): ?v2=0x... overrides the address, e.g. against an anvil fork (see rpc.js ?rpc=).
(function (C) {
  let a = (C.contracts.stakingV2 || "").trim();
  const local = /^(localhost|127\.0\.0\.1)$/.test(location.hostname);
  const q = local && new URLSearchParams(location.search).get("v2");
  if (q) a = q.trim();
  C.v2 = /^0x[0-9a-fA-F]{40}$/.test(a) && !/^0x0{40}$/i.test(a) ? a : "";
  // v2 differences used by the site: minOut is checked against NET output (after the 0.3% treasury fee),
  // v1 checked the GROSS pool output. Fee (0.3%) and the 50/50 instant/locked split are unchanged.
  C.stakingSources = C.v2 ? [{ id: "v1", label: "Old", address: C.contracts.staking }, { id: "v2", label: "v2", address: C.v2 }]
                          : [{ id: "v1", label: "", address: C.contracts.staking }];
})(window.SAVIOR_CONFIG);
