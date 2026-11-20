# LastWin — bukti end-to-end di fork LOKAL Anvil (BSC testnet, chain 97)

Tanggal: 2026-11-20. Semua tx di bawah ini HANYA di `http://127.0.0.1:8545`
(Anvil fork dari BSC testnet). Tidak ada kunci user, tidak ada dana asli:
semua penanda tangan adalah akun default Anvil (kunci test publik).
Anvil sudah BERHENTI setelah run ini selesai (exit 0, ~72 menit) — state fork
hanya di memori, jadi semua alamat di bawah ini sudah hilang dari `127.0.0.1:8545`.
Untuk mengulang dari nol: `anvil --fork-url https://bsc-testnet.publicnode.com --fork-block-number 143811509 --chain-id 97 --port 8545`,
lalu ulangi §2–§7. Bukti yang tersisa adalah file ini + `play-result.json`.

## 0. Ringkasan hasil

| Langkah | Hasil |
| --- | --- |
| Fork OpenFour (proxy set sendiri) | ✅ Registry/Core/feeRouter baru, owner = signer = deployer |
| Deploy 4 impl LastWin | ✅ 7.427.357 gas (persis dry-run) |
| Registrasi preset 1778027615734 | ✅ setelah 1 perbaikan bug di script registrasi |
| Create token LastWin | ✅ native quote DITOLAK vault (`Vault: quote must be ERC20`) → fallback WBNB, token jadi |
| Buy 1 (creator, 0,05) | ✅ lastBuyer=creator, qualifyingBuys=1, pot naik |
| Buy 2 (buyer2, 0,05) | ✅ lastBuyer pindah ke buyer2, qualifyingBuys=2 |
| Buy kecil (creator, 0,005) | ✅ lastBuyer & qualifyingBuys TIDAK berubah |
| Time travel +419 dtk | ✅ timeLeft 0, roundEnded=true |
| Buy setelah nol via `buyByBudget` | ❌ revert `CoreErrBudgetNotExecutable` (estimasi 0) — lihat §6 |
| Buy setelah nol via `buy(token, 1)` | ✅ terima tepat 1 token (cap), migrasi terpicu, phase=Migrated |
| `settle()` | ✅ winner 90% / creator 10% TEPAT (cek saldo, bukan klaim) |
| `settle()` kedua (sweep) | ✅ bayar 0, tidak revert; sweep dust pasca-migrasi juga 90/10 tepat |

Token: `0x9fc071182F6E5f7265A0d5F361aCFd62A77d7e3c` ("LastWin Demo" / LWD,
preset 1778027615734, quote WBNB, raise 1, sale 800 jt / max 1 mld).

## 1. Lingkungan

- Anvil 1.9.0: `anvil --fork-url https://bsc-testnet.publicnode.com
  --fork-block-number 143811509 --chain-id 97 --port 8545`
  (fork dari `data-seed-prebsc-1-s1` GAGAL: node itu prune state lama,
  `eth_getStorageAt` di fork block balas `missing trie node`; publicnode
  melayani storage historis dengan benar.)
- Deployer/creator/signer Core = Anvil #0 `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
  (kunci `0xac0974…f2ff80` — kunci test publik Anvil; catatan: kunci di
  brief tugas tertulis `…f3ff80`, itu BUKAN kunci akun #0 — yang benar
  `…f2ff80`, diverifikasi dengan `cast wallet address`).
- Buyer kedua = Anvil #1 `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`.
- `forge` 1.9.0, `node` 24, `ethers` 6.17.0.

## 2. Fork OpenFour (out/fork-deployment.json tersimpan di fork-local/)

Fork Registry: `0x6c55D8EC102c5A6fD9da8bDA17296962ef2EEC6b`
Fork Core: `0x668B0Afb7d3Ca832C1ca739BfD4405B25178E9A8`
FeeRouter: `0xcdbf721Ae23D7340E90cD55251146ff3356b5979`
CreateDeployer: `0xF7144b91045C96b9300d8012b5dD2514088C79fF`
Tools: `0x73866F4409B3E236ec4ABb48C915e9D0cCd27884`
WBNB: `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`
Registry resmi `0xE5014c0616e528B0ABF7CC120A58032c1FbE7060` TIDAK PERNAH disentuh.
Preset fork: 1778027615722 / 1778027615723 / 1778027615733 (bondingV1, bondingTaxV1, stock4TaxV1).

