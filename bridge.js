// bridge.js, USDC to Arc with Circle CCTP V2, called directly (no SDK, no backend, no API key).
// Every wallet request is a plain eth_sendTransaction with explicit from/to/data/chainId/gas:
//   1. source chain: USDC approve(TokenMessengerV2, exact amount)   (skipped if the allowance already covers it)
//   2. source chain: TokenMessengerV2.depositForBurn(amount, 26, recipient, USDC, 0x0, maxFee, finality)
//   3. Circle Iris API (public): wait for the attestation of the burn
//   4. Arc:          MessageTransmitterV2.receiveMessage(message, attestation)  (mints USDC to the recipient)
// No eth_sign, personal_sign, eth_signTypedData or eth_signTransaction is ever requested, and no unlimited approval.
// Contract addresses come from chains.js (Circle CCTP V2 deployments, as listed by Circle Bridge Kit 1.15.2).
const IRIS = "https://iris-api.circle.com";
const ARC_DOMAIN = 26;
const PENDING_KEY = "savior.bridge.pending";
const ERC20 = new ethers.Interface([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
]);
const TM = new ethers.Interface([
  "function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken, bytes32 destinationCaller, uint256 maxFee, uint32 minFinalityThreshold)",
]);
const MT = new ethers.Interface([
  "function receiveMessage(bytes message, bytes attestation) returns (bool)",
  "function usedNonces(bytes32 nonce) view returns (uint256)",
]);
const ZERO32 = "0x" + "0".repeat(64);
const hex = (n) => "0x" + BigInt(n).toString(16);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arc = () => window.SAVIOR_ARC_CHAIN;
// Use the wallet the user connected (injected or WalletConnect); fall back to an injected wallet.
const getWallet = () => (window.WalletConnector && window.WalletConnector.rawProvider) || window.ethereum || null;
const $ = (id) => document.getElementById(id);

// ---------- log + steps ----------
function log(msg, cls = "") {
  const box = $("bridge-log"); if (!box) return;
  const d = document.createElement("div"); d.className = cls; d.textContent = msg; box.appendChild(d); box.scrollTop = box.scrollHeight;
}
function logLink(msg, url, cls = "ok") {
  const box = $("bridge-log"); if (!box) return;
  const d = document.createElement("div"); d.className = cls; d.append(msg + " ");
  if (url) { const a = document.createElement("a"); a.href = url; a.target = "_blank"; a.rel = "noopener"; a.textContent = "view"; d.appendChild(a); }
  box.appendChild(d); box.scrollTop = box.scrollHeight;
}
const ORDER = ["approve", "burn", "attest", "mint"];
let cur = null; // step in progress, used to mark the failed step
function step(active, done, failed) { if (active) cur = active; if (window.setBridgeStep) window.setBridgeStep(active, done, failed); }
const txUrl = (chain, hash) => chain.explorer + "/tx/" + hash;

// The wallet's own error text (OKX, Rabby, MetaMask and WalletConnect wallets put it in different places).
function walletError(e) {
  const code = e?.code ?? e?.error?.code ?? e?.info?.error?.code;
  const msg = e?.data?.message || e?.error?.message || e?.info?.error?.message || e?.shortMessage || e?.reason || e?.message || String(e);
  if (code === 4001 || code === "ACTION_REJECTED" || /user rejected|user denied|rejected the request|request rejected|cancel/i.test(msg)) return "Rejected in the wallet: " + msg;
  return msg + (code != null && !String(msg).includes(String(code)) ? ` (code ${code})` : "");
}

// ---------- reads (public RPCs of the chain, then the wallet) ----------
const providers = {};
function rpcProviders(chain) {
  if (chain.id === arc().id && window.SaviorRPC) return [window.SaviorRPC.provider()];
  return (providers[chain.id] = providers[chain.id] || chain.rpc.map((u) => new ethers.JsonRpcProvider(u, chain.id, { staticNetwork: true })));
}
async function read(chain, fn) {
  let last;
  for (const p of rpcProviders(chain)) { try { return await fn(p); } catch (e) { last = e; } }
  const w = getWallet();
  if (w && Number(await w.request({ method: "eth_chainId" }).catch(() => 0)) === chain.id) return fn(new ethers.BrowserProvider(w, "any"));
  throw last || new Error("No RPC available for " + chain.name);
}
const call = (chain, to, data) => read(chain, (p) => p.call({ to, data }));

