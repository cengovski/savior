// chains.js, source chains for the USDC bridge to Arc.
// Every EVM mainnet that Circle Bridge Kit (vendor/bridge-kit.esm.js, @circle-fin/bridge-kit@1.15.2) supports
// with CCTP V2, excluding Arc itself (the destination). `key` is the Bridge Kit chain identifier passed to
// kit.bridge(); `id` is the EVM chain id used for wallet switching and for the Reown AppKit network list.
// Regenerate from BridgeKit#getSupportedChains() when the vendored Bridge Kit is upgraded.
(function () {
  const ARC = {
    key: "Arc", name: "Arc Mainnet", id: 5042, domain: 26,
    native: { name: "USDC", symbol: "USDC", decimals: 18 },
    rpc: ["https://rpc.mainnet.arc.io"], explorer: "https://explorer.arc.io", logo: "arc-icon.svg",
  };
  const SOURCES = [
    {"key":"Ethereum","name":"Ethereum","id":1,"domain":0,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://ethereum-rpc.publicnode.com","https://ethereum.publicnode.com"],"explorer":"https://etherscan.io","logo":"ethereum.svg"},
    {"key":"Base","name":"Base","id":8453,"domain":6,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://mainnet.base.org","https://base.publicnode.com"],"explorer":"https://basescan.org","logo":"base.svg"},
    {"key":"Arbitrum","name":"Arbitrum","id":42161,"domain":3,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://arb1.arbitrum.io/rpc"],"explorer":"https://arbiscan.io","logo":"arbitrum.svg"},
    {"key":"Optimism","name":"OP Mainnet","id":10,"domain":2,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://mainnet.optimism.io"],"explorer":"https://optimistic.etherscan.io","logo":"op-mainnet.svg"},
    {"key":"Polygon","name":"Polygon PoS","id":137,"domain":7,"native":{"name":"POL","symbol":"POL","decimals":18},"rpc":["https://polygon.publicnode.com","https://polygon.drpc.org"],"explorer":"https://polygonscan.com","logo":"polygon.svg"},
    {"key":"Avalanche","name":"Avalanche","id":43114,"domain":1,"native":{"name":"Avalanche","symbol":"AVAX","decimals":18},"rpc":["https://api.avax.network/ext/bc/C/rpc"],"explorer":"https://subnets.avax.network/c-chain","logo":"avalanche.svg"},
    {"key":"Linea","name":"Linea","id":59144,"domain":11,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://rpc.linea.build"],"explorer":"https://lineascan.build","logo":"linea.svg"},
    {"key":"Unichain","name":"Unichain","id":130,"domain":10,"native":{"name":"Uni","symbol":"UNI","decimals":18},"rpc":["https://mainnet.unichain.org"],"explorer":"https://unichain.blockscout.com","logo":"unichain.svg"},
    {"key":"Codex","name":"Codex","id":81224,"domain":12,"native":{"name":"ETH","symbol":"ETH","decimals":18},"rpc":["https://rpc.codex.xyz"],"explorer":"https://explorer.codex.xyz","color":"#1F2937"},
    {"key":"Cronos","name":"Cronos","id":25,"domain":32,"native":{"name":"Cronos","symbol":"CRO","decimals":18},"rpc":["https://evm.cronos.org"],"explorer":"https://cronoscan.com","color":"#002D74"},
    {"key":"Edge","name":"Edge","id":3343,"domain":28,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://edge-mainnet.g.alchemy.com/public"],"explorer":"https://pro.edgex.exchange/en-US/explorer","color":"#0E7C66"},
    {"key":"HyperEVM","name":"HyperEVM","id":999,"domain":19,"native":{"name":"Hype","symbol":"HYPE","decimals":18},"rpc":["https://rpc.hyperliquid.xyz/evm"],"explorer":"https://hyperevmscan.io","color":"#0F3D3E"},
    {"key":"Injective","name":"Injective","id":1776,"domain":29,"native":{"name":"Injective","symbol":"INJ","decimals":18},"rpc":["https://sentry.evm-rpc.injective.network"],"explorer":"https://injscan.com","color":"#0082FA"},
    {"key":"Ink","name":"Ink","id":57073,"domain":21,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://rpc-gel.inkonchain.com","https://rpc-qnd.inkonchain.com"],"explorer":"https://explorer.inkonchain.com","color":"#7132F5"},
    {"key":"Monad","name":"Monad","id":143,"domain":15,"native":{"name":"Monad","symbol":"MON","decimals":18},"rpc":["https://rpc.monad.xyz"],"explorer":"https://monadscan.com","color":"#6E54FF"},
    {"key":"Morph","name":"Morph","id":2818,"domain":30,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://rpc.morphl2.io"],"explorer":"https://explorer.morph.network","color":"#14A800"},
    {"key":"Pharos","name":"Pharos","id":1672,"domain":31,"native":{"name":"Pharos","symbol":"PHAROS","decimals":18},"rpc":["https://rpc.pharos.xyz"],"explorer":"https://pharos.socialscan.io","color":"#1B3BFF"},
    {"key":"Plasma","name":"Plasma","id":9745,"domain":33,"native":{"name":"Plasma","symbol":"XPL","decimals":18},"rpc":["https://rpc.plasma.to"],"explorer":"https://plasmascan.to","color":"#162F29"},
    {"key":"Plume","name":"Plume","id":98866,"domain":22,"native":{"name":"Plume","symbol":"PLUME","decimals":18},"rpc":["https://rpc.plume.org"],"explorer":"https://explorer.plume.org","color":"#E2463C"},
    {"key":"Sei","name":"Sei","id":1329,"domain":16,"native":{"name":"Sei","symbol":"SEI","decimals":18},"rpc":["https://evm-rpc.sei-apis.com"],"explorer":"https://seiscan.io","color":"#9E1F19"},
    {"key":"Sonic","name":"Sonic","id":146,"domain":13,"native":{"name":"Sonic","symbol":"S","decimals":18},"rpc":["https://rpc.soniclabs.com"],"explorer":"https://sonicscan.org","color":"#0A2540"},
    {"key":"World_Chain","name":"World Chain","id":480,"domain":14,"native":{"name":"Ether","symbol":"ETH","decimals":18},"rpc":["https://worldchain-mainnet.g.alchemy.com/public"],"explorer":"https://worldscan.org","color":"#111111"},
    {"key":"X_Layer","name":"X Layer","id":196,"domain":37,"native":{"name":"OKB","symbol":"OKB","decimals":18},"rpc":["https://xlayerrpc.okx.com"],"explorer":"https://www.oklink.com/xlayer","color":"#000000"},
    {"key":"XDC","name":"XDC","id":50,"domain":18,"native":{"name":"XDC","symbol":"XDC","decimals":18},"rpc":["https://erpc.xdcrpc.com","https://erpc.xinfin.network"],"explorer":"https://xdcscan.io","color":"#2A4BFF"}
  ];
  window.SAVIOR_ARC_CHAIN = ARC;
  window.SAVIOR_BRIDGE_CHAINS = SOURCES;
  window.SAVIOR_DEFAULT_BRIDGE_CHAIN = "Base";
  // EIP-3085 params for wallet_addEthereumChain.
  window.saviorAddChainParams = function (c) {
    return { chainId: "0x" + c.id.toString(16), chainName: c.name, nativeCurrency: c.native, rpcUrls: c.rpc.slice(0, 1), blockExplorerUrls: [c.explorer] };
  };
  window.saviorChainById = function (id) { id = Number(id); return id === ARC.id ? ARC : SOURCES.find((c) => c.id === id) || null; };
  window.saviorChainByKey = function (k) { return k === ARC.key ? ARC : SOURCES.find((c) => c.key === k) || null; };
})();
