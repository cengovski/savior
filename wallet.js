/**
 * wallet.js, Shared wallet connector
 * Supports: MetaMask, Coinbase, Rainbow, Trust, Brave, any EIP-1193 injected wallet,
 *           and mobile wallets via Reown AppKit (wallet list with deep links, QR on desktop)
 *
 * Networks: Arc Mainnet (5042, default) plus every bridge source chain from chains.js, so WalletConnect
 * sessions include them and the bridge can switch the wallet to the source chain.
 *
 * Usage:
 *   await WalletConnector.connect()        → opens the AppKit modal
 *   WalletConnector.address                → current address or null
 *   WalletConnector.provider               → ethers BrowserProvider (follows chain switches)
 *   WalletConnector.signer                 → ethers Signer
 *   WalletConnector.chainId                → chain id the wallet is on (number) or null
 *   await WalletConnector.switchChain(id)  → switch the wallet (AppKit switchNetwork, then
 *                                            wallet_switchEthereumChain / wallet_addEthereumChain fallback)
 *   await WalletConnector.ensureArc()      → switch back to Arc before Arc transactions
 *   WalletConnector.holdNetwork(true)      → pause the automatic switch back to Arc (used while bridging)
 *   WalletConnector.on('connect' | 'disconnect' | 'accountsChanged' | 'chainChanged', fn)
 */

const ARC_TESTNET_PARAMS = {
    chainId: '0x13B2', // 5042, Arc Mainnet
    chainName: 'Arc',
    nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
    rpcUrls: ['https://rpc.mainnet.arc.io'],
    blockExplorerUrls: ['https://explorer.arc.io']
};
const ARC_CHAIN_ID = 5042;

const WC_PROJECT_ID = '35a6cd36c771d9917bc693d762b4f824';

