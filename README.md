# $SAVIOR Token Rehberi - Uniswap V4 ile Trench'lerin Kurtarıcısı

**Repo:** https://github.com/cengovski/savior  
**Network:** Arc Mainnet (Chain ID: 5042; hex `0x13B2`)  
**Token:** $SAVIOR  
**Tema:** Trench'lerin Kurtarıcısı (Meme + Arc + Kahramanlık)

Bu dosya, eski prototip tasarımından kalan notları da içerir; canlı dağıtımın eksiksiz teknik dokümantasyonu değildir. 

Canlı kontrat adresleri ve kaynak kodları ayrıca doğrulanmalıdır; aşağıdaki örnekler canlı dağıtımla eşleştirilmiş değildir. 

> **⚠️ ÖNEMLİ UYARI:** Bu proje yüksek riskli Uniswap V4 Hook + custom Vault + timelock mekanizması içerir. Production için **mutlaka profesyonel audit** (Cantina, Spearbit, Certik vb.) yaptırın. Hook'lar çok güçlüdür, exploit riski yüksektir.


> **Durum ve güvenlik notu (19 Ekim 2026):** Yayındaki arayüz `docs/index.html` Arc Mainnet'i (Chain ID `5042`) hedefler; gas varlığı USDC'dir. Bu README içindeki Base/ETH, %48 kilit ve Vault/Hook örneklerinin bir bölümü eski prototip/skeleton tasarımdan kalmıştır. Örnek kontratlarda tamamlanmamış `TODO` ve `revert` yolları vardır; bunlar canlı uygulamanın gerçek davranışını kanıtlamaz ve production deploy için kullanılmamalıdır. Arayüzde gösterilen %50 kilit ve %2 treasury fee de yalnızca kontrat adresleri ve zincir üstü işlemler doğrulanırsa uygulanıyor kabul edilmelidir. Proje denetlenmiş olarak sunulmamaktadır. Repository'de admin panelinin gömdüğü TOKEN_BC/HOOK_BC/STAKING_BC bytecode sabitleri dışında bunlarla eşleştiği doğrulanmış Solidity kaynak dosyaları bulunmuyor; README'deki skeleton kodlar deployed bytecode'ın kaynak eşdeğeri olarak görülmemelidir. Herhangi bir işlemden önce doğru ağ, kontrat adresleri, doğrulanabilir kaynak kodu ve cüzdan imzasındaki calldata kontrol edilmelidir.

---

## 1. Token ve Proje Özeti

### Arayüzde anlatılan mekanizma (zincir üstünde ayrıca doğrulanmalı)
- Yayındaki arayüz Arc Mainnet'i (Chain ID 5042) ve USDC ↔ $SAVIOR akışını gösterir.
- Arayüz açıklaması, alımda %50 anında kullanılabilir / %50 5–10 gün kilitli dağılım ve swap başına %2 treasury ücreti olduğunu söyler. Bu metinler tek başına kontratların bu kuralları uyguladığını kanıtlamaz.
- Canlı kontrat adresleri, pool kimliği, ücret alıcısı ve kilit/claim akışı doğrulanmadan bu mekanizmaları garanti edilmiş özellikler olarak sunmayın.
- **Kişisel Kasa (Vault) Sistemi:**
  - Her alım yapan cüzdan için **otomatik / ilk seferde deploy** edilen kişisel Vault kontratı.
  - **Eski tasarım notu:** Bu örnek %48 kilit öngörür; güncel arayüzdeki %50 açıklamasıyla aynı değildir. Canlı kontratla doğrulanmadan kullanmayın.
  - Eski prototip rastgele kilit süresi amaçlar; zincir üstünde doğrulanmış davranış değildir.
  - Hedef tasarımda claim yalnızca sahibi tarafından yapılır; canlı kontratla doğrulanmalıdır.
  - Bu enforce iddiası, verilen skeleton kodla doğrulanmış değildir; canlı hook/pool kodu ve başarılı/başarısız swap testleri gerekir.
- **Ücret:** Arayüz %2 treasury fee gösterir. Aşağıdaki eski örnek kod bu davranışın canlı kontratta uygulandığını kanıtlamaz.
  - Treasury: set explicitly at deployment after independent verification; the old hard-coded address is not authoritative.
- **Pool kısıtlaması:** Diğer havuzlarda işlem yapılamayacağı iddiası, token transferleri ve hook davranışı zincir üzerinde test edilmeden doğrulanmış sayılmaz.
- **Site (GitHub Pages):** 
  - Arc Mainnet hedefli arayüz; eski Base temalı kopyalar prototip kalıntısıdır.
  - USDC ↔ $SAVIOR arayüzü (slippage ayarlanabilir).
  - Bağlanan cüzdanın Vault kontrat(lar)ı listesi + unlock countdown + Claim butonu.
  - Arayüzdeki likidite/kontrat araçları yalnızca doğru Arc kontrat adresleriyle ayrıca doğrulanmalıdır.
  - Arc Mainnet RPC yapılandırması.

