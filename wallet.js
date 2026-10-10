/**
 * wallet.js, Shared wallet connector
 * Supports: MetaMask, Coinbase, Rainbow, Trust, Brave, any EIP-1193 injected wallet,
 *           and mobile wallets via Reown AppKit (wallet list with deep links, QR on desktop)
 *
 * Usage:
 *   await WalletConnector.connect()   → opens the AppKit modal
 *   WalletConnector.address           → current address or null
 *   WalletConnector.provider          → ethers BrowserProvider
 *   WalletConnector.signer            → ethers Signer
 *   WalletConnector.on('connect', fn)
 *   WalletConnector.on('disconnect', fn)
 *   WalletConnector.on('accountsChanged', fn)
 */

const ARC_TESTNET_PARAMS = {
    chainId: '0x13B2', // 5042, Arc Mainnet
    chainName: 'Arc',
    nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
    rpcUrls: ['https://rpc.mainnet.arc.io'],
    blockExplorerUrls: ['https://explorer.arc.io']
};

const WC_PROJECT_ID = '35a6cd36c771d9917bc693d762b4f824';

const WalletConnector = (() => {
    // Reown AppKit (vendored ESM, see vendor/README.md) with the ethers adapter.
    // AppKit lists installed wallets via EIP-6963 in their own "Installed" section, shows a wallet list on
    // mobile (each entry deep-links to that wallet), and a QR code on desktop.
    let _appKit = null, _initP = null;
    let _provider = null, _signer = null, _address = null, _rawProvider = null;
    const _listeners = { connect: [], disconnect: [], accountsChanged: [] };
    const emit = (ev, d) => (_listeners[ev] || []).forEach(fn => { try { fn(d); } catch (e) { console.error(e); } });
    const on = (ev, fn) => (_listeners[ev] = _listeners[ev] || []).push(fn);

    const FEATURED = [
        'c57ca95b47569778a828d19178114f4db188b89b763c899ba0be274e97267d96', // MetaMask
        '4622a2b2d6af1c9844944291e5e7351a6aa24cd7b23099efac1b2fd875da31a0', // Trust Wallet
        '1ae92b26df02f0abca6304df07debccd18262fdf5fe82daa81593582dac9a369', // Rainbow
        '971e689d0a5be527bac79629b4ee9b925e82208e5168b733496a09c0faed0709', // OKX Wallet
        'fd20dc426fb37566d803205b19bbc1d4096b248ac04548e3cfb6b3a38bd033aa', // Coinbase / Base
    ];

    async function sync() {
        const raw = _appKit.getWalletProvider();
        const acct = _appKit.getAccount && _appKit.getAccount();
        const addr = acct?.isConnected ? acct.address : null;
        if (raw && addr) {
            const changed = raw !== _rawProvider;
            _rawProvider = raw;
            _provider = new ethers.BrowserProvider(raw);
            try { _signer = await _provider.getSigner(); } catch (e) { _signer = null; }
            const was = _address; _address = addr;
            if (!was) emit('connect', addr);
            else if (was.toLowerCase() !== addr.toLowerCase() || changed) emit('accountsChanged', addr);
            if (Number(_appKit.getChainId && _appKit.getChainId()) !== 5042) {
                try { await _appKit.switchNetwork(_arc); } catch (e) { console.warn('switch to Arc failed', e); }
            }
        } else if (_address) {
            _address = null; _provider = null; _signer = null; _rawProvider = null;
            emit('disconnect');
        }
    }

    let _arc = null;
    function init() {
        if (_initP) return _initP;
        _initP = (async () => {
            const base = document.querySelector('script[data-site-root]')?.dataset.siteRoot || './';
            const { createAppKit, EthersAdapter, defineChain } = await import(new URL(base + 'vendor/appkit/entry.js', document.baseURI).href);
            _arc = defineChain({
                id: 5042, caipNetworkId: 'eip155:5042', chainNamespace: 'eip155', name: 'Arc Mainnet',
                nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
                rpcUrls: { default: { http: ['https://rpc.mainnet.arc.io'] } },
                blockExplorers: { default: { name: 'Arc Explorer', url: 'https://explorer.arc.io' } },
            });
            const siteUrl = location.origin + location.pathname.replace(/[^/]*$/, '');
            _appKit = createAppKit({
                adapters: [new EthersAdapter()],
                networks: [_arc], defaultNetwork: _arc, allowUnsupportedChain: false,
                projectId: WC_PROJECT_ID,
                metadata: { name: '$SAVIOR', description: 'Fair token distribution on Arc Mainnet', url: location.origin,
                            icons: [new URL(base + 'apple-touch-icon.png', siteUrl).href] },
                featuredWalletIds: FEATURED,
                enableEIP6963: true, enableInjected: true, enableCoinbase: true,
                features: { analytics: false, email: false, socials: false, swaps: false, onramp: false, send: false, history: false },
                themeMode: 'dark',
            });
            _appKit.subscribeProviders(() => sync());
            _appKit.subscribeAccount(() => sync());
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

    async function disconnect() { if (_appKit) await _appKit.disconnect(); }

    // Restore an existing session without opening the modal.
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => init().catch(e => console.error('AppKit init', e)));
    else init().catch(e => console.error('AppKit init', e));

    return { connect, disconnect, on, init,
        get address() { return _address; }, get provider() { return _provider; },
        get signer() { return _signer; }, get rawProvider() { return _rawProvider; }, get appKit() { return _appKit; } };
})();

window.WalletConnector = WalletConnector;
