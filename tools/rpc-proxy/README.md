# Arc RPC proxy (proposal, not deployed)

A free Cloudflare Worker that sits between the $SAVIOR site and the public Arc Mainnet RPCs.

## Why

Every visitor's browser currently talks to the public RPCs directly. Each one polls the head block,
reads the pool state and scans logs, so N visitors cost about N times the requests, and the official RPC
answers bursts with HTTP 429. With an edge cache, most of those reads are shared:

| Read | Edge cache | Effect |
|---|---|---|
| `eth_blockNumber` | 1 s | all visitors share one head lookup per second per edge location |
| `eth_call` at `latest` (pool state, locks via Multicall3) | 2 s | estimate and leaderboard reads are shared |
| `eth_getLogs` with a fixed `toBlock` | 24 h | history scans are served from cache after the first visitor |
| receipts / transactions by hash | 1 h | immutable once mined |

Upstream failover: `rpc.mainnet.arc.io`, then `arc-rpc.publicnode.com`, `5042.rpc.thirdweb.com` and
`arc-mainnet.drpc.org`. A 429, a 5xx or a plan-limit error moves the request to the next upstream.

Safety:
- Read-only allowlist of methods. `eth_sendRawTransaction` and anything else not listed is refused:
  wallets keep sending transactions through their own RPC.
- CORS only for `cengovski.github.io`, `savior-cengovski.vercel.app`, Vercel previews and localhost.
- Batches capped at 20 requests. An optional per-IP rate limit is sketched in `wrangler.toml`.
- No secrets. If a keyed RPC is added later, store its URL with `wrangler secret put` and never commit it.

## Cost

Cloudflare Workers free plan: 100,000 requests per day; the Cache API is included. One page view sends
roughly 60 to 80 RPC requests in its first minute after the batching changes, so the free plan covers
about 1,000 to 1,500 full visits per day. Beyond that the Workers paid plan is 5 USD per month.

## Deploy (when approved)

```
cd tools/rpc-proxy
npx wrangler login
npx wrangler deploy
```

Then add the Worker URL as the first entry of `ENDPOINTS` in `rpc.js` (keep the public RPCs after it as
fallbacks):

```js
{ url: "https://savior-arc-rpc.<account>.workers.dev", logs: true },
```

## Test locally

```
npx wrangler dev
curl -s -H 'Origin: http://localhost:8765' -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://127.0.0.1:8787
```