### Tokenomics (Önerilen)
- Arayüzün gösterdiği hedef dağılım: %50 anında kullanılabilir, %50 5–10 gün kilitli.
- Arayüzün gösterdiği hedef ücret: swap başına %2 treasury fee.
- Toplam arz, likidite dağılımı ve ücret uygulaması canlı kontrat verileriyle doğrulanmadı; bu değerleri doğrulanmış tokenomics olarak kabul etmeyin.

---

## 2. Eski prototip mimarisi (canlı dağıtımın kanıtı değildir)

```
Kullanıcı (Cüzdan)
    ↓ (Vault üzerinden)
Vault (Kişisel, CREATE2 deterministic) 
    ├── buy() → PoolManager.swap() + %48 lock + %2 fee hook
    ├── sell() → unlock kontrolü + swap
    └── claim() → unlocked token'ları cüzdana çek
          ↓
SaviorHook (V4 Hook)
    ├── afterSwap: %2 fee → Treasury
    └── (lock mantığı Vault'ta centralized)
          ↓
Uniswap V4 Pool (Arc Mainnet — only if verified/deployed) + PositionManager
          ↓
SaviorToken (ERC20)
```

### Ana Kontratlar
1. **SaviorToken.sol** - Standart ERC20 (mintable, initial supply pool için)
2. **VaultFactory.sol** - CREATE2 ile deterministic Vault deploy (her cüzdan için 1 tane)
3. **Vault.sol** - Ownable, lock/claim/swap fonksiyonları. Alım-satım burada enforce edilir.
4. **SaviorHook.sol** - Uniswap V4 IHooks implementasyonu. Fee + swap event'leri. (Lock Vault'ta)
5. **(Opsiyonel) SaviorRouter.sol** - Eğer swap logic'ini hook'tan ayırmak isterseniz.

**Önemli:** Bu bölüm eski Base/ETH prototipine ait örnek/skeleton koddur; canlı Arc arayüzünün kullandığı kontratlarla eşleştiği doğrulanmamıştır. Tam V4 entegrasyonu (delta, settle, tick vs.) için `@uniswap/v4-core` ve `@uniswap/v4-periphery` kullanın. Bu rehberde **ana logic + skeleton** verilmiştir. Ajan bunu genişletebilir.

---

## 3. Akıllı Kontratlar (Tam Kod + Skeleton)

