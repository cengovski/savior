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
