# vendor/

`bridge-kit.esm.js` is an esbuild ESM bundle (browser, minified) of:
- `@circle-fin/bridge-kit@1.15.2`
- `@circle-fin/adapter-ethers-v6@1.12.1` (bundles its own ethers v6)

Exports: `BridgeKit`, `createEthersAdapterFromProvider`. Lazy-loaded only when the Bridge tab is opened.
Rebuild:
```
npm i @circle-fin/bridge-kit@1.15.2 @circle-fin/adapter-ethers-v6@1.12.1 ethers@6 esbuild
printf "export { BridgeKit } from '@circle-fin/bridge-kit';\nexport { createEthersAdapterFromProvider } from '@circle-fin/adapter-ethers-v6';\n" > entry.js
npx esbuild entry.js --bundle --format=esm --platform=browser --minify --target=es2020 \
  --define:process.env.NODE_ENV='"production"' --define:global=globalThis --outfile=bridge-kit.esm.js
```
No API keys are involved: the user's wallet signs, attestation uses Circle's public Iris API.

`appkit/` is an esbuild ESM bundle (code-split, entry `appkit/entry.js`) of:
- `@reown/appkit@1.8.24`
- `@reown/appkit-adapter-ethers@1.8.24` (with ethers v6)

Exports: `createAppKit`, `EthersAdapter`, `defineChain`. Loaded on page load to restore sessions; chunks load on demand.
Rebuild:
```
npm i @reown/appkit@1.8.24 @reown/appkit-adapter-ethers@1.8.24 ethers@6 esbuild
printf "export { createAppKit } from '@reown/appkit';\nexport { defineChain } from '@reown/appkit/networks';\nexport { EthersAdapter } from '@reown/appkit-adapter-ethers';\n" > entry.js
npx esbuild entry.js --bundle --format=esm --splitting --chunk-names=chunks/[name]-[hash] --platform=browser --minify \
  --target=es2020 --define:process.env.NODE_ENV='"production"' --define:global=globalThis --outdir=appkit
```
The Reown projectId (`WC_PROJECT_ID`) is a public identifier, not a secret. Allowed origins are set in the Reown dashboard.
