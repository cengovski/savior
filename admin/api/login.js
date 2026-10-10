// POST /api/login  (form or JSON: { password })
// Edge function. Compares against ADMIN_PASSWORD env var (constant-time),
// issues HttpOnly; Secure; SameSite=Strict signed cookie. Rate limited.
import { COOKIE, TTL_SECONDS, sign, safeEqual } from '../lib/session.js';
export const config = { runtime: 'edge' };

// Best-effort per-instance limiter. For a hard global limit, also add a
// Vercel Firewall rate-limit rule on /api/login (see admin/README.md) or
// set UPSTASH_REDIS_REST_URL/TOKEN.
const hits = new Map();
const WINDOW = 15 * 60 * 1000, MAX = 5;
async function limited(ip) {
  const url = process.env.UPSTASH_REDIS_REST_URL, tok = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (url && tok) {
    const k = `admin-login:${ip}`;
    const r = await fetch(`${url}/pipeline`, { method: 'POST', headers: { Authorization: `Bearer ${tok}` },
      body: JSON.stringify([['INCR', k], ['EXPIRE', k, String(WINDOW / 1000), 'NX']]) });
    const [[, n]] = (await r.json()).map(x => [null, x.result]);
    return n > MAX;
  }
  const now = Date.now();
  const e = hits.get(ip) || { n: 0, t: now };
  if (now - e.t > WINDOW) { e.n = 0; e.t = now; }
  e.n++; hits.set(ip, e);
  return e.n > MAX;
}

export default async function handler(req) {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== new URL(req.url).host) return new Response('Forbidden', { status: 403 });
  const ip = (req.headers.get('x-forwarded-for') || 'unknown').split(',')[0].trim();
  if (await limited(ip)) return new Response('Too many attempts', { status: 429, headers: { 'Retry-After': '900' } });

  const pw = process.env.ADMIN_PASSWORD, secret = process.env.SESSION_SECRET;
  if (!pw || !secret) return new Response('Admin not configured', { status: 503 });

  let given = '';
  const ct = req.headers.get('content-type') || '';
  if (ct.includes('application/json')) given = (await req.json()).password || '';
  else given = (await req.formData()).get('password') || '';

  if (!safeEqual(String(given), pw)) {
    await new Promise(r => setTimeout(r, 500));
    return Response.redirect(new URL('/login?e=1', req.url), 303);
  }
  const exp = Math.floor(Date.now() / 1000) + TTL_SECONDS;
  const token = await sign({ sub: 'admin', exp }, secret);
  return new Response(null, { status: 303, headers: {
    Location: '/',
    'Set-Cookie': `${COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${TTL_SECONDS}`,
    'Cache-Control': 'no-store',
  }});
}
