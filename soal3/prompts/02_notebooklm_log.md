# Log NotebookLM: Verifikasi Kepatuhan Kode terhadap PSAK 207 (Soal 3.1b)

**Alat:** NotebookLM (sekarang bernama *Gemini Notebook*), akun Google pribadi
**Notebook:** "Financial Accounting Standards and Cash Flow Reporting" (dibuat 12 Oktober 2026)
**Tangkapan layar:** `bukti/screenshots/notebooklm_*.jpg`

## 1. Sumber yang dimasukkan (6)

| # | Sumber | Fungsi |
|---|---|---|
| 1 | BINUS Accounting: *PSAK 2 (Penyesuaian 2014): Laporan Arus Kas*: https://accounting.binus.ac.id/2017/08/30/psak-2-penyesuaian-2014-laporan-arus-kas/ | Definisi kas, setara kas, aktivitas arus kas |
| 2 | BINUS Accounting: *Setara Kas, Pembatasan, dan Overdraft* (2025): https://accounting.binus.ac.id/2025/07/28/setara-kas-pembatasan-dan-overdraft/ | Kriteria 3 bulan, kas yang dibatasi, cerukan bank |
| 3 | IAS Plus (Deloitte): *IAS 7 Statement of Cash Flows*: https://www.iasplus.com/en/standards/ias/ias7 | Standar acuan PSAK 207 (adopsi IFRS) |
| 4 | IAI: *Perubahan Penomoran PSAK & ISAK dalam SAK Indonesia*: https://web.iaiglobal.or.id/assets/files/file_publikasi/Perubahan_Penomoran_PSAK_ISAK_dalam_SAK_Indonesia.pdf | PSAK 2 → PSAK 207, PSAK 1 → PSAK 201, PSAK 25 → PSAK 208 |
| 5 | `soal3/prompts/notebooklm_sumber_spesifikasi_kode.md` (repo GitHub) | Ringkasan aturan bisnis yang diimplementasikan |
| 6 | `soal3/supabase/01_audit_trail_immutability.sql` (repo GitHub) | Kode backend yang diuji |

## 2. Prompt

```
Bertindaklah sebagai auditor internal. Uji kepatuhan logika kode pada dokumen
"notebooklm_sumber_spesifikasi_kode.md" dan "01_audit_trail_immutability.sql" terhadap
PSAK 207 (dahulu PSAK 2) Laporan Arus Kas tentang kas dan setara kas. Untuk setiap aturan
bisnis A–C di dokumen spesifikasi, beri status SESUAI / PERLU PERBAIKAN / DI LUAR CAKUPAN
PSAK beserta alasannya dan kutip sumbernya. Secara khusus jawab: (1) apakah definisi akun
kas (1101 Kas, 1102 Bank, 1103 Kas Kecil) sudah sesuai definisi kas dan setara kas, termasuk
kriteria jatuh tempo 3 bulan; (2) bagaimana perpindahan antara kas dan setara kas serta
cerukan bank harus diperlakukan; (3) apakah mekanisme jurnal pembalik (storno) dan penguncian
jurnal POSTED mendukung keandalan informasi arus kas. Akhiri dengan daftar rekomendasi
perbaikan kode yang konkret.
```

## 3. Ringkasan jawaban NotebookLM (memo audit internal, dengan sitasi ke sumber)

| Aturan | Status dari NotebookLM | Inti temuan |
|---|---|---|
| A. Definisi akun kas (1101, 1102, 1103) | **PERLU PERBAIKAN** | Kas, Bank (giro), dan Kas Kecil sudah tepat sebagai *kas*. Namun **setara kas** (investasi sangat likuid, jatuh tempo ≤ 3 bulan **sejak tanggal perolehan**, risiko perubahan nilai tidak signifikan) belum dimodelkan, dan **cerukan bank** belum ditangani. |
| B. Validasi voucher kas keluar | **PERLU PERBAIKAN** | Aturan "kas hanya di sisi kredit" benar untuk kas keluar, tetapi **mutasi antar pos kas/setara kas** (mis. Bank → Kas Kecil, Bank → deposito 3 bulan) bukan arus kas menurut PSAK 207 dan perlu jalur tersendiri. Klasifikasi **aktivitas operasi/investasi/pendanaan** juga belum ada. |
| C. Penguncian POSTED, storno, hash | **DI LUAR CAKUPAN PSAK 207** (mendukung keandalan, sejalan dengan PSAK 208) | Immutability, audit log append-only, hash SHA-256 berantai, dan storno menjaga keandalan informasi arus kas. Transaksi asli dan storno saling meniadakan pada periode yang sama tanpa menghapus jejak audit. |

Poin penting lain dari jawaban NotebookLM:
- Deposito yang saat dibeli berjangka > 3 bulan **bukan** setara kas, walaupun sisa jatuh temponya tinggal 2 bulan.
- Cerukan bank yang merupakan bagian tak terpisahkan dari pengelolaan kas **mengurangi** kas dan setara kas di laporan arus kas, tetapi di **neraca** disajikan sebagai **liabilitas jangka pendek**.

Rekomendasi NotebookLM: (1) tambah akun setara kas, (2) RPC khusus mutasi kas internal,
(3) view rekonsiliasi cerukan bank, (4) kolom klasifikasi aktivitas arus kas.

## 4. Tindak lanjut (sudah diimplementasikan & diuji)

Berkas `soal3/supabase/04_perbaikan_hasil_notebooklm.sql`, uji di `05_uji_perbaikan_notebooklm.sql` → `bukti/uji_soal3_perbaikan_notebooklm.txt`:

| Rekomendasi | Implementasi | Hasil uji |
|---|---|---|
| Akun setara kas | Akun `1104 Setara Kas – Deposito ≤ 3 bulan` dan `1105 Deposito > 3 bulan (bukan setara kas)`. Daftar kas/setara kas dipindah ke tabel `cash_equivalent_accounts` (tidak lagi di-hardcode). | Mutasi ke 1105 ditolak; ke 1104 diterima |
| Mutasi kas internal | `rpc_create_cash_transfer()` dengan jenis jurnal `MUTASI_KAS`. Voucher kas keluar tetap menolak debit ke akun kas dan mengarahkan pengguna ke RPC ini. | Bank → Kas Kecil via voucher ditolak, via transfer diterima |
| Cerukan bank | View `v_kas_dan_setara_kas`. Saldo kredit akun Bank → "CERUKAN_BANK (liabilitas jangka pendek)". Kas fisik negatif → ditandai "TIDAK WAJAR". | Saldo tersaji sesuai kategori |
| Aktivitas arus kas | Kolom `cash_flow_activity` (OPERASI/INVESTASI/PENDANAAN) + pilihan di formulir web + view `v_arus_kas_per_aktivitas` (MUTASI_KAS dikecualikan, storno mengikuti aktivitas jurnal aslinya). | Arus kas per aktivitas tampil |

Catatan kritis: saran kode dari NotebookLM tidak dipakai mentah-mentah. Contohnya, NotebookLM
menyarankan `report_classification = 'ASSET_LANCAR'`, yang akan melanggar CHECK constraint
skema (nilai yang valid adalah `'ASET'`). Logika cerukan juga diperketat sehingga hanya akun Bank
yang bisa dianggap cerukan, karena kas fisik tidak mungkin bersaldo negatif. Setelah perubahan,
seluruh rantai hash tetap valid (13/13 jurnal).