Verifikasi: `Registry.owner()` = `Core.signer()` = deployer; preset ids di atas.

### Kendala & perbaikan (di /tmp/openfour-docs saja, bukan repo LastWin)
1. `npm run fork` gagal 2x dengan `nonce has already been used / nonce too low`
   (ethers v6 memakai ulang nonce tx sebelumnya di Anvil fork). Perbaikan:
   bungkus wallet dengan `ethers.NonceManager` (+ `wallet.address` diset
   manual karena NonceManager tidak punya `.address` sinkron) dan pin
   `--fork-block-number`. Setelah itu fork jalan penuh (±40 tx).
   File asli disimpan sebagai `fork-from-chain.js.orig`.
2. `npm install` di `fork-deploy` meletakkan `node_modules` di
   `developer/node_modules` (npm workspace) — tidak masalah, `require('ethers')` tetap jalan.

## 3. Deploy implementasi LastWin

`PRESET_ID=0 forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`

| Kontrak | Alamat | Tx hash |
| --- | --- | --- |
| LastBuyerWinsCustomData | `0x95e55Ec31667EbCDcBBAdFb30C06e22Ddb020071` | `0x1b5fde325de6795718861ad77e7f9a35109ad5636412f4f0357d0d535d564c5a` |
| LastBuyerWinsTradeModule | `0x8CE6967Bb6027b8427203f022d045BdB43382801` | `0xfc741db5c87dedbb6f8ec01b88691b488b63cb042174bb605469251c9c32f307` |
| LastBuyerWinsMigrateModule | `0xACfd55C566a1b71580c313f5142D711F95AE4807` | `0xb443eef07354d2cf25e13bd53370da2e7b8d73b02b54f74cfa31cda338739205` |
| Validator (preset 0) | `0xb3ab8132A014FF0b849cf374580Dcda7A70437F0` | `0xd6f3e6e919b1b9c2b9f4dc9f50efe567cc19269ddf7af53c856a349d212e9faf` |

Gas total 7.427.357 — sama persis dengan dry-run di `docs/VERIFICATION.md`.

## 4. Registrasi preset 1778027615734

`FORK_REGISTRY=0x6c55…E6b PRESET_ID=1778027615734 DATA_IMPL=… TRADE_IMPL=… MIGRATE_IMPL=… forge script script/RegisterForkPreset.s.sol --broadcast`

Validator baru (terikat 734): `0x03AEa62c7ae75Cb85371f1480810c20b3c9D0918`
(tx `0x17d807a0664ed9aa8058b33bb1832a1a6c2e2d9658ad7209d406096ddc4e81ba`)

| Upsert | Tx hash | Hasil on-chain |
| --- | --- | --- |
| module data `module.data.last_buyer_wins` | `0xff966d677dd33ff83575f6526998c1aab28c7fa3d9b7d8d90ac01b772dcf81a8` | beacon `0x4D5e96BA2ac0d0e8383b767d4D02Bbf3C3Bff5B1`, kind 5, active |
| module trade `module.trade.last_buyer_wins` | `0x1f2e3a9b90f05d8f13a65f0b5a4730d5321d56a8999c791fb727b135db70c8ea` | beacon `0xA28B3e95009667955c4E90aFAa19E8C0567aceEB`, kind 3, active |
| module migrate `module.migrate.last_buyer_wins` | `0x9a67f2cba46e977a2cb03a8e777d307d9412a3f8e9eb2a545d5642e930c8a951` | beacon `0xdc79036bBdEC2EbD4344E3B0c41699882c0Db419`, kind 4, active |
| preset 1778027615734 "LastBuyerWins" | `0x6beeba578af509cfb66ef14b89b38922c787df626b57489d1b443e43b3a00853` | active=true, createEnabled=true; slot token/vault/curve/tokenImpl disalin dari bondingV1 1778027615722 |

### Bug yang ditemukan & diperbaiki (di repo LastWin, BELUM di-push)
`RegisterForkPreset.s.sol` mendeklarasikan `getModule` dengan 4 nilai
balik datar — padahal Registry mengembalikan SATU struct `ModuleRecord`,
yang encoding-nya diawali satu word offset (`0x20`). Decode gagal dan
script revert tepat setelah `getModule(DATA_KEY)` (upsert sendiri sudah
sukses di simulasi, tapi tidak ada yang ter-broadcast). Bukti: `cast call`
dengan ABI 4-nilai datar → `could not decode output`, dengan ABI struct
tunggal → decode benar. Perbaikan: `getModule` sekarang mengembalikan
`IOpenFourRegistry.ModuleRecord memory` dan read-back memakai field
`.beacon` / `.active`. File yang diubah: `script/RegisterForkPreset.s.sol`.

