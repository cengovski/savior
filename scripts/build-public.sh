#!/usr/bin/env bash
# Build the PUBLIC static site into dist/, excluding the admin project and
# repo-internal files. Used by the root vercel.json (public Vercel project only;
# the admin project has Root Directory=admin and uses admin/vercel.json).
set -euo pipefail
rm -rf dist && mkdir dist
tar -cf - \
  --exclude=./dist --exclude=./.git --exclude=./admin --exclude=./scripts \
  --exclude=./node_modules --exclude=./vercel.json --exclude=./.vercelignore \
  --exclude='./*.md' --exclude=./admin.html --exclude=./docs/admin.html \
  . | tar -xf - -C dist
test -f dist/index.html
if find dist -path '*admin*' | grep -q .; then echo "admin files leaked into dist" >&2; exit 1; fi
echo "public build ok: $(find dist -type f | wc -l) files"
