// GET /login -> login form. POST /login (or /api/login) -> check ADMIN_PASSWORD,
// set HttpOnly signed session cookie. Rate limited per IP.
import { COOKIE, TTL_SECONDS, sign, safeEqual } from '../lib/session.js';
import { readBody, send, redirect } from '../lib/http.js';

const PAGE = (err) => `<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>SAVIOR Admin – Giriş</title>
<style>body{background:#0f172a;color:#e2e8f0;font-family:system-ui;display:flex;justify-content:center;padding-top:80px}
form{background:#1e293b;padding:24px;border-radius:12px;width:340px}input,button{width:100%;padding:10px;margin-top:10px;border-radius:8px;border:1px solid #334155;box-sizing:border-box}
button{background:#2563eb;color:#fff;font-weight:600}.err{color:#f87171}</style></head>
<body><form method="post" action="/login"><h1>SAVIOR Admin</h1><label>Şifre</label>
<input name="password" type="password" autocomplete="current-password" required><button>Giriş</button>
${err ? `<p class="err">${err}</p>` : ''}</form></body></html>`;

// Best-effort per-instance limiter; optional global limiter via Upstash.
const hits = new Map();
const WINDOW = 15 * 60 * 1000, MAX = 5;
async function limited(ip) {
  const url = process.env.UPSTASH_REDIS_REST_URL, tok = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (url && tok) {
    const k = `admin-login:${ip}`;
    const r = await fetch(`${url}/pipeline`, { method: 'POST', headers: { Authorization: `Bearer ${tok}` },
      body: JSON.stringify([['INCR', k], ['EXPIRE', k, String(WINDOW / 1000), 'NX']]) });
    const out = await r.json();
    return Number(out?.[0]?.result) > MAX;
  }
  const now = Date.now();
  const e = hits.get(ip) || { n: 0, t: now };
  if (now - e.t > WINDOW) { e.n = 0; e.t = now; }
  e.n++; hits.set(ip, e);
  return e.n > MAX;
}

export default async function handler(req, res) {
  const html = { 'Content-Type': 'text/html; charset=utf-8' };
  if (req.method === 'GET' || req.method === 'HEAD') {
    const err = (req.url || '').includes('e=1') ? 'Hatalı şifre' : '';
    return send(res, 200, PAGE(err), html);
  }
  if (req.method !== 'POST') return send(res, 405, 'Method not allowed', { Allow: 'GET, POST' });

  const origin = req.headers.origin;
  if (origin) {
    try { if (new URL(origin).host !== req.headers.host) return send(res, 403, 'Forbidden'); }
    catch { return send(res, 403, 'Forbidden'); }
  }
  const ip = String(req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (await limited(ip)) return send(res, 429, PAGE('Çok fazla deneme, 15 dk sonra tekrar deneyin'), { ...html, 'Retry-After': '900' });

  const pw = process.env.ADMIN_PASSWORD, secret = process.env.SESSION_SECRET;
  if (!pw || !secret) return send(res, 503, 'Admin not configured (ADMIN_PASSWORD / SESSION_SECRET missing)');

  const body = await readBody(req);
  if (!safeEqual(String(body.password || ''), pw)) {
    await new Promise(r => setTimeout(r, 500));
    return redirect(res, '/login?e=1');
  }
  const exp = Math.floor(Date.now() / 1000) + TTL_SECONDS;
  const token = await sign({ sub: 'admin', exp }, secret);
  redirect(res, '/', { 'Set-Cookie': `${COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${TTL_SECONDS}` });
}
