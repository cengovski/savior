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

  // ---------- bridge "From chain" dropdown (listbox) + steps ----------
  (function chainSelect() {
    const wrap = $("bridge-chain-select"), btn = $("bridge-from-btn"), list = $("bridge-chain-list"), input = $("bridge-from");
    const chains = window.SAVIOR_BRIDGE_CHAINS || [];
    if (!wrap || !btn || !list || !input || !chains.length) return;
    const POPULAR = 8;
    const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
    const icon = (c) => c.logo
      ? `<img class="chain-logo" src="assets/logos/${c.logo}" alt="" width="20" height="20"/>`
      : `<span class="chain-mono" style="--c:${c.color || "#334155"}" aria-hidden="true">${esc(c.name.charAt(0))}</span>`;
    const optId = (c) => "bridge-chain-" + c.key;
    list.innerHTML = chains.map((c, i) =>
      (i === 0 ? '<li class="cs-group" role="presentation">Popular</li>' : i === POPULAR ? '<li class="cs-group" role="presentation">More chains</li>' : "") +
      `<li role="option" id="${optId(c)}" data-chain="${esc(c.key)}" aria-selected="false">${icon(c)}<span>${esc(c.name)}</span><span class="cs-gas">${esc(c.native.symbol)}</span></li>`).join("");
    const opts = () => Array.from(list.querySelectorAll('[role="option"]'));
    let active = -1, typed = "", typedAt = 0;
    const isOpen = () => !list.classList.contains("hidden");
    function highlight(i, scroll = true) {
      const o = opts(); if (!o.length) return;
      active = Math.max(0, Math.min(o.length - 1, i));
      o.forEach((x, k) => x.classList.toggle("kb", k === active));
      list.setAttribute("aria-activedescendant", o[active].id);
      if (scroll) o[active].scrollIntoView({ block: "nearest" });
    }
    function select(key, fire = true) {
      const c = chains.find((x) => x.key === key); if (!c) return;
      const changed = input.value !== key;
      input.value = key;
      opts().forEach((x) => x.setAttribute("aria-selected", String(x.dataset.chain === key)));
      $("bridge-from-value").innerHTML = icon(c) + `<span class="cs-name">${esc(c.name)}</span>`;
      const gas = $("bridge-gas-note"); if (gas) gas.textContent = `${c.native.symbol} on ${c.name}`;
      if (fire && changed) {
        input.dispatchEvent(new Event("change", { bubbles: true }));
        document.dispatchEvent(new CustomEvent("savior:bridge-chain", { detail: c }));
      }
    }
    function open() {
      if (isOpen()) return;
      list.classList.remove("hidden"); wrap.classList.add("open"); btn.setAttribute("aria-expanded", "true");
      const i = opts().findIndex((x) => x.dataset.chain === input.value);
      highlight(i < 0 ? 0 : i, false);
      const o = opts()[active]; if (o) list.scrollTop = Math.max(0, o.offsetTop - list.clientHeight / 2 + o.offsetHeight / 2);
      list.focus({ preventScroll: true });
    }
    function close(focusBtn = true) {
      if (!isOpen()) return;
      list.classList.add("hidden"); wrap.classList.remove("open"); btn.setAttribute("aria-expanded", "false");
      list.removeAttribute("aria-activedescendant");
      if (focusBtn) btn.focus({ preventScroll: true });
    }
    btn.addEventListener("click", () => (isOpen() ? close() : open()));
    btn.addEventListener("keydown", (e) => {
      if (["ArrowDown", "ArrowUp", "Enter", " "].includes(e.key)) { e.preventDefault(); open(); }
    });
    list.addEventListener("click", (e) => {
      const li = e.target.closest('[role="option"]'); if (!li) return;
      select(li.dataset.chain); close();
    });
    list.addEventListener("mousemove", (e) => {
      const li = e.target.closest('[role="option"]'); if (!li) return;
      const i = opts().indexOf(li); if (i !== active) highlight(i, false);
    });
    list.addEventListener("keydown", (e) => {
      const n = opts().length, page = 6;
      switch (e.key) {
        case "ArrowDown": e.preventDefault(); highlight(active + 1); break;
        case "ArrowUp": e.preventDefault(); highlight(active - 1); break;
        case "Home": e.preventDefault(); highlight(0); break;
        case "End": e.preventDefault(); highlight(n - 1); break;
        case "PageDown": e.preventDefault(); highlight(active + page); break;
        case "PageUp": e.preventDefault(); highlight(active - page); break;
        case "Enter": case " ": e.preventDefault(); if (active >= 0) select(opts()[active].dataset.chain); close(); break;
        case "Escape": e.preventDefault(); close(); break;
        case "Tab": close(false); break;
        default:
          if (e.key.length === 1 && /\S/.test(e.key)) {   // type-ahead
            const now = Date.now(); typed = (now - typedAt < 700 ? typed : "") + e.key.toLowerCase(); typedAt = now;
            const i = chains.findIndex((c) => c.name.toLowerCase().startsWith(typed));
            if (i >= 0) highlight(i);
          }
      }
    });
    document.addEventListener("pointerdown", (e) => { if (isOpen() && !wrap.contains(e.target)) close(false); });
    select(input.value || window.SAVIOR_DEFAULT_BRIDGE_CHAIN || chains[0].key, false);
    window.SaviorChainSelect = { open, close, select, get value() { return input.value; } };
  })();
  window.setBridgeStep = (active, done = [], failed = null) => {
    document.querySelectorAll("#bridge-steps .step").forEach((s) => {
      s.classList.toggle("done", done.includes(s.dataset.step) && s.dataset.step !== failed);
      s.classList.toggle("active", s.dataset.step === active);
      s.classList.toggle("err", s.dataset.step === failed);
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
    if (!$("pool-price") && !$("tok-supply")) return; // these stats live on the Docs page now
    if (typeof ethers === "undefined" || !window.SaviorQuote) return setTimeout(stats, 500);
    try {
      const p = window.SaviorRPC.provider();
      const run = (fn) => (window.SaviorLocks ? window.SaviorLocks.rpc(fn) : fn());
      const st = await run(() => window.SaviorQuote.readState(p));
      // sqrtPriceX96 = sqrt(SAVIOR/USDC); USDC per SAVIOR = (2^96/sqrtP)^2; both 6 decimals
      // (if the pool sorts SAVIOR first, sqrtP = sqrt(USDC/SAVIOR) instead)
      const x = window.SAVIOR_CONFIG.saviorIsCurrency0 ? Number(st.sqrtP * 1000000n / (1n << 96n)) / 1e6 : Number((1n << 96n) * 1000000n / st.sqrtP) / 1e6;
      if ($("pool-price")) $("pool-price").textContent = (x * x * 1e6).toLocaleString("en-US", { maximumFractionDigits: 4 }) + " USDC";
      const tok = new ethers.Contract(window.SAVIOR_CONFIG.contracts.token, ["function totalSupply() view returns (uint256)"], p);
      const sup = await run(() => tok.totalSupply());
      const n = Number(ethers.formatUnits(sup, 6));
      if ($("tok-supply")) { $("tok-supply").textContent = n.toLocaleString("en-US", { notation: "compact", maximumFractionDigits: 2 }); $("tok-supply").title = n.toLocaleString("en-US") + " SAVIOR"; }
    } catch (e) { console.warn("stats", e); setTimeout(stats, 30000); } // keep last value, try again later
  }

  document.addEventListener("DOMContentLoaded", () => { applyTheme(currentTheme(), false); watchBridge(); setTimeout(stats, 800); });
})();
