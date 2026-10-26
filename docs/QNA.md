# FairDot — Q&A Prototipe

## A. Apa yang dilakukan FairDot?

**Q: Apa tujuan FairDot?**
A: Menguji cost basis per holder, pemicu proteksi pada rasio 5×, pelepasan profit bertahap, dan pembatasan jual pada pool yang mengintegrasikan kontrak.

**Q: Apakah harga atau pokok saya dijamin?**
A: Tidak. Kontrak tidak menjamin harga naik, likuiditas tersedia, atau jumlah quote hasil penjualan sama dengan pokok yang dihitung. Harga eksekusi dapat berbeda dari VWAP akibat slippage dan perubahan pasar.

## B. Mekanisme prototipe

**Q: Bagaimana harga masuk dihitung?**
A: Total quote yang diinvestasikan dibagi jumlah token yang tercatat. Pembelian 1.000 token pada harga 1 dan 1.000 token pada harga 3 menghasilkan harga masuk 2,0.

**Q: Kapan proteksi aktif?**
A: Saat VWAP 24 jam mencapai setidaknya 5× harga masuk. Jadwal lock dimulai ketika `activateLock(user)` dipanggil; pool mock memanggilnya sebelum penjualan yang dicoba pada mode proteksi. Aktivasi tidak otomatis terjadi tepat saat harga melintasi 5× untuk semua holder.

**Q: Apakah pokok selalu bebas?**
A: Dalam perhitungan prototipe, jumlah token pokok diperkirakan dari total investasi dibagi VWAP efektif, bukan harga eksekusi. Jika harga data tidak tersedia atau usang, penjualan posisi tercatat ditolak sampai data segar tersedia. Karena itu, ini bukan jaminan nilai pokok yang dapat direalisasikan.

**Q: Bagaimana penjualan besar ditangani?**
A: Penjualan individual lebih dari 10% quote liquidity memerlukan jadwal. Jumlah token dipecah menjadi 3 bagian dengan jeda 8 jam, atau 10 bagian dengan jeda 1 hari untuk ukuran di atas 30%. Jadwal dibuat pemegang token sebelum menjual; ini belum otomatis membuat seluruh jumlah penjualan dalam satu permintaan.

**Q: Bisakah stagger dilewati dengan transaksi kecil atau banyak wallet?**
A: Ya, prototipe belum menggabungkan riwayat penjualan lintas transaksi kecil atau lintas alamat. Pemindahan token saat sebuah jadwal aktif diblokir, tetapi pemecahan sebelum jadwal dibuat masih mungkin. Ini blocker sebelum klaim anti-drain atau mainnet.

**Q: Apa yang terjadi saat token dipindahkan?**
A: Transfer EOA-ke-EOA mewariskan cost basis secara proporsional. Transfer ke kontrak selain pool yang terdaftar diblokir. Penggabungan posisi dengan waktu lock berbeda dan perilaku lock pada siklus harga berulang masih memerlukan spesifikasi dan test tambahan.

## C. Kebijakan pool B dan kompatibilitas

**Q: Mengapa hanya pool terdaftar yang boleh berinteraksi?**
A: Ini membatasi penggunaan token lewat kontrak DEX/router yang tidak mengintegrasikan validasi FairDot. Prototipe hanya mendukung satu pool, yang harus ditetapkan sebelum trading aktif dan tidak dapat diganti setelahnya.

**Q: Apakah token dapat dipakai bebas di DEX lain, bridge, multisig, atau smart wallet?**
A: Belum. Interaksi dengan alamat kontrak selain pool terdaftar diblokir. Integrasi tambahan perlu desain whitelist dan review keamanan; kebijakan ini mengurangi composability.

**Q: Apakah pilihan B mencegah penjualan privat atau transfer antar orang?**
A: Tidak. Transfer antar-EOA tetap dimungkinkan. Token tidak dapat mengawasi kesepakatan privat di luar jalur pool, dan riwayat stagger tidak digabung lintas-wallet.

## D. Likuiditas dan keamanan

**Q: Apakah likuiditas terkunci?**
A: Tidak ada mekanisme LP lock/vesting dalam kode saat ini. Jangan mengklaim rugpull dicegah oleh penguncian likuiditas.

**Q: Apakah MockLiquidityPool DEX produksi?**
A: Tidak. Itu pool constant-product sederhana untuk testnet, menggunakan native tPOTv3 sebagai quote asset, tanpa biaya swap dan tanpa perlindungan oracle/MEV atau manajemen likuiditas produksi.

**Q: Apakah kontrak siap mainnet?**
A: Tidak. Diperlukan pool produksi terintegrasi, cost basis untuk distribusi awal, batas VWAP yang scalable, aturan final untuk transfer/lock/siklus harga, penutupan bypass penjualan, pengujian lebih lengkap, dan audit keamanan independen.

## E. Development dan deployment

**Q: Jaringan testnet apa yang digunakan?**
A: Portaldot V3 EVM, chain ID `420420777`.

**Q: Bagaimana mengecek deploy tanpa transaksi?**
A: Isi `.env` secara lokal dan jalankan `PREFLIGHT_ONLY=1 npm run deploy:portaldotv3`. Jangan pernah membagikan private key atau seed phrase.

**Q: Apakah test yang lulus berarti aman?**
A: Tidak. Lima belas test lokal saat ini menguji beberapa alur prototipe; test suite bukan audit keamanan dan tidak membuktikan seluruh kasus produksi.
