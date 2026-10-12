# Spesifikasi Logika Kode — Modul Voucher Kas Keluar (untuk diuji di NotebookLM)

Dokumen ini adalah ringkasan aturan bisnis yang DIIMPLEMENTASIKAN di kode
(`soal3/supabase/01_audit_trail_immutability.sql` dan `soal3/web/index.html`)
untuk diuji kepatuhannya terhadap PSAK 207 (dahulu PSAK 2) Laporan Arus Kas
dan PSAK 201 (dahulu PSAK 1) Penyajian Laporan Keuangan.

## A. Definisi akun kas di bagan akun (chart_of_accounts)
| Kode | Nama akun | Diperlakukan sebagai kas/bank di voucher kas keluar? |
|---|---|---|
| 1101 | Kas | Ya |
| 1102 | Bank (rekening giro) | Ya |
| 1103 | Kas Kecil | Ya |
| 1401 | Sewa Dibayar di Muka | Tidak |
| 2101 | Utang Usaha | Tidak |
| 61xx | Beban operasional (gaji, listrik, sewa, perlengkapan, transportasi) | Tidak |

Kode menyimpan konstanta `KAS_CODES = ['1101','1102','1103']`.
Setara kas (misal deposito berjangka ≤ 3 bulan) BELUM memiliki akun tersendiri.
Cerukan (overdraft) bank BELUM dimodelkan.

## B. Aturan validasi voucher kas keluar (frontend + RPC `rpc_create_cash_voucher`)
1. Tanggal transaksi wajib dan tidak boleh di masa depan.
2. Nomor bukti (BKK-…) dan deskripsi wajib diisi; nomor bukti UNIQUE.
3. Minimal 2 baris jurnal; tiap baris hanya debit ATAU kredit, nominal > 0.
4. Total Debit = Total Kredit (zero-discrepancy), dicek di browser DAN di database.
5. Akun kas/bank (1101/1102/1103) WAJIB ada dan HANYA di sisi KREDIT
   (karena voucher ini mencatat arus kas keluar).
6. Kas diakui pada tanggal transaksi pembayaran (basis kas untuk voucher; akrual
   untuk beban dicatat di jurnal lain bila ada).

## C. Pengendalian setelah posting
7. Jurnal berstatus POSTED tidak dapat di-UPDATE/DELETE (trigger database).
8. Koreksi hanya melalui jurnal pembalik (storno) dengan alasan wajib, lalu input ulang.
9. created_by diambil dari JWT pengguna login (server-side), created_at = waktu server.
10. hash_checksum SHA-256 berantai atas header + baris jurnal + hash sebelumnya.

## D. Pertanyaan verifikasi
- Apakah definisi kas & setara kas di kode sudah sesuai PSAK 207?
- Apakah transaksi antara kas dan setara kas (mis. memindahkan kas ke deposito 3 bulan)
  seharusnya dicatat sebagai arus kas keluar?
- Bagaimana perlakuan cerukan bank?
- Apakah voucher kas keluar dapat diklasifikasikan ke aktivitas operasi/investasi/pendanaan?
- Apakah mekanisme storno sesuai dengan prinsip koreksi kesalahan (PSAK 208)?