// ---------- wallet ----------
async function account() {
  const wc = window.WalletConnector;
  if (wc && wc.address) return wc.address;
  const w = getWallet(); if (!w) return null;
  const a = await w.request({ method: "eth_accounts" }).catch(() => []);
  return (a && a[0]) || null;
}
// Move the wallet to `chain`. Uses the shared connector (AppKit switchNetwork with wallet_switchEthereumChain /
// wallet_addEthereumChain fallback) when a wallet is connected through it, otherwise talks to the injected wallet.
async function switchWalletTo(chain) {
  const wc = window.WalletConnector;
  if (wc && wc.address && wc.switchChain) return wc.switchChain(chain.id);
  const eth = getWallet(); if (!eth) throw new Error("Connect a wallet first.");
  const h = hex(chain.id);
  if (Number(await eth.request({ method: "eth_chainId" })) === chain.id) return true;
  try { await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: h }] }); }
  catch (e) {
    if (e && (e.code === 4902 || /unrecognized|not added|unknown chain/i.test(e.message || ""))) {
      await eth.request({ method: "wallet_addEthereumChain", params: [window.saviorAddChainParams(chain)] });
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: h }] }).catch(() => {});
    } else throw e;
  }
  return true;
}
async function ensureOn(chain) {
  const eth = getWallet();
  if (Number(await eth.request({ method: "eth_chainId" })) !== chain.id) await switchWalletTo(chain);
  const now = Number(await eth.request({ method: "eth_chainId" }));
  if (now !== chain.id) throw new Error(`Your wallet is on another network. Switch it to ${chain.name} and try again.`);
}
// A standard transaction: eth_sendTransaction with explicit chainId, from, to, data, value 0 and a gas limit.
async function sendTx(chain, to, data, what) {
  const eth = getWallet(), from = await account();
  if (!eth || !from) throw new Error("Connect a wallet first.");
  await ensureOn(chain);
  let gas;
  try { gas = await read(chain, (p) => p.estimateGas({ from, to, data, value: 0n })); }
  catch (e) {
    try { gas = BigInt(await eth.request({ method: "eth_estimateGas", params: [{ from, to, data, value: "0x0" }] })); }
    catch (e2) { throw new Error(`${what} would fail: ${walletError(e2.shortMessage ? e2 : e)}`); }
  }
  const tx = { from, to, data, value: "0x0", chainId: hex(chain.id), gas: hex((BigInt(gas) * 13n) / 10n + 10000n) };
  log(`${what}: confirm in your wallet (${chain.name})...`, "muted");
  return eth.request({ method: "eth_sendTransaction", params: [tx] });
}
async function waitReceipt(chain, hash, what) {
  const eth = getWallet();
  for (let i = 0; i < 900; i++) {
    let rc = null;
    try { rc = await read(chain, (p) => p.getTransactionReceipt(hash)); } catch (e) {}
    if (!rc && eth) { try { const r = await eth.request({ method: "eth_getTransactionReceipt", params: [hash] }); if (r) rc = { status: Number(r.status) }; } catch (e) {} }
    if (rc) { if (Number(rc.status) !== 1) throw new Error(`${what} failed on ${chain.name} (transaction reverted).`); return rc; }
    await sleep(2000);
  }
  throw new Error(`${what} not confirmed yet. Check it in the explorer, then press Retry last transfer.`);
}

// ---------- Circle Iris API ----------
async function fastFee(srcDomain, speed) {
  const r = await fetch(`${IRIS}/v2/burn/USDC/fees/${srcDomain}/${ARC_DOMAIN}`);
  if (!r.ok) throw new Error("Could not load the CCTP fee (HTTP " + r.status + ").");
  const list = await r.json();
  const want = speed === "FAST" ? 1000 : 2000;
  const f = (Array.isArray(list) ? list : []).find((x) => Number(x.finalityThreshold) === want);
  if (!f) throw new Error(speed === "FAST" ? "Fast transfer is not available from this chain right now. Choose Standard." : "Standard transfer fee not available.");
  return { finality: want, bps: Number(f.minimumFee) || 0 };
}
async function waitAttestation(srcDomain, burnHash) {
  for (let i = 0; ; i++) {
    try {
      const r = await fetch(`${IRIS}/v2/messages/${srcDomain}?transactionHash=${burnHash}`);
      if (r.ok) {
        const j = await r.json(); const m = j && j.messages && j.messages[0];
        if (m && m.status === "complete" && m.attestation && m.attestation !== "PENDING") return m;
        if (i % 6 === 0) log(`Waiting for Circle attestation${m && m.status ? " (" + m.status + ")" : ""}...`, "muted");
      } else if (i % 6 === 0) log("Waiting for Circle to see the burn...", "muted");
    } catch (e) { if (i % 6 === 0) log("Attestation service not reachable yet, retrying...", "muted"); }
    await sleep(5000);
  }
}

