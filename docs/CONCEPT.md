# FairDot — Formula dan Batasan Prototipe

## Tujuan

FairDot menguji mekanisme cost basis per holder, pemicu proteksi 5×, pelepasan profit bertahap, dan batas penjualan yang ditegakkan oleh satu pool terdaftar. Ini masih prototipe testnet; jangan anggap klaim proteksi sebagai jaminan bahwa harga tidak turun atau pokok selalu dapat direalisasikan pada harga tertentu.

## 1. Harga masuk rata-rata berbobot jumlah token

Harga masuk adalah rata-rata biaya yang benar-benar dibayar per token:

```text
P_entry = Σ(tokenAmount_i × price_i) / Σ(tokenAmount_i)
TotalInvested = Σ(tokenAmount_i × price_i / 10^18)
P_entry = TotalInvested × 10^18 / TotalTrackedTokens
```

`tokenAmount_i` menggunakan unit ERC-20 18 desimal, dan `price_i` adalah harga per token dalam unit quote yang diskalakan 1e18.

**Contoh:**

- Beli 1.000 token pada harga 1: biaya 1.000 quote.
- Beli 1.000 token pada harga 3: biaya 3.000 quote.
- Total biaya 4.000 quote dibagi 2.000 token, sehingga `P_entry = 2,0`.

Ini adalah rata-rata berbobot jumlah token dan cost basis per token. Contoh lama yang menghasilkan 2,5 tidak sesuai dengan definisi tersebut dan telah dihapus.

## 2. Harga efektif dan mode proteksi

`P_effective` pada prototipe adalah VWAP 24 jam dari trade points pool:

```text
P_effective = Σ(price × quoteVolume) / Σ(quoteVolume)
Ratio = P_effective / P_entry
```

Pool harus merekam volume buy dan sell dalam **unit quote yang sama**. Jika tidak ada observasi segar, harga efektif tidak tersedia dan penjualan posisi tercatat ditolak sampai ada observasi baru; kontrak tidak lagi memakai harga yang usang tanpa batas waktu.

| Rasio | Mode prototipe | Perilaku |
|---|---|---|
| `< 5×` | Normal | Seluruh saldo dilaporkan dapat ditarik |
| `>= 5×` | Proteksi | Token pokok dihitung dari `TotalInvested / P_effective`; profit sisanya mengikuti jadwal lock |

Konversi pokok pada prototipe juga memakai VWAP, bukan harga eksekusi swap. Karena harga swap aktual bisa berbeda akibat slippage dan perubahan pasar, ini belum menjamin jumlah quote yang diterima sama dengan nilai pokok.

## 3. Pelepasan profit

Setelah `activateLock(user)` dipanggil ketika rasio minimal 5×, kontrak mencatat jumlah profit dan waktu mulai. Profit dilepas linear selama 10 hari; pada hari ke-10 seluruh profit posisi dilaporkan tersedia.

Timer dimulai saat fungsi aktivasi dipanggil, bukan otomatis pada detik persis harga melewati 5×. Pool mock memanggil aktivasi sebelum penjualan; fungsi juga dapat dipanggil siapa saja untuk holder. Semantik siklus harga berulang, pembelian tambahan saat lock aktif, serta penggabungan dua posisi dengan waktu lock berbeda masih perlu spesifikasi dan test tambahan sebelum mainnet.

## 4. Transfer posisi

Saat token berpindah antar-EOA, proporsi posisi dihitung terhadap saldo pengirim **sebelum** transfer:

```text
share = amountTransferred / balanceBeforeTransfer
investedMoved = totalInvestedSender × share
trackedTokensMoved = trackedTokensSender × share
```

Cost basis penerima digabung berdasarkan total biaya dan total token terlacak. Transfer ke pool terdaftar adalah jalur penjualan dan basis token yang dijual dikurangi dari posisi pengirim, bukan diwariskan ke pool sebagai basis pembeli berikutnya.

Jadwal stagger yang sedang aktif tidak dapat dipindahkan dengan transfer. Transfer ke/dari kontrak selain pool terdaftar diblokir. Ini membatasi composability: wallet kontrak, router, bridge, dan DEX lain tidak dapat memakai token kecuali desain/daftar integrasinya diperbarui.

## 5. Stagger penjualan

Pool membandingkan nilai satu permintaan penjualan dengan quote liquidity:

```text
L_ratio = withdrawalValue / totalQuoteLiquidity
<= 10%       -> 1 bagian
>10% dan <=30% -> 3 bagian, jarak 8 jam
>30%         -> 10 bagian, jarak 1 hari
```

Untuk jumlah besar, holder membuat jadwal atas jumlah token tertentu; pool hanya menerima installment sesuai jadwal. Ini masih berbasis permintaan/akun dan belum menutup bypass dengan banyak penjualan kecil atau memecah posisi ke beberapa alamat. Karena itu, klaim “tidak ada yang dapat menguras pool” belum dapat dibuat.

## 6. Pool terdaftar dan cakupan B

Token hanya mengizinkan perpindahan yang melibatkan kontrak `liquidityPool` terdaftar; hanya satu pool dapat dikonfigurasi pada prototipe ini dan tidak dapat diganti setelah trading diaktifkan. Transfer EOA-ke-EOA tetap boleh. Kebijakan ini menutup jalur interaksi langsung dengan kontrak DEX yang tidak disetujui, tetapi tidak mencegah transaksi privat antar-wallet dan tidak menggabungkan batas penjualan lintas-wallet.

## 7. Belum diimplementasikan / prasyarat mainnet

- Liquidity lock/vesting LP tidak diimplementasikan.
- Token awal/treasury atau penerima token tanpa record buy tidak memiliki cost basis pembelian otomatis.
- Riwayat harga berupa array yang terus bertambah; pemindaian VWAP perlu dibatasi atau diganti agregasi yang aman untuk volume produksi.
- Pool mock adalah contoh testnet tanpa fee dan tanpa mekanisme oracle/MEV atau manajemen likuiditas produksi.
- Perlu definisi final untuk lock pada beberapa siklus harga, tambahan pembelian, dan penggabungan posisi.
- Perlu audit keamanan independen dan pengujian semua jalur pasar sebelum mainnet.
