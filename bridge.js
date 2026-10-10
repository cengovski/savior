// bridge.js, USDC → Arc via Circle CCTP V2 using Circle Bridge Kit. No API key, no backend:
// the user's injected wallet signs approve+burn on the source chain and the mint on Arc;
// attestation comes from Circle's public Iris API (handled inside Bridge Kit).
let kitMod = null;
const $ = (id) => document.getElementById(id);
function log(msg, cls = "text-white/60") {
  const box = $("bridge-log"); if (!box) return;
  const d = document.createElement("div"); d.className = cls; d.textContent = msg; box.appendChild(d); box.scrollTop = box.scrollHeight;
}
async function loadKit() {
  if (!kitMod) { log("Loading Bridge Kit…", "text-white/30"); kitMod = await import("./vendor/bridge-kit.esm.js"); }
  return kitMod;
}
function explorerLink(step) {
  return step && (step.explorerUrl || step.txHash || "");
}
async function runBridge() {
  const btn = $("bridge-btn");
  const from = $("bridge-from").value;
  const amount = ($("bridge-amount").value || "").trim();
  const recipient = ($("bridge-recipient").value || "").trim();
  const speed = $("bridge-speed").value;
  $("bridge-log").replaceChildren();
  if (!/^\d+(\.\d{1,6})?$/.test(amount) || Number(amount) <= 0) return log("Enter a valid USDC amount (max 6 decimals).", "text-rose-400");
  if (!window.ethereum) return log("No injected wallet found (MetaMask, Rabby, Coinbase…). WalletConnect is not supported for bridging yet.", "text-rose-400");
  if (recipient && !/^0x[0-9a-fA-F]{40}$/.test(recipient)) return log("Recipient must be a 0x EVM address.", "text-rose-400");
  btn.disabled = true;
  try {
    const { BridgeKit, createEthersAdapterFromProvider } = await loadKit();
    const kit = new BridgeKit();
    const adapter = await createEthersAdapterFromProvider({ provider: window.ethereum });
    kit.on("*", (p) => {
      try {
        const name = p?.method || p?.name || p?.action || "step";
        const v = p?.values || p;
        log(`• ${name}${v?.state ? ", " + v.state : ""}${v?.txHash ? ", " + v.txHash : ""}`);
      } catch (_) {}
    });
    const to = { adapter, chain: "Arc" };
    if (recipient) to.recipientAddress = recipient;
    const params = { from: { adapter, chain: from }, to, amount, config: { transferSpeed: speed } };
    try {
      const est = await kit.estimate(params);
      log("Estimate: " + JSON.stringify(est, (k, v) => (typeof v === "bigint" ? v.toString() : v)).slice(0, 400), "text-white/40");
    } catch (e) { log("Estimate unavailable: " + (e.shortMessage || e.message), "text-white/30"); }
    log(`Bridging ${amount} USDC ${from} → Arc (CCTP domain 26). Confirm each step in your wallet: approve → burn → (attestation) → mint on Arc.`, "text-amber-300");
    const res = await kit.bridge(params);
    window.lastBridgeResult = res;
    for (const s of res.steps || []) log(`✓ ${s.name}: ${s.state}${explorerLink(s) ? " " + explorerLink(s) : ""}`, s.state === "error" ? "text-rose-400" : "text-emerald-400");
    log(`Result: ${res.state}`, res.state === "success" ? "text-emerald-400 font-bold" : "text-amber-400 font-bold");
    if (res.state !== "success") log("Transfer is not complete. Funds are not lost: burned USDC can be minted later, keep this page open and press Bridge → Retry, or use kit.retry(window.lastBridgeResult).", "text-amber-300");
  } catch (e) {
    console.error("[bridge]", e);
    log("Error: " + (e.shortMessage || e.message || String(e)), "text-rose-400");
  } finally { btn.disabled = false; }
}
async function retryBridge() {
  if (!window.lastBridgeResult) return log("Nothing to retry.", "text-white/40");
  const { BridgeKit, createEthersAdapterFromProvider } = await loadKit();
  const kit = new BridgeKit();
  const adapter = await createEthersAdapterFromProvider({ provider: window.ethereum });
  try { const r = await kit.retry(window.lastBridgeResult, { from: adapter, to: adapter }); window.lastBridgeResult = r; log("Retry result: " + r.state, "text-emerald-400"); }
  catch (e) { log("Retry failed: " + (e.shortMessage || e.message), "text-rose-400"); }
}
window.SaviorBridge = { run: runBridge, retry: retryBridge, preload: () => loadKit().then(() => log("Bridge Kit ready.", "text-white/30")).catch((e) => log("Failed to load Bridge Kit: " + e.message, "text-rose-400")) };