### 3.1 contracts/SaviorToken.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SaviorToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("$SAVIOR", "SAVIOR") Ownable(initialOwner) {}

    // Match the admin deployment flow (which mints using 6-decimal units).
    // Verify this source matches the published bytecode before any deployment.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // İleride transfer hook eklenebilir (sadece belirli pool'lardan izin)
    // Şimdilik standart ERC20 - enforcement hook + vault ile sağlanır.
}
```

### 3.2 contracts/Vault.sol (Kişisel Kasa)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable saviorToken;
    address public immutable factory;
    address public immutable poolManager;
    address public immutable saviorHook;
    address public immutable treasury;

    struct Lock {
        uint256 amount;
        uint256 unlockTime;
        bool claimed;
    }

    Lock[] public locks;
    uint256 public totalLocked;

    event Locked(address indexed user, uint256 amount, uint256 unlockTime);
    event Claimed(address indexed user, uint256 amount);

    constructor(
        address _owner,
        address _saviorToken,
        address _poolManager,
        address _saviorHook,
        address _treasury
    ) Ownable(_owner) {
        saviorToken = IERC20(_saviorToken);
        factory = msg.sender;
        poolManager = _poolManager;
        saviorHook = _saviorHook;
        treasury = _treasury;
    }

    // Alım için ana fonksiyon (swap + otomatik %48 lock)
    function buy(uint256 ethAmount, uint256 minSaviorOut, uint256 slippageBps) external payable onlyOwner {
        require(msg.value == ethAmount, "ETH mismatch");
        // TODO: V4 PoolManager ile swap çağrısı yap (delta, settle, quoter ile minOut kontrol)
        // Örnek: IPoolManager(poolManager).swap(...);
        // Swap sonrası alınan SAVIOR miktarını al (event veya return ile)

        uint256 saviorReceived = /* swap sonucundan gelen miktar */;
        require(saviorReceived >= minSaviorOut, "Slippage");

        uint256 lockAmount = (saviorReceived * 48) / 100;
        uint256 userAmount = saviorReceived - lockAmount;

        // %2 fee zaten hook'ta treasury'ye gidiyor (opsiyonel burada da eklenebilir)

        if (lockAmount > 0) {
            _lock(lockAmount);
        }
        if (userAmount > 0) {
            saviorToken.safeTransfer(owner(), userAmount);
        }
    }

    // Satım için (sadece unlocked veya policy'ye göre)
    function sell(uint256 saviorAmount, uint256 minEthOut) external onlyOwner {
        // TODO: unlocked kontrolü + V4 swap (SAVIOR -> ETH)
        // Basit implementasyon: unlocked miktar kontrolü eklenebilir
        revert("Sell implementation required with V4 integration");
    }

    function _lock(uint256 amount) internal {
        // 5-10 gün arası rastgele (tx anında belirlenir, simüle edilemez)
        uint256 randomDays = 5 + (uint256(keccak256(abi.encode(block.prevrandao, block.timestamp, msg.sender, locks.length))) % 6);
        uint256 unlockTime = block.timestamp + (randomDays * 1 days);

        locks.push(Lock(amount, unlockTime, false));
        totalLocked += amount;

        saviorToken.safeTransferFrom(msg.sender, address(this), amount); // veya swap sonrası balance
        emit Locked(owner(), amount, unlockTime);
    }

    function claim() external onlyOwner {
        uint256 claimable = 0;
        for (uint i = 0; i < locks.length; i++) {
            if (!locks[i].claimed && block.timestamp >= locks[i].unlockTime) {
                claimable += locks[i].amount;
                locks[i].claimed = true;
            }
        }
        require(claimable > 0, "Nothing to claim");
        totalLocked -= claimable;
        saviorToken.safeTransfer(owner(), claimable);
        emit Claimed(owner(), claimable);
    }

    // View fonksiyonları (frontend için)
    function getLocks() external view returns (Lock[] memory) {
        return locks;
    }

    function getClaimableAmount() external view returns (uint256) {
        uint256 claimable = 0;
        for (uint i = 0; i < locks.length; i++) {
            if (!locks[i].claimed && block.timestamp >= locks[i].unlockTime) {
                claimable += locks[i].amount;
            }
        }
        return claimable;
    }

    // Fallback: Sadece owner ETH çekebilir (gerekirse)
    receive() external payable {}
    fallback() external payable {}
}
```

### 3.3 contracts/VaultFactory.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vault} from "./Vault.sol";

contract VaultFactory {
    mapping(address => address) public userVault;
    address public immutable saviorToken;
    address public immutable poolManager;
    address public immutable saviorHook;
    address public immutable treasury;

    event VaultCreated(address indexed user, address vault);

    constructor(address _saviorToken, address _poolManager, address _saviorHook, address _treasury) {
        saviorToken = _saviorToken;
        poolManager = _poolManager;
        saviorHook = _saviorHook;
        treasury = _treasury;
    }

    function deployVault() external returns (address) {
        require(userVault[msg.sender] == address(0), "Vault already exists");

        // CREATE2 deterministic address
        bytes32 salt = keccak256(abi.encodePacked(msg.sender));
        Vault vault = new Vault{salt: salt}(
            msg.sender,
            saviorToken,
            poolManager,
            saviorHook,
            treasury
        );

        userVault[msg.sender] = address(vault);
        emit VaultCreated(msg.sender, address(vault));
        return address(vault);
    }

    function getVault(address user) external view returns (address) {
        return userVault[user];
    }

    // Predict address before deploy
    function predictVaultAddress(address user) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(user));
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(Vault).creationCode,
                abi.encode(user, saviorToken, poolManager, saviorHook, treasury)
            ))
        ));
        return address(uint160(uint256(hash)));
    }
}
```

### 3.4 contracts/SaviorHook.sol (V4 Hook Skeleton)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract SaviorHook is IHooks {
    address public immutable treasury;
    uint256 public constant FEE_BPS = 200; // %2

    constructor(address _treasury) {
        treasury = _treasury;
    }

    // Hook izinleri (deploy öncesi HookMiner ile hesapla)
    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // İsteğe bağlı: swap öncesi kontroller (sadece vault'tan gelsin vs.)
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        // %2 fee hesapla ve treasury'ye gönder (delta'dan veya hook balance'dan)
        // Gerçek implementasyon: delta.amount0() / amount1() üzerinden fee al
        // Örnek basit: 
        // uint256 fee = ... 
        // IPoolManager(msg.sender).take(key.currency0, treasury, fee); veya donate

        return (IHooks.afterSwap.selector, 0);
    }

    // Diğer fonksiyonlar boş bırakılabilir veya revert
}
```