const WalletConnector = (() => {
    // Reown AppKit (vendored ESM, see vendor/README.md) with the ethers adapter.
    // AppKit lists installed wallets via EIP-6963 in their own "Installed" section, shows a wallet list on
    // mobile (each entry deep-links to that wallet), and a QR code on desktop.
    let _appKit = null, _initP = null;
    let _provider = null, _signer = null, _address = null, _rawProvider = null, _chainId = null;
    let _hold = 0; // > 0 while a flow (the bridge) needs the wallet on another chain
    const _listeners = { connect: [], disconnect: [], accountsChanged: [], chainChanged: [] };
    const emit = (ev, d) => (_listeners[ev] || []).forEach(fn => { try { fn(d); } catch (e) { console.error(e); } });
    const on = (ev, fn) => (_listeners[ev] = _listeners[ev] || []).push(fn);

    const FEATURED = [
        'c57ca95b47569778a828d19178114f4db188b89b763c899ba0be274e97267d96', // MetaMask
        '4622a2b2d6af1c9844944291e5e7351a6aa24cd7b23099efac1b2fd875da31a0', // Trust Wallet
        '1ae92b26df02f0abca6304df07debccd18262fdf5fe82daa81593582dac9a369', // Rainbow
        '971e689d0a5be527bac79629b4ee9b925e82208e5168b733496a09c0faed0709', // OKX Wallet
        'fd20dc426fb37566d803205b19bbc1d4096b248ac04548e3cfb6b3a38bd033aa', // Coinbase / Base
    ];

    const sourceChains = () => window.SAVIOR_BRIDGE_CHAINS || [];
    const chainInfo = (id) => (window.saviorChainById && window.saviorChainById(id)) ||
        (Number(id) === ARC_CHAIN_ID ? { id: ARC_CHAIN_ID, name: 'Arc Mainnet', native: ARC_TESTNET_PARAMS.nativeCurrency, rpc: ARC_TESTNET_PARAMS.rpcUrls, explorer: ARC_TESTNET_PARAMS.blockExplorerUrls[0] } : null);

    async function readChainId(raw) {
        try { const v = await raw.request({ method: 'eth_chainId' }); const n = Number(v); if (n) return n; } catch (_) {}
        const k = Number(_appKit && _appKit.getChainId && _appKit.getChainId());
        return k || null;
    }

    async function sync() {
        const raw = _appKit.getWalletProvider();
        const acct = _appKit.getAccount && _appKit.getAccount();
        const addr = acct?.isConnected ? acct.address : null;
        if (raw && addr) {
            const changed = raw !== _rawProvider;
            _rawProvider = raw;
            // "any": the provider keeps working across chain switches (bridge source chain, then back to Arc).
            if (changed || !_provider) _provider = new ethers.BrowserProvider(raw, 'any');
            try { _signer = await _provider.getSigner(); } catch (e) { _signer = null; }
            const was = _address; _address = addr;
            const cid = await readChainId(raw);
            const chainMoved = cid !== _chainId; _chainId = cid;
            if (!was) emit('connect', addr);
            else if (was.toLowerCase() !== addr.toLowerCase() || changed) emit('accountsChanged', addr);
            if (chainMoved) emit('chainChanged', cid);
            if (cid && cid !== ARC_CHAIN_ID && !_hold) {
                try { await _appKit.switchNetwork(_arc); }
                catch (e) { console.warn('switch to Arc failed', e); window.openNetModal && window.openNetModal((chainInfo(cid) || {}).name || ('Chain ' + cid)); }
            }
        } else if (_address) {
            _address = null; _provider = null; _signer = null; _rawProvider = null; _chainId = null;
            emit('disconnect');
        }
    }

    let _arc = null, _networks = [];
    function init() {
        if (_initP) return _initP;
        _initP = (async () => {
            const base = document.querySelector('script[data-site-root]')?.dataset.siteRoot || './';
            const { createAppKit, EthersAdapter, defineChain } = await import(new URL(base + 'vendor/appkit/entry.js', document.baseURI).href);
            const siteUrl = location.origin + location.pathname.replace(/[^/]*$/, '');
            _arc = defineChain({
                id: ARC_CHAIN_ID, caipNetworkId: 'eip155:' + ARC_CHAIN_ID, chainNamespace: 'eip155', name: 'Arc Mainnet',
                nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
                rpcUrls: { default: { http: ['https://rpc.mainnet.arc.io'] } },
                blockExplorers: { default: { name: 'Arc Explorer', url: 'https://explorer.arc.io' } },
            });
            // Bridge source chains (chains.js), so WalletConnect sessions approve them and switching works.
            const sources = sourceChains().map(c => defineChain({
                id: c.id, caipNetworkId: 'eip155:' + c.id, chainNamespace: 'eip155', name: c.name,
                nativeCurrency: c.native,
                rpcUrls: { default: { http: c.rpc } },
                blockExplorers: { default: { name: c.name + ' Explorer', url: c.explorer } },
            }));
            _networks = [_arc, ...sources];
            const chainImages = { [ARC_CHAIN_ID]: new URL(base + 'assets/logos/arc-icon.svg', siteUrl).href };
            sourceChains().forEach(c => { if (c.logo) chainImages[c.id] = new URL(base + 'assets/logos/' + c.logo, siteUrl).href; });
            _appKit = createAppKit({
                adapters: [new EthersAdapter()],
                networks: _networks, defaultNetwork: _arc, allowUnsupportedChain: false,
                chainImages,
                projectId: WC_PROJECT_ID,
                metadata: { name: '$SAVIOR', description: 'Fair token distribution on Arc Mainnet', url: location.origin,
                            icons: [new URL(base + 'apple-touch-icon.png', siteUrl).href] },
                featuredWalletIds: FEATURED,
                enableEIP6963: true, enableInjected: true, enableCoinbase: true,
                features: { analytics: false, email: false, socials: false, swaps: false, onramp: false, send: false, history: false },
                themeMode: (window.getTheme && window.getTheme()) || 'dark',
                themeVariables: {
                    '--w3m-accent': '#0073E6',
                    '--w3m-color-mix': '#00011C',
                    '--w3m-color-mix-strength': 8,
                    '--w3m-font-family': "'DM Sans', system-ui, sans-serif",
                    '--w3m-border-radius-master': '3px',
                    '--w3m-z-index': 110,
                },
            });
            window.addEventListener('savior:theme', (e) => {
                try { _appKit.setThemeMode(e.detail); _appKit.setThemeVariables({ '--w3m-accent': e.detail === 'dark' ? '#3898EC' : '#0073E6' }); } catch (_) {}
            });
            try { _appKit.setThemeVariables({ '--w3m-accent': (window.getTheme && window.getTheme()) === 'dark' ? '#3898EC' : '#0073E6' }); } catch (_) {}
            _appKit.subscribeProviders(() => sync());
            _appKit.subscribeAccount(() => sync());
            if (_appKit.subscribeNetwork) _appKit.subscribeNetwork(() => sync());
            await sync();
            return _appKit;
        })();
        return _initP;
    }

    // Opens the AppKit modal. Resolves with the address once connected, or null if the user closes it.
    // (No error is thrown on close, so there is no "connection reset" message.)
    async function connect() {
        const kit = await init();
        if (_address) { await kit.open({ view: 'Account' }); return _address; }
        await kit.open({ view: 'Connect' });
        return new Promise((resolve) => {
            const done = (v) => { clearInterval(t); resolve(v); };
            const t = setInterval(() => {
                if (_address) done(_address);
                else if (!kit.getState().open) done(null);
            }, 400);
        });
    }

    const isRejection = (e) => {
        const code = e?.code ?? e?.data?.originalError?.code ?? e?.cause?.code;
        return code === 4001 || code === 'ACTION_REJECTED' || /user (rejected|denied|cancel)|rejected the request|request rejected/i.test(String(e?.message || e?.shortMessage || ''));
    };
    const isUnknownChain = (e) => {
        const code = e?.code ?? e?.data?.originalError?.code ?? e?.cause?.code;
        return code === 4902 || code === -32603 && /chain/i.test(String(e?.message || '')) ||
            /unrecognized chain|unknown chain|not been added|not added|try adding the chain|4902/i.test(String(e?.message || ''));
    };
    async function waitForChain(raw, id, ms) {
        const end = Date.now() + ms;
        do {
            if (await readChainId(raw) === id) return true;
            await new Promise(r => setTimeout(r, 250));
        } while (Date.now() < end);
        return false;
    }

    // Switch the connected wallet to `id`. Works for injected wallets and WalletConnect: AppKit switchNetwork first
    // (it knows the session), then a direct wallet_switchEthereumChain with a wallet_addEthereumChain fallback.
    async function switchChain(id) {
        id = Number(id);
        // Pause the automatic switch back to Arc while we move the wallet elsewhere.
        if (id === ARC_CHAIN_ID) return _switchChain(id);
        _hold++;
        try { return await _switchChain(id); } finally { _hold--; }
    }
    async function _switchChain(id) {
        const kit = await init();
        const raw = _rawProvider || kit.getWalletProvider();
        if (!raw || !_address) throw new Error('Connect a wallet first.');
        if (await readChainId(raw) === id) return true;
        const info = chainInfo(id);
        const label = info ? info.name : 'chain ' + id;
        const net = _networks.find(n => Number(n.id) === id);
        let firstErr = null;
        if (net) {
            try { await kit.switchNetwork(net); }
            catch (e) { if (isRejection(e)) throw new Error('Network switch to ' + label + ' was rejected in the wallet.'); firstErr = e; }
            if (await waitForChain(raw, id, 2500)) { await sync(); return true; }
        }
        const hex = '0x' + id.toString(16);
        try {
            await raw.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] });
        } catch (e) {
            if (isRejection(e)) throw new Error('Network switch to ' + label + ' was rejected in the wallet.');
            if (!info || !isUnknownChain(e)) { firstErr = firstErr || e; }
            else {
                const params = window.saviorAddChainParams ? window.saviorAddChainParams(info)
                    : { chainId: hex, chainName: info.name, nativeCurrency: info.native, rpcUrls: info.rpc.slice(0, 1), blockExplorerUrls: [info.explorer] };
                try { await raw.request({ method: 'wallet_addEthereumChain', params: [params] }); }
                catch (e2) { if (isRejection(e2)) throw new Error('Adding ' + label + ' was rejected in the wallet.'); firstErr = e2; }
                try { await raw.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hex }] }); } catch (_) {}
            }
        }
        if (await waitForChain(raw, id, 4000)) { await sync(); return true; }
        const wc = /walletconnect/i.test(String(kit.getWalletInfo && kit.getWalletInfo()?.name || '')) || !!raw.session;
        const hint = wc ? ' If you connected with WalletConnect before this network was added, disconnect and connect again so the session includes it.' : '';
        throw new Error('Your wallet did not switch to ' + label + '.' + hint + (firstErr ? ' (' + (firstErr.shortMessage || firstErr.message || firstErr) + ')' : ''));
    }

    async function ensureArc() { return switchChain(ARC_CHAIN_ID); }
    function holdNetwork(on) { _hold = Math.max(0, _hold + (on ? 1 : -1)); }

    async function disconnect() { if (_appKit) await _appKit.disconnect(); }
    async function switchToArc() { const kit = await init(); await kit.switchNetwork(_arc); await sync(); }

    // Restore an existing session without opening the modal.
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => init().catch(e => console.error('AppKit init', e)));
    else init().catch(e => console.error('AppKit init', e));

    return { connect, disconnect, on, init, switchToArc, switchChain, ensureArc, holdNetwork,
        get address() { return _address; }, get provider() { return _provider; },
        get signer() { return _signer; }, get rawProvider() { return _rawProvider; }, get appKit() { return _appKit; },
        get chainId() { return _chainId; }, get networks() { return _networks.map(n => ({ id: Number(n.id), name: n.name })); } };
})();

window.WalletConnector = WalletConnector;
