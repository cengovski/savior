// quote.js: read-only swap estimate for the $SAVIOR pool, no wallet needed.
// The official V4 Quoter cannot be used: the pool hook only accepts swaps routed by the staking contract,
// so the quote reverts. Instead we simulate the Uniswap V4 swap math client-side from on-chain state
// (PoolManager.extsload: slot0, liquidity, per-tick liquidityNet), then apply the staking contract's
// 0.3% treasury fee on the output and the 50/50 instant/locked split for buys.
(function () {
  const PM = "0x8366a39CC670B4001A1121B8F6A443A643e40951";
  const POOL_ID = "0x004d7e7f668a78ea18228d753008ccf0c2b6b9e7c6c03d7a44d7cd954d072ab6";
  const TICK_SPACING = 200, POOLS_SLOT = 6n, TREASURY_BPS = 30n, MAX_STEPS = 80;
  const Q96 = 1n << 96n, MIN_TICK = -887272, MAX_TICK = 887272;
  const abi = ethers.AbiCoder.defaultAbiCoder();
  let pm = null;
  const contract = (provider) => (pm = pm || new ethers.Contract(PM, ["function extsload(bytes32) view returns (bytes32)"], provider));
  const stateSlot = BigInt(ethers.keccak256(abi.encode(["bytes32", "uint256"], [POOL_ID, POOLS_SLOT])));
  const toS = (n) => ethers.toBeHex(n, 32);

  function sqrtAtTick(tick) {
    const absTick = BigInt(tick < 0 ? -tick : tick);
    let r = (absTick & 1n) ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
    const m = [0xfff97272373d413259a46990580e213an, 0xfff2e50f5f656932ef12357cf3c7fdccn, 0xffe5caca7e10e4e61c3624eaa0941cd0n,
      0xffcb9843d60f6159c9db58835c926644n, 0xff973b41fa98c081472e6896dfb254c0n, 0xff2ea16466c96a3843ec78b326b52861n,
      0xfe5dee046a99a2a811c461f1969c3053n, 0xfcbe86c7900a88aedcffc83b479aa3a4n, 0xf987a7253ac413176f2b074cf7815e54n,
      0xf3392b0822b70005940c7a398e4b70f3n, 0xe7159475a2c29b7443b29c7fa6e889d9n, 0xd097f3bdfd2022b8845ad8f792aa5825n,
      0xa9f746462d870fdf8a65dc1f90e061e5n, 0x70d869a156d2a1b890bb3df62baf32f7n, 0x31be135f97d08fd981231505542fcfa6n,
      0x9aa508b5b7a84e1c677de54f3e99bc9n, 0x5d6af8dedb81196699c329225ee604n, 0x2216e584f5fa1ea926041bedfe98n, 0x48a170391f7dc42444e8fa2n];
    for (let i = 0; i < m.length; i++) if (absTick & (1n << BigInt(i + 1))) r = (r * m[i]) >> 128n;
    if (tick > 0) r = ((1n << 256n) - 1n) / r;
    return (r >> 32n) + ((r % (1n << 32n)) === 0n ? 0n : 1n);
  }
  const divUp = (a, b) => a / b + (a % b ? 1n : 0n);
  const amount0Delta = (a, b, L, up) => { if (a > b) [a, b] = [b, a]; const n = (L << 96n) * (b - a); return up ? divUp(divUp(n, b), a) : n / b / a; };
  const amount1Delta = (a, b, L, up) => { if (a > b) [a, b] = [b, a]; const n = L * (b - a); return up ? divUp(n, Q96) : n / Q96; };
  function nextSqrtFromInput(sqrtP, L, amountIn, zeroForOne) {
    if (zeroForOne) { const num = L << 96n; return divUp(num * sqrtP, num + amountIn * sqrtP); }
    return sqrtP + (amountIn << 96n) / L;
  }

  async function readState(provider) {
    const c = contract(provider);
    const [s0, liq] = await Promise.all([c.extsload(toS(stateSlot)), c.extsload(toS(stateSlot + 3n))]);
    const w = BigInt(s0);
    const sqrtP = w & ((1n << 160n) - 1n);
    let tick = Number((w >> 160n) & 0xffffffn); if (tick >= 0x800000) tick -= 0x1000000;
    const lpFee = (w >> 208n) & 0xffffffn;
    const protoFee = (w >> 184n) & 0xffffffn;
    return { sqrtP, tick, lpFee, protoFee, L: BigInt(liq) & ((1n << 128n) - 1n) };
  }
  const tickCache = new Map();
  async function liquidityNet(provider, tick) {
    if (tickCache.has(tick)) return tickCache.get(tick);
    const slot = BigInt(ethers.keccak256(abi.encode(["int24", "uint256"], [tick, stateSlot + 4n])));
    const w = BigInt(await contract(provider).extsload(toS(slot)));
    let net = w >> 128n; if (net >= 1n << 127n) net -= 1n << 128n;
    tickCache.set(tick, net); return net;
  }

  // Exact-input swap on the pool. zeroForOne=true: USDC in (buy). Returns gross output from the pool.
  async function simulate(provider, zeroForOne, amountIn) {
    const st = await readState(provider);
    if (st.sqrtP === 0n) throw new Error("Pool not initialized");
    const feePips = st.lpFee; // dynamic-fee flag not set on this pool; protocol fee is 0 on Arc today
    let { sqrtP, L, tick } = st, rem = amountIn, out = 0n;
    for (let i = 0; i < MAX_STEPS && rem > 0n; i++) {
      const base = Math.floor(tick / TICK_SPACING) * TICK_SPACING;
      let nextTick = zeroForOne ? (sqrtP <= sqrtAtTick(base) ? base - TICK_SPACING : base) : base + TICK_SPACING;
      nextTick = Math.max(MIN_TICK, Math.min(MAX_TICK, nextTick));
      const target = sqrtAtTick(nextTick);
      const remLessFee = (rem * (1000000n - feePips)) / 1000000n;
      if (L > 0n) {
        const inToTarget = zeroForOne ? amount0Delta(target, sqrtP, L, true) : amount1Delta(sqrtP, target, L, true);
        if (remLessFee >= inToTarget) {
          const fee = divUp(inToTarget * feePips, 1000000n - feePips);
          out += zeroForOne ? amount1Delta(target, sqrtP, L, false) : amount0Delta(sqrtP, target, L, false);
          rem -= inToTarget + fee; sqrtP = target;
        } else {
          const nxt = nextSqrtFromInput(sqrtP, L, remLessFee, zeroForOne);
          out += zeroForOne ? amount1Delta(nxt, sqrtP, L, false) : amount0Delta(sqrtP, nxt, L, false);
          rem = 0n; break;
        }
      } else sqrtP = target;
      const net = await liquidityNet(provider, nextTick);
      L = zeroForOne ? L - net : L + net;
      tick = zeroForOne ? nextTick - 1 : nextTick;
      if (L < 0n) break;
    }
    if (rem > 0n) throw new Error("Not enough liquidity for this amount");
    return out;
  }

  // Public API: amounts in base units (6 decimals for both tokens).
  async function quote(provider, isBuy, amountIn) {
    tickCache.clear();
    const gross = await simulate(provider, isBuy, amountIn);
    const fee = (gross * TREASURY_BPS) / 10000n;
    const net = gross - fee;
    if (isBuy) { const locked = net / 2n; return { gross, fee, net, immediate: net - locked, locked }; }
    return { gross, fee, net };
  }
  // minOut for swapExactIn. v1 checks it against the GROSS pool output; v2 (SaviorStakingV2) checks the NET output
  // after the 0.3% treasury fee. Fee and the 50/50 split are identical in v1 and v2, so quote() needs no change.
  function minOut(q, slipBps) {
    const base = window.SAVIOR_CONFIG && window.SAVIOR_CONFIG.v2 ? q.net : q.gross;
    return base > 0n ? (base * BigInt(10000 - slipBps)) / 10000n : 1n;
  }
  window.SaviorQuote = { quote, simulate, readState, sqrtAtTick, minOut };
})();