**Hook Deployment Notu:** `Hooks` kütüphanesinden flag'leri encode et. Adresin son 2-3 byte'ı izinleri temsil etmeli (HookMiner kullan).

### 3.5 Deployment Script Önerisi (Foundry)

`scripts/Deploy.s.sol` oluşturun.

---

## 4. Frontend / GitHub Pages Sitesi

Site tamamen statik (Tailwind + Vanilla JS + Ethers.js). `docs/index.html` olarak koyun ve GitHub Pages'i `/docs` klasöründen yayınlayın.

**Tasarım:**
- Dark tema, Arc temalı renk paleti.
- Hero: Yukarıda generate edilen görsel + "$SAVIOR - Trench'lerin Kurtarıcısı" başlığı.
- Navbar: Logo, Connect Wallet, RPC Selector (5 public + custom).
- Swap Sekmesi: USDC ↔ $SAVIOR, slippage inputu (0.1% - 5%), Swap butonu (Vault üzerinden).
- My Vaults: Vault adresi, toplam kilitli, claimable, locks listesi + countdown (JS interval) + Claim butonları.
- Add Liquidity: Slider + anlık hesaplama (mock veya V4 SDK ile).
- Footer: Contracts, Treasury, Socials, Audit badge placeholder.

**Teknik:**
- Ethers.js v6 CDN
- Tailwind via play CDN
- Base RPC'ler:
  1. https://mainnet.base.org
  2. https://base.publicnode.com
  3. https://1rpc.io/base
  4. https://base-mainnet.g.alchemy.com/public
  5. https://go.getblock.us/be0a835176364ef5929d64c12c4a3597 (veya güncel)

Tüm frontend kodu `docs/index.html` dosyasında.

---

## 5. Adım Adım Deployment (Foundry + Node)

1. Foundry kur: `curl -L https://foundry.paradigm.xyz | bash`
2. `forge init` veya bu repoyu klonla.
3. `.env` oluştur: `PRIVATE_KEY=...` `BASE_RPC=...`
4. Token deploy et.
5. Hook deploy et (HookMiner ile adres hesapla → izinleri encode et).
6. Pool oluştur (`PoolManager.initialize` + hook).
7. Initial liquidity ekle (PositionManager ile 0 ETH / 1B SAVIOR full range veya wide tick).
8. VaultFactory deploy et.
9. Siteyi `docs/` klasörüne koy, GitHub Pages aktif et (Settings → Pages → Deploy from branch → /docs).

Detaylı script'ler `scripts/` klasöründe genişletilebilir.

---

## 6. Güvenlik, Audit ve Riskler

- **V4 Hook Riskleri:** En yüksek risk burada. Reentrancy, delta manipulation, hook bypass, sandwich + lock time manipulation.
- **Vault Ownership:** Sadece owner çağırabilir → iyi.
- **Rastgelelik:** `block.prevrandao` + `keccak` yeterince iyi (önceden tahmin zor).
- **Fee:** Sadece hook'tan treasury'ye.
- **Centralization:** Deploy sonrası owner renounce edilebilir (mint, vs.).
- **Audit Tavsiyesi:** Mutlaka yaptır. Hook + custom swap flow kritik.
- **Test:** Foundry ile unit + fork test (Arc Mainnet'e uygun test/fork ortamı).

---

## 7. Nasıl Kullanılır? (Kullanıcı Akışı)

1. Siteye gir → Connect Wallet; ağ Arc Mainnet (Chain ID 5042) olmalı.
2. RPC seç veya custom gir.
3. İlk alım için: "Deploy My Vault" butonuna bas (bir kere gas ödersin).
4. Swap arayüzünden ETH gir, slippage ayarla → Swap (Vault otomatik lock yapar).
5. My Vaults sekmesinden kilitli miktarları ve countdown'ları gör.
6. Unlock olunca Claim ile token'ları cüzdanına çek.
7. Likidite eklemek istersen Add Liquidity panelini kullan.

---

## 8. Sonraki Adımlar (Ajan İçin)

Bu README + contracts/ + docs/index.html dosyalarını ajanına ver. Ajan şunları yapmalı:

- Foundry ile tam compile + test.
- Gerçek V4 swap entegrasyonu tamamla (delta handling, quoter, exactInput vs.).
- Frontend'de ethers ile tam VaultFactory + Vault + Pool interaksiyonu.
- Slider + anlık reserve/price hesabı (V4 SDK veya subgraph).
- GH Pages yayını.
- Ekstra: Event indexer (The Graph veya basit), çoklu lock görselleştirme, mobil responsive.

Başarılar! Trench'leri kurtar 🛡️💎

Herhangi bir soru için issue aç veya bu rehberi güncelle.

**License:** MIT (kontratlar için)