## 5. Create token

Params: name `LastWin Demo`, symbol `LWD`, maxSupply 1.000.000.000,
saleAmount 800.000.000, raiseAmount 1, quote native dulu; customData
(initialDuration 300, extensionPerBuy 60, maxRemaining 300,
maxGameDuration 604800, minQualifyingQuote 0,01, winnerBps 9000);
trade (buyPotFeeBps 100, sellPotFeeBps 200, maxBuyAmount 0,
postRoundMaxBuy 1 token); migrate (adapter `0x0`, lpRecipient `0x…dEaD`,
tokenLiquidityAmount 0, maxQuoteToUse 0).

- Create native GAGAL di staticCall: `execution reverted: "Vault: quote must be ERC20"`.
  StandardVault fork ini hanya menerima quote ERC20 — jadi quote native
  (address(0)) TIDAK BISA dipakai dengan preset bonding ini. Ini menjawab
  sebagian open question #1 di README: pot fee mengalir sebagai quote ERC20.
- Fallback WBNB (wrap 2 BNB, approve Core): create sukses.
  Create tx: `0xab632eb73c245066db5d076681a4c5bc78bc67179b7f851d5c01673c0ffac7eb`
- `tokens(token)`: exists=true, presetId 1778027615734, vault
  `0x71304756B4c072D570820Cf148A2801F371447Da`, curve
  `0x1Db43E05D89784F788C72408259C85bCCd8099c4`, trade
  `0x4cC42e104aC8FAa8d5815f0041c3EEDdD2f6eaf1`, migrate
  `0x86feEDC53Bf98235Db1A1EB9f9efCE15c6955603`, tokenModule
  `0xdDDFAeD503F2B17B61f63B786963eAaB2adD95Bf`, customData
  `0x6B3d5B8bE73884578b9A88816AfdC0682FDAf616` (tag `module.data.last_buyer_wins` ✓),
  phase Trading (1), remainingForSale 800.000.000, totalRaised 0.
- `gameState()` saat create: deadline = create+300, timeLeft 300,
  lastBuyer `0x0`, qualifyingBuys 0, pot 0, potErc20 = WBNB.

## 6. Permainan (gameState lengkap ada di play-result.json)

Semua buy via `Core.buyByBudget` (quote WBNB; harga gas 0 di Anvil
sehingga delta saldo = nilai trade persis). Pot fee = 1% dari curveQuote
per buy; totalFee di estimasi = 2% (1% pot + 1% protocol/dev fee).

| Langkah | Tx | gameState sesudahnya |
| --- | --- | --- |
| Buy 1 — creator 0,05 | `0x94aecd0e2a78ef67d828c06862a9819f1785748ac6616ee04b455b4299897daa` | lastBuyer=creator, qualifyingBuys=1, timeLeft 300 (deadline +60, cap now+300), pot 0,000490196006078681 WBNB, terima 134.476.826,5 LWD, vault totalRaised 0,0490196 |
| Buy 2 — buyer2 0,05 (didahului wrap 2 WBNB + approve; tx deposit `0x256783ec…`, approve `0x08c1557a…`) | `0xe29c2a30cde8188d4e1eb0e3ecfa20fcdfdddabc0d6929f3e59be0f2845b5125` | lastBuyer=buyer2 `0x7099…79C8`, qualifyingBuys=2, timeLeft 300, pot 0,000980391816673924 WBNB, terima 104.547.499,2 LWD, totalRaised 0,09803918 |
| Buy kecil — creator 0,005 (< 0,01) | `0x6ac4ffef3e88a64df07372868b78e531e05e589c4d1879cf3f36dbbadb75ec59` | lastBuyer TETAP buyer2, qualifyingBuys TETAP 2, deadline tidak berubah, pot naik jadi 0,001029411415288842 WBNB, totalRaised 0,10294114 |
| Time travel +419 dtk (`anvil_increaseTime` + `evm_mine`) | — | timeLeft 0, ended=true, roundEnded=true, lastBuyer buyer2, qualifyingBuys 2 |
| Buy setelah nol via `buyByBudget` 0,001 | — | ❌ revert `CoreErrBudgetNotExecutable` (selector `0xd15b1d74`). Diagnosis: `estimateBuyByBudget` mengembalikan SEMUA NOL setelah clock nol, jadi Core menolak budget buy. Bukan bug LastWin — `MigrateModule.canMigrateNow()` = true dan `core.migrate` staticCall OK. |
| Buy setelah nol via `buy(token, 1 token)` | `0x9b8845aaedd617acd4cbd0a473f88a8c28cf63c93a78276537a1ae739dd9f12e` | terima TEPAT 1,0 LWD (cap postRoundMaxBuy ✓), lastBuyer tetap buyer2, qualifyingBuys tetap 2, **migrated=true, vault phase 3 (Migrated)** — buy memicu graduasi dengan adapter `0x0`, pot dust +0,000000000005393907 WBNB |

