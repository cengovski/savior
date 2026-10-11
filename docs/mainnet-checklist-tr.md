# SAVIOR Fresh Start: Mainnet Deploy Kontrol Listesi (Admin panel, "Fresh start" sekmesi)

Kural: Her adımda panel önce on-chain doğrular, sonra eth_call simülasyonu yapar, sonra cüzdan imzası ister. Simülasyon veya doğrulama satırlarında "BAD" görürsen DURDUR, imzalama.

## 0. Ön koşullar
- [ ] Cüzdan: deployer `0x7185d50557040047A142aEadA95e41C4b31720e7` (başka adresle tüm adımlar kapalı kalır).
- [ ] Deployer'da gas için yeterli native USDC: en az ~5 USDC (6. adım tek tx ~6.4M gas; diğerleri küçük). Ücretli NFT mint planlıyorsan distributor ön fonu için ek USDC.
- [ ] SAVIOR: yeni token 1. adımda 1.000.000.000 SAVIOR olarak tamamı deployer'a basılır. 2. adımdan önce deployer bakiyesi tam arz olmalı; 6. adım bitene kadar SAVIOR transferi YAPMA (panel engeller).
- [ ] Logo URI hazır (ipfs://...).
- [ ] Ağ: Arc mainnet (chainId 5042). Panel adresi doğru (production admin), ethers yerel dosyadan SRI ile yükleniyor.
- [ ] Panel artifact'i son commit ile aynı (feature/lucky-nft); "Reset local state" sadece yeni kuruluma başlarken.

## 1. Token
- [ ] logoURI gir, "Simulate + deploy token".
- [ ] Kontrol: codehash = artifact, owner = deployer, totalSupply = 1.000.000.000, deployer bakiyesi = tam arz.

## 2. Factory (FreshDeployer)
- [ ] "Simulate + deploy factory". Adres SADECE bu tx receipt'inden alınır.
- [ ] Kontrol: codehash = artifact, admin/token/usdc/poolManager/treasury/fee 10000/tickSpacing 200/positionManager/permit2 OK, stakingCodeHash = artifact, expectedLadderAmount = tam arz, expectedSqrtPrice = sabit tablo.
- [ ] Factory adresini ve tx hash'ini not al.

## 3. Lucky NFT: OpenSea koleksiyonu + LuckyDistributor
OpenSea Studio (Arc) ayarları:
- [ ] Koleksiyonu DEPLOYER cüzdanıyla oluştur (ERC721SeaDrop drop).
- [ ] Public mint stage KAPALI, signed/allowlist stage OpenSea'de AÇMA (kimse doğrudan mint edemesin).
- [ ] maxSupply belirle (beklenen kazanan sayısından büyük; örn. 10.000).
- [ ] Koleksiyon adresini panele yapıştır. Panel kontrol eder: OpenSea ERC721SeaDropCloneable klonu, owner = deployer.
- [ ] Mint fiyatı: 0 önerilir (ön fon gerekmez). >0 ise distributor'a native USDC ön fon gönder (fiyat x beklenen kazanç), %10 OpenSea ücreti dahil.
- [ ] maxTotalMintableByWallet yeterince büyük (varsayılan 1.000.000; distributor tek cüzdan, tüm kazançları o basar).
- [ ] "Verify collection + simulate + deploy distributor".
- [ ] Kontrol: distributor.staking = factory.predictStaking(), seaDrop, nft, feeRecipient (OpenSea), owner = deployer, codehash = artifact.

## 4. SeaDrop ayarı
- [ ] Payout adresini gir (boşsa deployer), "Simulate + configure" (en fazla 3 tx: allowlist root, payout, fee recipient).
- [ ] Kontrol: allowlist root = distributor.allowListLeaf(), payout set, OpenSea fee recipient izinli, public stage kapalı, allowlist stage aktif, maxSupply > basılan.
- [ ] Uyarılar: signer tanımlıysa OpenSea'de signed stage olmadığını doğrula; fiyat >0 ise ön fon yeterli mi.

## 5. Approve
- [ ] "Simulate + approve" (miktar = factory.expectedLadderAmount).
- [ ] Kontrol: allowance = ladder miktarı, deployer bakiyesi = ladder miktarı (eşit değilse 6. adım kapalı).

## 6. Hook salt + deploy (tek tx)
- [ ] "Mine salt in browser" (veya hazır salt yapıştır) ve "Verify salt": isValidHookSalt = true, hook adresi 0x...2080 ile biter.
- [ ] "Simulate + deploy all". Panel yerel ladder hash ve başlangıç fiyatı factory ile eşleşmezse imzalamaz.
- [ ] Simülasyon çıktısında staking, hook, başlangıç tick ve luckySink = distributor gör, sonra imzala.

## 7. Doğrulama (Verify deployment)
- [ ] staking = predictStaking, hook flags 0x2080, codehash'ler = artifact, hook.staking/initializer doğru, staking.owner = deployer, luckySink = distributor.
- [ ] 20 ladder NFT basıldı, hepsi deployer'da, 20/20 tick + likidite sabit tabloyla aynı.
- [ ] PoolManager SAVIOR ~ ladder miktarı, factory SAVIOR = 0. Deployer'da ~1.000 SAVIOR toz kalması normal.
- [ ] "Lucky NFT" bölümünde "Check drop config": tüm satırlar OK, uyarı yok (veya bilinçli kabul).

## 8. Site ayarı
- [ ] Sitenin config'ine yeni adresleri gir: TOKEN, STAKING, HOOK, PoolKey (currency0/1, fee 10000, tickSpacing 200, hooks), LuckyDistributor, NFT koleksiyonu, factory (bilgi).
- [ ] ABI'ler: staking-v2/abi/fresh/*.json. Eski staking/token adreslerini sitede "legacy" olarak işaretle.
- [ ] Site akışı: buy sonrası ikinci tx ile reveal (pencere ~8191 blok, ~70 dk), claim auto-reveal, kazanana claimNFT butonu.

## 9. İlk küçük gerçek test (Arc USDC davranışı)
- [ ] Ayrı bir cüzdandan ~1 USDC alım (minOut > 0): SAVIOR'un %50'si kilitlenir, %0.3 treasury'ye gider.
- [ ] Reveal yap; kilit süresi 5 ile 10 gün arası çıkmalı.
- [ ] ~10 USDC alım: lock "Lucky eligible" olmalı (panel Locks viewer). Kazanç çıkarsa distributor reserved/claimNFT akışını dene.
- [ ] Küçük bir satış: USDC cüzdana gelmeli (native USDC, 6 decimal ERC20 görünümü).
- [ ] "Collect fees" ile fee'lerin göründüğünü kontrol et.

## 10. Acil durum / geri dönüş
- Kontratlar değiştirilemez (proxy yok). Hata durumunda: yeni token/factory ile baştan kur, siteyi eski adreslere geri çevir.
- Acil kilit açma: "Schedule" sonra 48 saat bekle, "Execute" (tüm lock'lar claim edilebilir olur, geri alınamaz). Execute'tan önce "Cancel" mümkün.
- Likidite: 20 NFT deployer'da, kilit veya multisig yok; gerekirse sahibi likiditeyi çekebilir (kabul edilmiş risk).
- NFT tarafı hiçbir zaman reveal'ı bloklamaz; mint başarısızsa owed kaydı kalır, panelden "retryMint" ile tekrar denenir.
- 6. adım revert ederse hiçbir şey yarım kalmaz (tek tx). Factory tekrar kullanılabilir; salt/approve kontrol edip tekrar dene.
- Adım sırasında hata: panel "Refresh on-chain state" ile durumu yeniden okur; localStorage silinse bile adresler tx receipt'lerinden doğrulanır.
