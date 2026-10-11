// Faithful-ish local emulation of Vercel routing for admin/: rewrites from vercel.json,
// static files from outputDirectory, /api/* -> Node functions, otherwise 404.
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path'; import { pathToFileURL } from 'node:url';
const root = process.argv[2]; process.chdir(root);
const cfg = JSON.parse(fs.readFileSync('vercel.json','utf8'));
http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x'); let p = u.pathname;
  const sp = path.join(root, cfg.outputDirectory, p);
  if (p !== '/' && fs.existsSync(sp) && fs.statSync(sp).isFile()) { res.end(fs.readFileSync(sp)); return; }
  for (const r of cfg.rewrites) if (r.source === p) { p = r.destination; break; }
  const m = p.match(/^\/api\/([a-z-]+)$/);
  if (m && fs.existsSync(path.join(root,'api',m[1]+'.js'))) {
    req.url = p + u.search;
    try { const mod = await import(pathToFileURL(path.join(root,'api',m[1]+'.js'))); await mod.default(req, res); }
    catch (e) { res.statusCode = 500; res.end(String(e)); }
    return;
  }
  res.statusCode = 404; res.end('NOT_FOUND');
}).listen(3999, () => console.log('ready'));