## 7. Settle (90% winner / 10% creator — TEPAT)

Panggil `settle()` di custom-data clone `0x6B3d5B8bE73884578b9A88816AfdC0682FDAf616`
dari creator (permissionless).

Settle #1 — tx `0x759aa476804c61d4b631542334be9eefeed538a9dbcbf3ed8c09efef941cab0f`:
- Pot sebelum: 0,001029411415288842 WBNB (potNative 0).
- Harapan: winner 90% = 0,000926470273759957; creator 10% = 0,000102941141528885.
- Nyata (delta saldo WBNB): winner (buyer2) +0,000926470273759957 ✓;
  creator +0,000102941141528885 ✓. `totalPaidToWinnerByAsset` /
  `totalPaidToCreatorByAsset` cocok. Event `PotSettled(WBNB, buyer2,
  0,000926470273759957, creator, 0,000102941141528885)`. Pot sesudah: 0.
- Settle #2 (sweep) — tx `0x982870b4c356d670b46f1b08350e2bd99bf02187834fd18362199e3bb37afd97`:
  status 1, delta winner & creator 0, tidak revert.
- Settle #3 setelah buy pasca-round (dust) — tx
  `0x16bd1d96fa0b85d74e2e348f0891b7c2c4eee58e8cf06ed2fd966e348f1fa7b5`:
  pot 0,000000000005393907 → winner +0,000000000004854516 (90%),
  creator +0,000000000000539391 (10%), pot kembali 0.

Keadaan akhir (cek independen via `cast`): `gameState()` ended=true,
migrated=true, timeLeft 0, lastBuyer buyer2, qualifyingBuys 2, pot 0;
vault phase 3 Migrated, isSoldOut=false, totalRaised
0,102941142068275064 WBNB, remainingForSale 551.786.585,715713289;
saldo LWD creator 143.665.914,068; buyer2 104.547.500,216 (termasuk 1 token pasca-round).

## 8. Yang TIDAK terbukti / masih terbuka

- Sell path tidak diuji (bukan bagian tugas; buy-only).
- Likuiditas PCS V2 tidak diuji — `migrationAdapter = 0x0`, migrasi hanya
  menutup round (phase Migrated) tanpa pool. Uji adapter PCS V2 butuh
  langkah terpisah.
- Quote native tidak bisa dipakai dengan StandardVault fork ini
  (`Vault: quote must be ERC20`); game di atas memakai WBNB.
- `buyByBudget` tidak bisa dipakai setelah clock nol (estimasi 0 →
  `CoreErrBudgetNotExecutable`); pakai `buy(token, postRoundMaxBuy)`.
- Tidak ada audit; ini BUKAN bukti mainnet. Semua alamat hanya hidup di
  Anvil lokal (restart = hilang). Tidak ada push ke GitHub.

## 9. File

- `fork-local/fork-deployment.json` — alamat fork Registry/Core/dll.
- `fork-local/play-result.json` — log langkah demi langkah (semua tx,
  estimasi, gameState sebelum/sesudah).
- `fork-local/play-lastwin.js`, `play-lastwin-part2.js`,
  `diagnose-buy4.js`, `buy-exact-post-round.js`, `inspect-schemas.js` —
  skrip yang dipakai (kunci Anvil default saja).
- `fork-local/register-sim.log` — trace simulasi registrasi yang gagal
  sebelum perbaikan `getModule`.
- `broadcast/Deploy.s.sol/97/run-latest.json`,
  `broadcast/RegisterForkPreset.s.sol/97/run-latest.json` — tx broadcast.
