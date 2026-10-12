# Log Prompt Gemini Canvas (Soal 3.1a)

**Tujuan:** membangun rancangan formulir entri jurnal dinamis Voucher Kas Keluar dengan
kalkulasi total otomatis (*live balanced indicator*).
**Alat:** Gemini (gemini.google.com) dengan mode **Canvas**, akun Google pribadi, 12 Oktober 2026.
**Tangkapan layar:** `bukti/screenshots/gemini_canvas_*.jpg`

## Teknik prompt yang dipakai
1. **Peran & konteks.** AI diberi peran sebagai front-end developer sistem akuntansi.
2. **Batasan teknis eksplisit.** Satu file HTML + Tailwind CSS (CDN) + JavaScript murni, tanpa framework, sesuai materi kuliah.
3. **Aturan bisnis bernomor.** Setiap aturan akuntansi ditulis sebagai kriteria yang dapat diuji (1–7).
4. **Kontrak data.** Format payload dikunci agar sama persis dengan fungsi RPC Supabase.
5. **Verifikasi manusia.** Hasil AI ditinjau baris per baris sebelum dipakai (lihat bagian Evaluasi).

## Prompt yang dikirim

```
Kamu adalah front-end developer untuk sistem akuntansi perusahaan ritel/logistik.
Buatkan di Canvas satu file HTML (HTML + Tailwind CSS via CDN + JavaScript murni, TANPA
React/framework) untuk formulir "Voucher Kas Keluar (Bukti Kas Keluar)".

Field header: Tanggal Transaksi, No. Bukti (format BKK-YYYYMMDD-xxx), Deskripsi/Dibayarkan kepada.
Tabel baris jurnal dinamis: kolom Akun (dropdown dari bagan akun), Debit, Kredit, tombol hapus
baris, dan tombol "+ Tambah baris". Minimal 2 baris.

Bagan akun contoh: 1101 Kas, 1102 Bank, 1103 Kas Kecil, 1401 Sewa Dibayar di Muka, 2101 Utang
Usaha, 6101 Beban Gaji, 6102 Beban Listrik Air & Telepon, 6103 Beban Sewa, 6104 Beban
Perlengkapan Kantor, 6105 Beban Transportasi.

Aturan bisnis (wajib, dicek LIVE setiap kali input berubah):
1. Total Debit dan Total Kredit dihitung otomatis di footer tabel (format Rupiah id-ID).
2. Tampilkan "live balanced indicator": kotak hijau "SEIMBANG" bila Total Debit = Total Kredit
   > 0, kotak merah "TIDAK SEIMBANG" beserta nilai selisihnya bila tidak.
3. Nominal tidak boleh negatif; satu baris hanya boleh berisi debit ATAU kredit (tidak keduanya,
   tidak nol semua).
4. Karena ini kas KELUAR: akun Kas/Bank/Kas Kecil wajib ada dan hanya boleh di sisi KREDIT.
5. Tanggal tidak boleh di masa depan; No. Bukti & Deskripsi wajib diisi.
6. Tombol "Submit & Posting" DISABLED sampai semua aturan terpenuhi. Tampilkan checklist aturan
   (✓/✗) di bawah indikator agar pengguna tahu apa yang kurang.
7. Hitung dalam satuan sen (integer) untuk menghindari galat pembulatan desimal JavaScript.

Saat submit, susun payload JSON:
{ "p_transaction_date": "YYYY-MM-DD", "p_reference_no": "...", "p_description": "...",
  "p_lines": [ { "account_code": "6102", "debit": 750000, "credit": 0 }, ... ] }
dan tampilkan di console (nanti akan dikirim ke Supabase RPC rpc_create_cash_voucher).

Desain: bersih seperti buku besar, angka rata kanan dengan font monospace, responsif di layar
HP. Beri komentar kode berbahasa Indonesia.
```

## Riwayat eksekusi

| Percobaan | Model | Hasil |
|---|---|---|
| 1 | Gemini Pro + Canvas | Mulai membuat Canvas, tetapi sesi terputus sebelum selesai (percakapan tidak tersimpan). |
| 2 | Gemini Pro + Canvas | Gemini menjawab keliru: *"Saya hanya AI berbasis teks dan tidak bisa membantu Anda untuk itu."* Prompt lanjutan juga ditolak (`gemini_canvas_00_percobaan_pro_gagal.jpg`). |
| 3 | **Gemini 3.6 Flash + Canvas** | **Berhasil.** Canvas "Voucher Kas Keluar", 753 baris kode (`gemini_canvas_02`–`05`). |

Pelajaran: keluaran AI generatif tidak deterministik. Prompt yang sama bisa gagal di satu
model dan berhasil di model lain, sehingga hasilnya harus selalu diverifikasi.

## Hasil Gemini Canvas (percobaan 3)

Fitur yang berhasil dibuat sesuai prompt: header BKK dengan tombol "Auto" nomor bukti, tabel
baris dinamis, total footer format Rupiah, kotak **SEIMBANG (BALANCED)** hijau/merah beserta
selisih, checklist 5 aturan bisnis ✓/✗, tombol Submit yang disabled sampai valid, dan modal +
`console.log` payload JSON. Gemini juga menambahkan tombol *preset transaksi cepat* yang tidak
diminta.

## Evaluasi kritis kode Gemini (code review)

| # | Temuan pada kode Gemini | Dampak | Penanganan di versi final (`soal3/web/index.html`) |
|---|---|---|---|
| 1 | Konversi sen memakai `row.debitRupiah * 100` **tanpa pembulatan** | Galat floating point tetap ada (contoh `0.29 * 100 = 28.999999999999996`), sehingga aturan no. 7 tidak benar-benar terpenuhi. Debit dan kredit yang secara akuntansi sama bisa dinilai "tidak seimbang". | `Math.round(Number(v) * 100)` |
| 2 | "Hari ini" memakai `new Date().toISOString()` (zona **UTC**) | Di WIB (UTC+7), antara pukul 00.00–07.00 tanggal hari ini dianggap **masa depan** dan transaksi ditolak. | `toLocaleDateString('sv-SE')` (zona waktu lokal) |
| 3 | Payload memakai `Math.round(row.debitRupiah)` | Nilai sen (desimal) terpotong ke rupiah bulat. | Payload dikirim dalam rupiah dengan 2 desimal (`cents / 100`) sesuai tipe `NUMERIC(18,2)` |
| 4 | Hanya `console.log`, tanpa koneksi database, tanpa jejak audit | Belum memenuhi kebutuhan auditor. | Integrasi Supabase RPC, login (created_by dari JWT), daftar jurnal + hash, storno, audit log, verifikasi hash |
| 5 | Validasi hanya di browser | Bisa dilewati lewat API (masalah inti di Soal 1). | Semua aturan ditegakkan ulang di database (RPC + trigger). Bukti: `bukti/uji_soal3_keamanan_supabase_anon.txt` |

Kesimpulan: Gemini Canvas mempercepat pembuatan rancangan UI, tetapi kodenya memiliki bug
akuntansi yang halus (pembulatan dan zona waktu). Versi final memakai rancangan yang sama
(indikator seimbang, checklist aturan, tombol submit yang terkunci) dengan perbaikan di atas,
lalu diintegrasikan dengan backend.
