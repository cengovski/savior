// GET / (rewritten here). Valid session cookie -> admin panel HTML, else -> /login.
// The HTML lives in protected/ (outside the static output dir) and is bundled
// into this function via vercel.json functions.includeFiles.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const HERE = path.dirname(fileURLToPath(import.meta.url));
const CANDIDATES = [
  path.join(HERE, '..', 'protected', 'admin.html'),
  path.join(process.cwd(), 'protected', 'admin.html'),
  path.join(process.cwd(), 'admin', 'protected', 'admin.html'),
];
async function loadPanel() {
  for (const p of CANDIDATES) { try { return await readFile(p, 'utf8'); } catch {} }
  throw new Error('panel html not found: ' + CANDIDATES.join(' | '));
}
import { COOKIE, verify } from '../lib/session.js';
import { getCookie, send, redirect } from '../lib/http.js';

export default async function handler(req, res) {
  const ok = await verify(getCookie(req, COOKIE), process.env.SESSION_SECRET);
  if (!ok) return redirect(res, '/login');
  try {
    const html = await loadPanel();
    send(res, 200, html, { 'Content-Type': 'text/html; charset=utf-8' });
  } catch (e) {
    console.error(e);
    send(res, 500, 'Panel unavailable: ' + e.message);
  }
}
