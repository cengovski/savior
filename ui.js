// ui.js: theme, mobile menu, toasts, modal behavior, bridge chain pills, on-chain stats.
(function () {
  const $ = (id) => document.getElementById(id);

  // ---------- theme ----------
  function currentTheme() { return document.documentElement.getAttribute("data-theme") || "light"; }
  function applyTheme(t, save) {
    document.documentElement.setAttribute("data-theme", t);
    if (save) try { localStorage.setItem("savior.theme", t); } catch (e) {}
    const b = $("theme-btn"); if (b) b.innerHTML = `<svg class="ico-18"><use href="#i-${t === "dark" ? "sun" : "moon"}"/></svg>`;
    const m = document.querySelector('meta[name="theme-color"]'); if (m) m.content = t === "dark" ? "#00011C" : "#FAFAFA";
    window.dispatchEvent(new CustomEvent("savior:theme", { detail: t }));
  }
  window.toggleTheme = () => applyTheme(currentTheme() === "dark" ? "light" : "dark", true);
  window.getTheme = currentTheme;
  // follow the system while the user has not chosen
  try {
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
      if (!localStorage.getItem("savior.theme")) applyTheme(e.matches ? "dark" : "light", false);
    });
  } catch (e) {}

  // ---------- menu ----------
  window.openMenu = () => { $("menu-sheet").classList.remove("hidden"); trap($("menu-sheet")); };
  window.closeMenu = () => { $("menu-sheet").classList.add("hidden"); untrap(); };

  // ---------- modals: Esc closes, focus trap ----------
  let trapped = null, lastFocus = null;
  function trap(node) {
    lastFocus = document.activeElement; trapped = node;
    const f = node.querySelector("button,input,select,a[href]"); if (f) setTimeout(() => f.focus(), 30);
  }
  function untrap() { trapped = null; if (lastFocus && lastFocus.focus) lastFocus.focus(); }
  document.addEventListener("keydown", (e) => {
    if (!trapped || trapped.classList.contains("hidden")) return;
    if (e.key === "Escape") {
      if (trapped.id === "slip-panel") window.toggleSlipPanel();
      else if (trapped.id === "net-modal") window.closeNetModal();
      else if (trapped.id === "menu-sheet") window.closeMenu();
    } else if (e.key === "Tab") {
      const els = [...trapped.querySelectorAll("button,input,select,a[href]")].filter((x) => x.offsetParent !== null);
      if (!els.length) return;
      const first = els[0], last = els[els.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    }
  });
  window.__savTrap = trap; window.__savUntrap = untrap;

  // ---------- network modal ----------
  window.openNetModal = (name) => { $("net-current").textContent = name || "Another network"; $("net-modal").classList.remove("hidden"); trap($("net-modal")); };
  window.closeNetModal = () => { $("net-modal").classList.add("hidden"); untrap(); };
  window.switchToArc = async () => {
    try { await window.WalletConnector.switchToArc(); window.closeNetModal(); toast("success", "Switched to Arc Mainnet"); }
    catch (e) { toast("error", "Could not switch network", (e && (e.shortMessage || e.message)) || ""); }
  };

  // ---------- toasts ----------
  // toast(kind, title, subtitle, {link, linkText, sticky}) -> {update(kind,title,sub,opts), close()}
  window.toast = function (kind, title, sub, opts = {}) {
    const box = $("toasts"); if (!box) return { update() {}, close() {} };
    const t = document.createElement("div");
    let timer = null;
    function paint(k, ti, su, o = {}) {
      t.className = "toast " + k;
      t.replaceChildren();
      const dot = document.createElement("span"); dot.className = "dot"; t.appendChild(dot);
      const body = document.createElement("div");
      const b = document.createElement("b"); b.textContent = ti; body.appendChild(b);
      if (su || o.link) {
        const s = document.createElement("small"); if (su) s.textContent = su + (o.link ? " " : "");
        if (o.link) { const a = document.createElement("a"); a.href = o.link; a.target = "_blank"; a.rel = "noopener"; a.textContent = o.linkText || "View on explorer"; s.appendChild(a); }
        if (o.retry) { const r = document.createElement("a"); r.href = "#"; r.textContent = " Retry"; r.onclick = (e) => { e.preventDefault(); close(); o.retry(); }; s.appendChild(r); }
        body.appendChild(s);
      }
      t.appendChild(body);
      const x = document.createElement("button"); x.className = "x"; x.setAttribute("aria-label", "Dismiss"); x.textContent = "\u00d7"; x.onclick = close; t.appendChild(x);
      clearTimeout(timer);
      if (k !== "pending" && !o.sticky) timer = setTimeout(close, 6000);
    }
    function close() { clearTimeout(timer); t.remove(); }
    paint(kind, title, sub, opts);
    box.appendChild(t);
    return { update: paint, close };
  };

  // ---------- bridge chain pills + steps ----------
  document.addEventListener("click", (e) => {
    const c = e.target.closest && e.target.closest(".chain");
    if (!c) return;
    document.querySelectorAll(".chain").forEach((x) => x.classList.toggle("active", x === c));
    $("bridge-from").value = c.dataset.chain;
  });
  window.setBridgeStep = (active, done = []) => {
    document.querySelectorAll("#bridge-steps .step").forEach((s) => {
      s.classList.toggle("done", done.includes(s.dataset.step));
      s.classList.toggle("active", s.dataset.step === active);
    });
  };

  // ---------- lazy-load Bridge Kit when the bridge section is near ----------
  function watchBridge() {
    const sec = $("bridge"); if (!sec || !("IntersectionObserver" in window)) return;
    const io = new IntersectionObserver((ents) => {
      if (ents.some((x) => x.isIntersecting) && window.SaviorBridge) { window.SaviorBridge.preload(); io.disconnect(); }
    }, { rootMargin: "300px" });
    io.observe(sec);
  }

  // ---------- on-chain stats: price and supply ----------
  async function stats() {
    if (typeof ethers === "undefined" || !window.SaviorQuote) return setTimeout(stats, 500);
    try {
      const p = window.SaviorRPC.provider();
      const run = (fn) => (window.SaviorLocks ? window.SaviorLocks.rpc(fn) : fn());
      const st = await run(() => window.SaviorQuote.readState(p));
      // sqrtPriceX96 = sqrt(SAVIOR/USDC); USDC per SAVIOR = (2^96/sqrtP)^2; both 6 decimals
      const x = Number((1n << 96n) * 1000000n / st.sqrtP) / 1e6;
      $("pool-price").textContent = (x * x * 1e6).toLocaleString("en-US", { maximumFractionDigits: 4 }) + " USDC";
      const tok = new ethers.Contract(window.SAVIOR_CONFIG.contracts.token, ["function totalSupply() view returns (uint256)"], p);
      const sup = await run(() => tok.totalSupply());
      const n = Number(ethers.formatUnits(sup, 6));
      $("tok-supply").textContent = n.toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 2 });
      $("tok-supply").title = n.toLocaleString("en-US") + " SAVIOR";
    } catch (e) { console.warn("stats", e); setTimeout(stats, 30000); } // keep last value, try again later
  }

  document.addEventListener("DOMContentLoaded", () => { applyTheme(currentTheme(), false); watchBridge(); setTimeout(stats, 800); });
})();
