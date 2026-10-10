// Small helpers for Node (req, res) Vercel functions.
export function getCookie(req, name) {
  const raw = req.headers.cookie || '';
  for (const part of raw.split(/;\s*/)) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i) === name) return decodeURIComponent(part.slice(i + 1));
  }
  return null;
}
export async function readBody(req) {
  if (req.body !== undefined && req.body !== null) {
    if (typeof req.body === 'object' && !Buffer.isBuffer(req.body)) return req.body;
    return parse(String(req.body), req.headers['content-type']);
  }
  const chunks = []; let size = 0;
  for await (const c of req) { size += c.length; if (size > 10_000) break; chunks.push(c); }
  return parse(Buffer.concat(chunks).toString('utf8'), req.headers['content-type']);
}
function parse(text, ct = '') {
  if (ct.includes('application/json')) { try { return JSON.parse(text); } catch { return {}; } }
  return Object.fromEntries(new URLSearchParams(text));
}
export function send(res, status, body, headers = {}) {
  res.statusCode = status;
  res.setHeader('Cache-Control', 'no-store');
  for (const [k, v] of Object.entries(headers)) res.setHeader(k, v);
  res.end(body);
}
export function redirect(res, location, headers = {}) {
  send(res, 303, '', { Location: location, ...headers });
}
