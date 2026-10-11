# Admin panel hardening: decision + history-cleanup plan

## Options evaluated
**(a) Separate protected Vercel project + middleware/server login (CHOSEN)**
- Same platform already in use; no DNS move needed; preview URLs of the public
  project no longer contain admin code at all.
- Server-side password (env var), HMAC-signed HttpOnly cookie, rate limiting,
  admin HTML served only by an authenticated function.
- Can additionally enable Vercel Deployment Protection on the admin project.

**(b) Cloudflare Access / Worker on a subdomain**
- Strongest identity (SSO/email OTP, no shared password), free up to 50 users.
- Requires the domain's DNS on Cloudflare and a second hosting path. Good
  follow-up: put `admin.<domain>` behind Cloudflare Access in front of (a).

Edge Middleware inside the *public* project was rejected: admin code would still
ship with every public/preview deployment, one misconfig away from exposure.

## Plaintext password / hash in git history (DOCUMENT ONLY — not executed)
Affected: `AGENTS.md` (added in e6b16b2, contains plaintext admin password),
`admin.html` / `docs/admin.html` (SHA-256 hash constant) on main, gh-pages,
feature branches, and any forks/clones/Vercel build caches.

1. **Rotate first.** Treat the old password as compromised. Never reuse it; set a
   new `ADMIN_PASSWORD` in the new admin project. If the same password was reused
   anywhere (wallets, RPC, email), change it there too.
2. Freeze pushes; announce a time window to all collaborators.
3. Fresh mirror clone: `git clone --mirror git@github.com:cengovski/savior.git`.
4. Create `replacements.txt` locally (NOT committed) with lines
   `<old-password>==>***REMOVED***` and `<old-hash>==>***REMOVED***`.
5. `git filter-repo --invert-paths --path AGENTS.md --replace-text replacements.txt`
   (or BFG: `bfg --delete-files AGENTS.md --replace-text replacements.txt`, then
   `git reflog expire --expire=now --all && git gc --prune=now --aggressive`).
   If AGENTS.md content is still wanted, re-add a sanitized version afterwards.
6. Verify: `git log --all -p | grep -c <hash-prefix>` → 0; same for password.
7. Temporarily lift branch protection; `git push --force --mirror` (owner only).
8. Collaborators re-clone (no merging old clones). Close/recreate open PRs.
9. GitHub Support: request purge of cached views/PR refs; check forks.
10. Delete the deploy-cache: redeploy Vercel, remove old preview deployments that
    still serve admin.html; republish gh-pages without admin.html.
11. Add secret scanning / pre-commit hook (gitleaks) to prevent recurrence.

## Needs owner approval
- Merge this branch to `main`; remove `admin.html` from `gh-pages`.
- Deleting old Vercel preview deployments (they still serve /admin.html).
- History rewrite + force-push (steps above).

## Public vs admin Vercel projects
- Public project (repo root): root `vercel.json` runs `scripts/build-public.sh`,
  which copies the static site into `dist/` **excluding `admin/`**, `scripts/`,
  `*.md`; `outputDirectory: dist`. No root `api/` dir => no functions.
- Admin project (Root Directory `admin`): uses only `admin/vercel.json`; the root
  `vercel.json` is not read. Root `.vercelignore` no longer lists `admin/`
  (it was stripping admin/ from git uploads -> 404).
- GitHub Pages serves the `gh-pages` branch (separate content; still contains
  admin.html and docs/admin.html until owner removes them). admin/ is not on it.
