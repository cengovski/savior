// migrate.js, user flow: claim from legacy staking (v1) then stake into SaviorStakingV2.
// Inactive until STAKING_V2_ADDR (index.html) is set. Every write is simulated first, then signed in the user's wallet.
(function () {
  if (typeof STAKING_V2_ADDR === "undefined" || !STAKING_V2_ADDR) return;
  const V1 = STAKING_V1_ADDR, V2 = STAKING_V2_ADDR, TOKEN = TOKEN_ADDR;
  const LOCKS_ABI = ["function getLocks(address) view returns ((uint128 amount,uint64 unlockAt)[])", "function globalUnlock() view returns (bool)", "function claim(uint256)"];
  const V2_ABI = LOCKS_ABI.concat(["function stake(uint256) returns (uint256)"]);
  const ERC = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
  const $ = (id) => document.getElementById(id);
  const fmt = (v) => Number(ethers.formatUnits(v, 6)).toLocaleString("en-US", { maximumFractionDigits: 2 });
  const errMsg = (e) => e.shortMessage || e.reason || e.message || String(e);
  const status = (m) => { $("mig-status").textContent = m; };
  let walletBal = 0n;
  const MIN_STAKE = 1000000n; // SaviorStakingV2.MIN_STAKE = 1 SAVIOR (6 decimals), audit D-2

  async function refresh() {
    const card = $("migrate-card");
    if (!card) return;
    if (!userAddress) { card.classList.add("hidden"); return; }
    try {
      const p = getReadProvider();
      const v1 = new ethers.Contract(V1, LOCKS_ABI, p), v2 = new ethers.Contract(V2, V2_ABI, p), t = new ethers.Contract(TOKEN, ERC, p);
      const [l1, open1, l2, bal] = await Promise.all([v1.getLocks(userAddress), v1.globalUnlock(), v2.getLocks(userAddress), t.balanceOf(userAddress)]);
      const sum = (ls) => ls.reduce((a, l) => a + BigInt(l.amount), 0n);
      const s1 = sum(l1);
      walletBal = BigInt(bal);
      $("mig-v1-total").textContent = fmt(s1) + " SAVIOR";
      $("mig-v1-state").textContent = open1 ? "Unlocked for migration, claim now" : "Migration not started yet (old locks still time-locked)";
      $("mig-wallet").textContent = fmt(walletBal) + " SAVIOR";
      $("mig-v2-total").textContent = fmt(sum(l2)) + " SAVIOR";
      $("mig-claim-btn").disabled = s1 === 0n;
      $("mig-stake-btn").disabled = walletBal < MIN_STAKE;
      card.classList.toggle("hidden", s1 === 0n && sum(l2) === 0n && walletBal === 0n);
    } catch (e) { status("Could not load migration data: " + errMsg(e)); card.classList.remove("hidden"); }
  }

  async function claimAllOld() {
    if (!WalletConnector?.signer) { toast("error", "Connect your wallet first"); return; }
    const v1r = new ethers.Contract(V1, LOCKS_ABI, getReadProvider());
    const v1 = new ethers.Contract(V1, LOCKS_ABI, WalletConnector.signer);
    const [locks, open] = await Promise.all([v1r.getLocks(userAddress), v1r.globalUnlock()]);
    const now = Math.floor(Date.now() / 1000);
    const idx = [];
    locks.forEach((l, i) => { if (BigInt(l.amount) > 0n && (open || now >= Number(l.unlockAt))) idx.push(i); });
    if (!idx.length) { status(open ? "Nothing to claim on the old contract." : "Old locks are still time-locked. Wait for the migration to start."); return; }
    $("mig-claim-btn").disabled = true;
    try {
      for (let k = 0; k < idx.length; k++) {
        const i = idx[k];
        status(`Simulating claim #${i} (${k + 1}/${idx.length})...`);
        await v1.claim.staticCall(i);
        status(`Confirm claim #${i} in your wallet (${k + 1}/${idx.length})`);
        const tx = await v1.claim(i);
        await tx.wait();
      }
      status("Claimed from the old contract. Now stake in the new one.");
      toast("success", "Claimed", "Old positions claimed to your wallet.");
    } catch (e) { status("Claim failed: " + errMsg(e)); }
    await refresh(); await window.refreshStakes?.();
  }

  async function stakeNew() {
    if (!WalletConnector?.signer) { toast("error", "Connect your wallet first"); return; }
    let amt;
    try { amt = ethers.parseUnits(($("mig-amount").value || "0").trim(), 6); } catch (e) { status("Invalid amount"); return; }
    if (amt <= 0n) { status("Enter an amount"); return; }
    if (amt < MIN_STAKE) { status("Minimum stake in the new contract is 1 SAVIOR"); return; }
    if (amt > walletBal) { status("Amount is higher than your wallet balance"); return; }
    $("mig-stake-btn").disabled = true;
    try {
      const signer = WalletConnector.signer;
      const t = new ethers.Contract(TOKEN, ERC, signer), v2 = new ethers.Contract(V2, V2_ABI, signer);
      if (BigInt(await t.allowance(userAddress, V2)) < amt) {
        status("Confirm SAVIOR approval for the new staking contract in your wallet");
        const a = await t.approve(V2, amt); await a.wait();
      }
      status("Simulating stake...");
      await v2.stake.staticCall(amt);
      status("Confirm stake in your wallet");
      const tx = await v2.stake(amt); await tx.wait();
      status("Staked in the new contract. Locked for 5 to 10 days.");
      toast("success", "Staked", fmt(amt) + " SAVIOR staked in the new contract.", { link: "https://explorer.arc.io/tx/" + tx.hash });
      $("mig-amount").value = "";
    } catch (e) { status("Stake failed: " + errMsg(e)); }
    await refresh(); await window.refreshStakes?.();
  }

  function max() { $("mig-amount").value = ethers.formatUnits(walletBal, 6); }

  const orig = window.refreshStakes;
  if (typeof orig === "function") window.refreshStakes = async function () { await orig.apply(this, arguments); await refresh(); };
  window.SaviorMigrate = { refresh, claimAllOld, stakeNew, max };
})();