// ---------- pending transfer (so a burned transfer can always be finished) ----------
const savePending = (p) => { try { localStorage.setItem(PENDING_KEY, JSON.stringify(p)); } catch (e) {} };
const loadPending = () => { try { return JSON.parse(localStorage.getItem(PENDING_KEY) || "null"); } catch (e) { return null; } };
const clearPending = () => { try { localStorage.removeItem(PENDING_KEY); } catch (e) {} };

async function finish(p) {
  // attestation, then mint on Arc
  const src = window.saviorChainByKey(p.from), dst = arc();
  step("attest", ["approve", "burn"]);
  const m = await waitAttestation(src.domain, p.burnHash);
  log("✓ Attestation ready.", "ok");
  step("mint", ["approve", "burn", "attest"]);
  const nonce = m.eventNonce || (m.decodedMessage && m.decodedMessage.nonce);
  if (nonce && /^0x[0-9a-fA-F]{64}$/.test(nonce)) {
    try {
      const used = MT.decodeFunctionResult("usedNonces", await call(dst, dst.cctp.messageTransmitter, MT.encodeFunctionData("usedNonces", [nonce])))[0];
      if (used > 0n) { log("✓ Already minted on Arc.", "ok"); return null; }
    } catch (e) {}
  }
  const data = MT.encodeFunctionData("receiveMessage", [m.message, m.attestation]);
  const hash = await sendTx(dst, dst.cctp.messageTransmitter, data, "Mint on Arc");
  logLink("Mint sent.", txUrl(dst, hash), "muted");
  await waitReceipt(dst, hash, "Mint on Arc");
  logLink("✓ Minted on Arc.", txUrl(dst, hash));
  return hash;
}

const hold = (on) => { try { window.WalletConnector && window.WalletConnector.holdNetwork && window.WalletConnector.holdNetwork(on); } catch (_) {} };
async function backToArc() {
  const wc = window.WalletConnector;
  if (!wc || !wc.address || !wc.ensureArc || wc.chainId === 5042) return;
  try { await wc.ensureArc(); log("Wallet switched back to Arc.", "muted"); } catch (e) { log("Switch your wallet back to Arc for swaps and claims: " + walletError(e), "muted"); }
}
function fail(stage, done, e, retry) {
  const msg = walletError(e);
  if (stage === "mint" && !done.includes("attest")) done.push("attest");
  console.warn("[bridge]", e);
  step(null, done, stage);
  log("✗ " + (stage ? stage.charAt(0).toUpperCase() + stage.slice(1) + " failed: " : "") + msg, "err");
  if (window.toast) window.toast("error", "Bridge failed", msg, { retry });
}

