// HMAC-SHA256 signed session tokens (Web Crypto; works in Edge + Node 18+).
const enc = new TextEncoder();
const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
async function key(secret) {
  return crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
}
export const COOKIE = '__Host-savior_admin';
export const TTL_SECONDS = 60 * 60 * 8;
export async function sign(payload, secret) {
  const body = b64u(enc.encode(JSON.stringify(payload)));
  const sig = b64u(await crypto.subtle.sign('HMAC', await key(secret), enc.encode(body)));
  return `${body}.${sig}`;
}
export function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}
export async function verify(token, secret) {
  if (!token || !secret) return null;
  const [body, sig] = token.split('.');
  if (!body || !sig) return null;
  const expected = b64u(await crypto.subtle.sign('HMAC', await key(secret), enc.encode(body)));
  if (!safeEqual(sig, expected)) return null;
  try {
    const p = JSON.parse(atob(body.replace(/-/g,'+').replace(/_/g,'/')));
    return p.exp > Math.floor(Date.now() / 1000) ? p : null;
  } catch { return null; }
}
export function getCookie(req, name) {
  const m = (req.headers.get('cookie') || '').match(new RegExp('(?:^|; )' + name.replace(/[-]/g,'\\-') + '=([^;]*)'));
  return m ? decodeURIComponent(m[1]) : null;
}
