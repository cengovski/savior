# SAVIOR Admin (protected, separate Vercel project)

The admin panel is **no longer part of the public site** (root `admin.html` and
`docs/admin.html` were removed; root `.vercelignore` excludes `admin/`).
It is deployed as its own Vercel project with Root Directory = `admin/`.

## How auth works
- `middleware.js` (Vercel Routing Middleware) redirects every request without a
  valid session cookie to `/login`.
- `POST /api/login` compares the submitted password with `ADMIN_PASSWORD`
  (constant-time), rate-limits (5 tries / 15 min / IP), and sets
  `__Host-savior_admin` = HMAC-SHA256 signed token (`HttpOnly; Secure; SameSite=Strict`, 8h).
- `/` is rewritten to `api/panel.js`, which re-verifies the cookie and returns
  `protected/admin.html` (not in `public/`, so never a static asset).
- No password or hash exists in source.

## Env vars (Vercel → Project → Settings → Environment Variables, Production + Preview)
| Name | Required | Notes |
|---|---|---|
| `ADMIN_PASSWORD` | yes | new strong password (≥ 20 chars). Never the old one. |
| `SESSION_SECRET` | yes | random ≥ 32 bytes, e.g. `openssl rand -base64 48`. Rotate to log everyone out. |
| `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` | optional | global rate limiting (otherwise per-instance best-effort). |

## Setup
1. Vercel → Add New Project → import `cengovski/savior`, Root Directory `admin`, Framework "Other".
2. Set env vars above. Mark them Sensitive.
3. Enable Deployment Protection (Vercel Authentication) for Preview deployments.
4. Optional: Firewall → rate-limit rule on `/api/login`; optional custom domain `admin.<domain>`.
5. Deploy; verify `/` redirects to `/login` when logged out, and `/protected/admin.html` 404s.

## Note
The panel only builds transactions; on-chain authority remains the owner wallet.
Hiding the UI is defence in depth, not the contract's access control.