let busy = false;
async function runBridge() {
  if (busy) return;
  const btn = $("bridge-btn");
  const src = window.saviorChainByKey && window.saviorChainByKey($("bridge-from").value);
  const amountStr = ($("bridge-amount").value || "").trim();
  const recipientIn = ($("bridge-recipient").value || "").trim();
  const speed = $("bridge-speed").value;
  $("bridge-log").replaceChildren(); step(null, []);
  if (!src) return log("Choose a source chain.", "err");
  if (!/^\d+(\.\d{1,6})?$/.test(amountStr) || Number(amountStr) <= 0) return log("Enter a valid USDC amount (max 6 decimals).", "err");
  if (!getWallet()) return log("Connect a wallet first (browser wallet or WalletConnect).", "err");
  if (recipientIn && !/^0x[0-9a-fA-F]{40}$/.test(recipientIn)) return log("Recipient must be a 0x EVM address.", "err");
  const pend = loadPending();
  if (pend && pend.burnHash && !pend.minted) log(`Note: an earlier transfer (${pend.amount} USDC from ${pend.fromName}) is not minted yet. Use Retry last transfer to finish it.`, "warn");
  busy = true; btn.disabled = true; hold(true);
  const done = []; cur = "approve";
  try {
    const from = await account();
    if (!from) throw new Error("Connect a wallet first.");
    const recipient = ethers.getAddress(recipientIn || from);
    const amount = ethers.parseUnits(amountStr, 6);
    const { usdc, tokenMessenger } = src.cctp;

    log(`Switching your wallet to ${src.name}...`, "muted");
    await switchWalletTo(src);

    const bal = ERC20.decodeFunctionResult("balanceOf", await call(src, usdc, ERC20.encodeFunctionData("balanceOf", [from])))[0];
    if (bal < amount) throw new Error(`Not enough USDC on ${src.name}: you have ${ethers.formatUnits(bal, 6)}, need ${amountStr}.`);
    const fee = await fastFee(src.domain, speed);
    let maxFee = fee.bps > 0 ? (amount * BigInt(Math.ceil(fee.bps * 1000)) + 10000000n - 1n) / 10000000n : 0n; // ceil(amount * bps / 10000)
    if (maxFee > 0n) maxFee = maxFee + maxFee / 5n + 1n;                                                         // +20% headroom
    if (maxFee >= amount) throw new Error("Amount is too small to cover the fast transfer fee. Enter more or choose Standard.");
    log(`${speed === "FAST" ? "Fast" : "Standard"} transfer: ${amountStr} USDC from ${src.name} to Arc, max fee ${ethers.formatUnits(maxFee, 6)} USDC (paid in USDC, deducted at mint). Recipient ${recipient}.`, "muted");

    // 1. approve (exact amount, standard ERC-20 approve to Circle TokenMessengerV2)
    step("approve", done);
    const allowance = ERC20.decodeFunctionResult("allowance", await call(src, usdc, ERC20.encodeFunctionData("allowance", [from, tokenMessenger])))[0];
    if (allowance >= amount) log("✓ Approve: allowance already covers the amount.", "ok");
    else {
      const h = await sendTx(src, usdc, ERC20.encodeFunctionData("approve", [tokenMessenger, amount]), "Approve USDC");
      logLink("Approve sent.", txUrl(src, h), "muted");
      await waitReceipt(src, h, "Approve");
      logLink("✓ Approve confirmed.", txUrl(src, h));
    }
    done.push("approve");

    // 2. burn
    step("burn", done);
    const burnData = TM.encodeFunctionData("depositForBurn", [amount, ARC_DOMAIN, ethers.zeroPadValue(recipient, 32), usdc, ZERO32, maxFee, fee.finality]);
    const burnHash = await sendTx(src, tokenMessenger, burnData, "Burn USDC");
    const p = { from: src.key, fromName: src.name, burnHash, amount: amountStr, recipient, speed, at: Date.now() };
    savePending(p);
    logLink("Burn sent.", txUrl(src, burnHash), "muted");
    await waitReceipt(src, burnHash, "Burn");
    logLink("✓ Burn confirmed.", txUrl(src, burnHash));
    done.push("burn");

    // 3 + 4. attestation, mint on Arc
    await finish(p);
    clearPending();
    step(null, ORDER.slice());
    log("✓ Done: USDC minted on Arc.", "ok");
    if (window.toast) window.toast("success", "Bridge complete", "USDC minted on Arc.");
  } catch (e) {
    fail(cur, done.slice(), e, runBridge);
    if (done.includes("burn")) log("Your USDC is burned and safe: it can still be minted on Arc. Press Retry last transfer (it also works after a reload).", "warn");
  } finally { busy = false; hold(false); btn.disabled = false; await backToArc(); }
}

async function retryBridge() {
  if (busy) return;
  const p = loadPending();
  if (!p || !p.burnHash) return log("Nothing to retry: no unfinished transfer in this browser.", "muted");
  if (!getWallet()) return log("Connect a wallet first.", "err");
  busy = true; hold(true);
  $("bridge-log").replaceChildren();
  log(`Finishing ${p.amount} USDC from ${p.fromName} (burn ${p.burnHash.slice(0, 10)}...).`, "muted");
  try { await finish(p); clearPending(); step(null, ORDER.slice()); log("✓ Done: USDC minted on Arc.", "ok"); }
  catch (e) { fail(cur, ["approve", "burn"].concat(cur === "mint" ? ["attest"] : []), e, retryBridge); }
  finally { busy = false; hold(false); await backToArc(); }
}

window.SaviorBridge = {
  run: runBridge, retry: retryBridge, pending: loadPending,
  preload: () => { const p = loadPending(); if (p && p.burnHash) log(`Unfinished transfer: ${p.amount} USDC from ${p.fromName}. Press Retry last transfer to mint it on Arc.`, "warn"); },
};
