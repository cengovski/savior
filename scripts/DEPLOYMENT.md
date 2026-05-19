# Deployment Rehberi (Foundry)

## 1. Hazırlık
```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts --no-git
forge install uniswap/v4-core uniswap/v4-periphery
```

## 2. .env
```
PRIVATE_KEY=0x...
BASE_RPC=https://mainnet.base.org
ETHERSCAN_API_KEY=...
```

## 3. Deploy Sırası (önerilen)
1. SaviorToken deploy
2. SaviorHook deploy (HookMiner ile)
3. VaultFactory deploy (token, poolManager, hook, treasury adresleriyle)
4. Pool oluştur (PoolManager + initialize + hook)
5. Initial liquidity ekle (PositionManager ile 1B SAVIOR + 0 ETH)
6. Siteyi güncelle (kontrat adreslerini frontend'e ekle)

HookMiner kullanımı için Uniswap docs'a bakın.

Detaylı script için `Deploy.s.sol` yazılabilir.