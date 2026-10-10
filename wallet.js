/**
 * wallet.js, Shared wallet connector
 * Supports: MetaMask, Coinbase, Rainbow, Trust, Brave, any EIP-1193 injected wallet,
 *           and WalletConnect v2 (300+ wallets via QR/deep link)
 *
 * Usage:
 *   await WalletConnector.connect()   → opens picker modal
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
    let _provider = null;
    let _signer   = null;
    let _address  = null;
    let _rawProvider = null;
    const _listeners = { connect: [], disconnect: [], accountsChanged: [] };

    function emit(event, data) {
        (_listeners[event] || []).forEach(fn => { try { fn(data); } catch(e) {} });
    }

    function on(event, fn) { (_listeners[event] = _listeners[event] || []).push(fn); }

    // ── Discover injected wallets via EIP-6963 ────────────────────────
    function getInjectedWallets() {
        const wallets = [];
        // EIP-6963 announced providers
        if (window.__eip6963Providers) {
            for (const [, p] of window.__eip6963Providers) wallets.push({ name: p.info.name, icon: p.info.icon, provider: p.provider });
        }
        // Legacy window.ethereum (MetaMask compatible)
        if (window.ethereum && wallets.length === 0) {
            const name = window.ethereum.isMetaMask ? 'MetaMask' :
                         window.ethereum.isCoinbaseWallet ? 'Coinbase Wallet' :
                         window.ethereum.isBraveWallet ? 'Brave Wallet' :
                         window.ethereum.isTrust ? 'Trust Wallet' : 'Browser Wallet';
            wallets.push({ name, icon: null, provider: window.ethereum });
        }
        // Multi-provider (window.ethereum.providers array)
        if (window.ethereum?.providers?.length > 0) {
            wallets.length = 0;
            for (const p of window.ethereum.providers) {
                const name = p.isMetaMask ? 'MetaMask' :
                             p.isCoinbaseWallet ? 'Coinbase Wallet' :
                             p.isBraveWallet ? 'Brave Wallet' :
                             p.isTrust ? 'Trust Wallet' : 'Injected Wallet';
                wallets.push({ name, icon: null, provider: p });
            }
        }
        return wallets;
    }

    // EIP-6963 listener
    window.addEventListener('eip6963:announceProvider', (e) => {
        if (!window.__eip6963Providers) window.__eip6963Providers = new Map();
        window.__eip6963Providers.set(e.detail.info.uuid, e.detail);
    });
    window.dispatchEvent(new Event('eip6963:requestProvider'));

    // ── Switch / add Arc Mainnet ──────────────────────────────────────
    async function ensureArcTestnet(rawProvider) {
        const isArc = async () => String(await rawProvider.request({ method: 'eth_chainId' })).toLowerCase() === ARC_TESTNET_PARAMS.chainId.toLowerCase();
        if (await isArc()) return;
        try {
            await rawProvider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: ARC_TESTNET_PARAMS.chainId }] });
        } catch (e) {
            // 4902 = unknown chain. Mobile wallets over WalletConnect often return other codes, so try adding Arc anyway.
            if (e && (e.code === 4001 || /reject|denied/i.test(e.message || ''))) throw new Error('Network switch rejected. Please switch to Arc Mainnet (chain 5042).');
            await rawProvider.request({ method: 'wallet_addEthereumChain', params: [ARC_TESTNET_PARAMS] });
            try { await rawProvider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: ARC_TESTNET_PARAMS.chainId }] }); } catch (_) {}
        }
        if (!(await isArc())) throw new Error('Please switch your wallet to Arc Mainnet (chain 5042) and try again.');
    }

    // ── Connect with a specific raw provider ─────────────────────────
    async function connectWithProvider(rawProvider) {
        await rawProvider.request({ method: 'eth_requestAccounts' });
        await ensureArcTestnet(rawProvider);

        _rawProvider = rawProvider;
        _provider    = new ethers.BrowserProvider(rawProvider);
        _signer      = await _provider.getSigner();
        _address     = await _signer.getAddress();

        // Watch for account/chain changes
        rawProvider.on('accountsChanged', async (accounts) => {
            if (!accounts || accounts.length === 0) { disconnect(); return; }
            _signer  = await _provider.getSigner();
            _address = accounts[0];
            emit('accountsChanged', _address);
        });
        rawProvider.on('chainChanged', async () => {
            // Rebuild instead of reloading: a reload would drop a WalletConnect session.
            _provider = new ethers.BrowserProvider(rawProvider);
            try { _signer = await _provider.getSigner(); } catch (_) {}
        });
        rawProvider.on('disconnect',   () => disconnect());

        emit('connect', _address);
        return _address;
    }

    // ── WalletConnect v2 ──────────────────────────────────────────────
    // Root cause of the old mobile error ("Cannot read properties of undefined (reading 'init')"):
    // the UMD build of @walletconnect/ethereum-provider registers window["@walletconnect/ethereum-provider"],
    // never window.EthereumProvider, and its QR modal is a separate dynamic import. We now load a vendored ESM
    // bundle (provider + modal). Arc (5042) is optional, not required: wallets reject sessions that require
    // a chain they do not know yet, so we connect first and then add/switch to Arc.
    let _wcProvider = null;
    async function connectWalletConnect() {
        if (!WC_PROJECT_ID) throw new Error('WalletConnect is not configured (missing projectId).');
        const { EthereumProvider } = await import(new URL('./vendor/walletconnect.esm.js', document.baseURI).href);
        if (_wcProvider) { try { await _wcProvider.disconnect(); } catch (_) {} }
        const wcProvider = await EthereumProvider.init({
            projectId: WC_PROJECT_ID,
            optionalChains: [5042, 1],
            rpcMap: { 5042: 'https://rpc.mainnet.arc.io', 1: 'https://cloudflare-eth.com' },
            optionalMethods: ['eth_sendTransaction', 'personal_sign', 'eth_signTypedData', 'eth_signTypedData_v4',
                              'wallet_switchEthereumChain', 'wallet_addEthereumChain'],
            showQrModal: true,
            qrModalOptions: { themeMode: 'dark', explorerRecommendedWalletIds: [
                'c57ca95b47569778a828d19178114f4db188b89b763c899ba0be274e97267d96', // MetaMask
                '4622a2b2d6af1c9844944291e5e7351a6aa24cd7b23099efac1b2fd875da31a0', // Trust
                '1ae92b26df02f0abca6304df07debccd18262fdf5fe82daa81593582dac9a369', // Rainbow
            ] },
            metadata: {
                name: '$SAVIOR',
                description: 'Fair token distribution on Arc Mainnet',
                url: window.location.origin,
                icons: [new URL('logo.svg', location.origin + location.pathname.replace(/docs\/[^/]*$/, '')).href]
            }
        });
        _wcProvider = wcProvider;
        await wcProvider.connect();
        return connectWithProvider(wcProvider);
    }

    // ── Main connect(), shows picker modal ──────────────────────────
    async function connect() {
        return new Promise((resolve, reject) => {
            const injected = getInjectedWallets();
            showPickerModal(injected, async (choice) => {
                try {
                    let addr;
                    if (choice === 'wc') {
                        addr = await connectWalletConnect();
                    } else {
                        addr = await connectWithProvider(choice.provider);
                    }
                    resolve(addr);
                } catch(e) {
                    reject(e);
                }
            }, reject);
        });
    }

    function disconnect() {
        _provider = null; _signer = null; _address = null; _rawProvider = null;
        emit('disconnect');
    }

    // ── Picker modal UI ───────────────────────────────────────────────
    function showPickerModal(injected, onPick, onCancel) {
        // Remove existing modal
        const existing = document.getElementById('wc-picker-modal');
        if (existing) existing.remove();

        const overlay = document.createElement('div');
        overlay.id = 'wc-picker-modal';
        overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:99999;display:flex;align-items:center;justify-content:center;padding:16px;backdrop-filter:blur(6px)';

        const walletIcons = {
            'MetaMask':        '🦊',
            'Coinbase Wallet': '🔵',
            'Rainbow':         '🌈',
            'Trust Wallet':    '🛡️',
            'Brave Wallet':    '🦁',
            'Browser Wallet':  '🌐',
        };

        const injectedHTML = injected.map((w, i) => `
            <button onclick="window.__wcPickerPick(${i})"
                style="width:100%;display:flex;align-items:center;gap:12px;padding:14px 16px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);border-radius:14px;cursor:pointer;color:#fff;font-size:15px;font-weight:500;transition:background .15s"
                onmouseover="this.style.background='rgba(0,82,255,.15)'"
                onmouseout="this.style.background='rgba(255,255,255,.05)'">
                <span style="font-size:24px;width:32px;text-align:center">${walletIcons[w.name] || '💼'}</span>
                <span>${w.name}</span>
                <span style="margin-left:auto;font-size:11px;color:rgba(255,255,255,.3);background:rgba(52,211,153,.1);border:1px solid rgba(52,211,153,.2);border-radius:100px;padding:2px 8px;color:#34d399">Detected</span>
            </button>`).join('');

        overlay.innerHTML = `
            <div style="background:#0f1018;border:1px solid rgba(255,255,255,.08);border-radius:24px;padding:28px;width:100%;max-width:400px;max-height:90vh;overflow-y:auto">
                <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:20px">
                    <div>
                        <div style="font-family:'Space Grotesk',sans-serif;font-size:18px;font-weight:700;color:#fff">Connect Wallet</div>
                        <div style="font-size:12px;color:rgba(255,255,255,.4);margin-top:2px">Choose your wallet to connect</div>
                    </div>
                    <button onclick="window.__wcPickerCancel()" style="background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.1);border-radius:50%;width:32px;height:32px;cursor:pointer;color:rgba(255,255,255,.5);font-size:16px;display:flex;align-items:center;justify-content:center">&times;</button>
                </div>

                ${injected.length > 0 ? `
                <div style="font-size:11px;font-weight:600;color:rgba(255,255,255,.3);letter-spacing:.08em;text-transform:uppercase;margin-bottom:8px">Installed Wallets</div>
                <div style="display:flex;flex-direction:column;gap:8px;margin-bottom:16px">${injectedHTML}</div>` : ''}

                ${injected.length === 0 ? `<div style="font-size:12px;line-height:1.5;color:#fcd34d;background:rgba(245,158,11,.08);border:1px solid rgba(245,158,11,.25);border-radius:12px;padding:10px 12px;margin-bottom:16px">${/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent) ? 'No wallet detected in this mobile browser. Use WalletConnect below to connect MetaMask, Trust or Rainbow, or open this site inside your wallet app\'s browser.' : 'No browser wallet extension detected. Install MetaMask or another wallet, or use WalletConnect below.'}</div>` : ''}
                <div style="font-size:11px;font-weight:600;color:rgba(255,255,255,.3);letter-spacing:.08em;text-transform:uppercase;margin-bottom:8px">Other Wallets</div>
                <button onclick="window.__wcPickerPick('wc')"
                    style="width:100%;display:flex;align-items:center;gap:12px;padding:14px 16px;background:rgba(255,255,255,.05);border:1px solid rgba(255,255,255,.1);border-radius:14px;cursor:pointer;color:#fff;font-size:15px;font-weight:500;transition:background .15s"
                    onmouseover="this.style.background='rgba(0,82,255,.15)'"
                    onmouseout="this.style.background='rgba(255,255,255,.05)'">
                    <span style="font-size:24px;width:32px;text-align:center">📱</span>
                    <div style="text-align:left">
                        <div>WalletConnect</div>
                        <div style="font-size:11px;color:rgba(255,255,255,.4)">MetaMask Mobile, Trust, Rainbow, 300+ wallets</div>
                    </div>
                </button>

                <div style="margin-top:20px;padding-top:16px;border-top:1px solid rgba(255,255,255,.05);font-size:11px;color:rgba(255,255,255,.25);text-align:center">
                    Connected to Arc Mainnet · USDC gas token
                </div>
            </div>`;

        window.__wcPickerPick = (choice) => {
            overlay.remove();
            delete window.__wcPickerPick;
            delete window.__wcPickerCancel;
            if (choice === 'wc') { onPick('wc'); }
            else { onPick(injected[choice]); }
        };
        window.__wcPickerCancel = () => {
            overlay.remove();
            delete window.__wcPickerPick;
            delete window.__wcPickerCancel;
            onCancel(new Error('User cancelled'));
        };

        overlay.addEventListener('click', (e) => { if (e.target === overlay) window.__wcPickerCancel(); });
        document.body.appendChild(overlay);
    }

    return { connect, disconnect, on, get address() { return _address; }, get provider() { return _provider; }, get signer() { return _signer; }, get rawProvider() { return _rawProvider; } };
})();

window.WalletConnector = WalletConnector;
