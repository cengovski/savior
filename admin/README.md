# SAVIOR Admin (protected, separate Vercel project)

The admin panel is **no longer part of the public site** (root `admin.html` and
`docs/admin.html` were removed; root `.vercelignore` excludes `admin/`).
It is deployed as its own Vercel project with Root Directory = `admin/`.

## How auth works (no middleware; all routing via functions)
- `vercel.json` rewrites `/` -> `api/panel`, `/login` -> `api/login`, `/logout` -> `api/logout`.
- `api/panel.js` checks the `__Host-savior_admin` cookie (HMAC-SHA256 signed with
  `SESSION_SECRET`); valid -> serves `protected/admin.html` (bundled via
  `functions.includeFiles`), else 303 -> `/login`.
- `api/login.js`: GET renders the form; POST compares with `ADMIN_PASSWORD`
  (constant-time), rate-limits 5 tries / 15 min / IP, sets cookie
  `HttpOnly; Secure; SameSite=Strict`, 8h.
- Static output (`public/`) only holds `robots.txt`; `protected/` is never static,
  so `/protected/admin.html` is 404.
- No password or hash exists in source.

## Local test (no Vercel login needed)
```
ADMIN_PASSWORD=<dummy> SESSION_SECRET=<dummy> node dev/local-server.mjs "$PWD" &
P=<dummy> bash dev/smoke-test.sh
```

## Env vars (Vercel → Project → Settings → Environment Variables, Production + Preview)
| Name | Required | Notes |
|---|---|---|
| `ADMIN_PASSWORD` | yes | new strong password (≥ 20 chars). Never the old one. |
| `SESSION_SECRET` | yes | random ≥ 32 bytes, e.g. `openssl rand -base64 48`. Rotate to log everyone out. |
| `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` | optional | global rate limiting (otherwise per-instance best-effort). |

## Vercel settings checklist (project savior-j1fq)
1. Settings -> Build & Deployment -> **Root Directory = `admin`** (no leading slash).
   "Include files outside the root directory" may stay on; not needed.
2. **Framework Preset = Other.** Build Command / Install Command / Output Directory:
   leave override toggles OFF (vercel.json sets `outputDirectory: public`).
3. **Node.js Version = 20.x, 22.x or 24.x** (24.x currently set - fine).
4. Environment Variables: `ADMIN_PASSWORD`, `SESSION_SECRET` set for **Production
   and Preview** (and the `feature/phase1` branch if scoped), marked Sensitive.
   Redeploy after adding/changing env vars.
5. Deployment Protection: Vercel Authentication ON ("All Deployments" or
   "Standard"). Note: `savior-j1fq.vercel.app` production alias is also behind it
   with current setting `all_except_custom_domains`.
6. Git -> Production Branch: currently deployments from `feature/phase1` are
   **production** targets; set it to the branch you intend (e.g. keep feature/phase1
   for this admin-only project, or main later).
7. Ignored Build Step (optional): `git diff --quiet HEAD^ HEAD -- .` so only admin/
   changes redeploy.
8. After deploy: `/` -> 303 `/login`; `/protected/admin.html` -> 404;
   Functions tab lists `api/panel`, `api/login`, `api/logout`.

## Note
The panel only builds transactions; on-chain authority remains the owner wallet.
Hiding the UI is defence in depth, not the contract's access control.
