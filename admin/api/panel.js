// Serves the admin panel only after re-verifying the session (defence in
// depth: the HTML lives outside public/ so it is never a static asset).
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { verify } from '../lib/session.js';

export default async function handler(req, res) {
  const m = (req.headers.cookie || '').match(/(?:^|; )__Host-savior_admin=([^;]*)/);
  const ok = await verify(m ? decodeURIComponent(m[1]) : null, process.env.SESSION_SECRET);
  if (!ok) { res.statusCode = 302; res.setHeader('Location', '/login'); return res.end(); }
  const html = await readFile(path.join(process.cwd(), 'protected', 'admin.html'), 'utf8');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(html);
}
