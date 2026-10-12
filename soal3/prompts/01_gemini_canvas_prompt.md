# Log Prompt — Gemini Canvas (Soal 3.1a)

Tujuan: membangun rancangan formulir entri jurnal dinamis Voucher Kas Keluar
dengan kalkulasi total otomatis (*live balanced indicator*).

Teknik prompt yang dipakai:
1. **Peran & konteks** – AI diberi peran sebagai pengembang front-end untuk sistem akuntansi.
2. **Spesifikasi teknis eksplisit** – stack dibatasi (HTML + Tailwind CSS + JavaScript murni, satu file).
3. **Aturan bisnis bernomor** – setiap aturan akuntansi ditulis sebagai kriteria yang dapat diuji.
4. **Kontrak data** – format payload dikunci agar sama dengan fungsi RPC di Supabase.
5. **Iterasi** – prompt lanjutan untuk memperbaiki hasil.

---

## Prompt 1 (utama)

```
Kamu adalah front-end developer untuk sistem akuntansi perusahaan ritel/logistik.
Buatkan di Canvas satu file HTML (HTML + Tailwind CSS via CDN + JavaScript murni,
TANPA React/framework) untuk formulir "Voucher Kas Keluar (Bukti Kas Keluar)".

Field header: Tanggal Transaksi, No. Bukti (format BKK-YYYYMMDD-xxx), Deskripsi/Dibayarkan kepada.
Tabel baris jurnal dinamis: kolom Akun (dropdown dari bagan akun), Debit, Kredit,
tombol hapus baris, dan tombol "+ Tambah baris". Minimal 2 baris.

Bagan akun contoh: 1101 Kas, 1102 Bank, 1103 Kas Kecil, 1401 Sewa Dibayar di Muka,
2101 Utang Usaha, 6101 Beban Gaji, 6102 Beban Listrik Air & Telepon, 6103 Beban Sewa,
6104 Beban Perlengkapan Kantor, 6105 Beban Transportasi.

Aturan bisnis (wajib, dicek LIVE setiap kali input berubah):
1. Total Debit dan Total Kredit dihitung otomatis di footer tabel (format Rupiah id-ID).
2. Tampilkan "live balanced indicator": kotak hijau "SEIMBANG" bila Total Debit = Total Kredit > 0,
   kotak merah "TIDAK SEIMBANG" beserta nilai selisihnya bila tidak.
3. Nominal tidak boleh negatif; satu baris hanya boleh berisi debit ATAU kredit (tidak keduanya, tidak nol semua).
4. Karena ini kas KELUAR: akun Kas/Bank/Kas Kecil wajib ada dan hanya boleh di sisi KREDIT.
5. Tanggal tidak boleh di masa depan; No. Bukti & Deskripsi wajib diisi.
6. Tombol "Submit & Posting" DISABLED sampai semua aturan terpenuhi.
   Tampilkan checklist aturan (✓/✗) di bawah indikator agar pengguna tahu apa yang kurang.
7. Hitung dalam satuan sen (integer) untuk menghindari galat pembulatan desimal JavaScript.

Saat submit, susun payload JSON:
{ "p_transaction_date": "YYYY-MM-DD", "p_reference_no": "...", "p_description": "...",
  "p_lines": [ { "account_code": "6102", "debit": 750000, "credit": 0 }, ... ] }
dan tampilkan di console (nanti akan dikirim ke Supabase RPC rpc_create_cash_voucher).

Desain: bersih seperti buku besar, angka rata kanan dengan font monospace,
responsif di layar HP. Beri komentar kode berbahasa Indonesia.
```

## Prompt 2 (iterasi)

```
Tambahkan: (a) integrasi Supabase JS v2 via CDN — jika SUPABASE_URL & ANON KEY diisi,
panggil supabase.rpc('rpc_create_cash_voucher', payload); jika kosong jalankan mode demo;
(b) panel "Jurnal Terposting" yang menampilkan created_by, created_at dan hash_checksum;
(c) tombol "Buat jurnal pembalik" dengan input alasan wajib (bukan edit/hapus),
karena jurnal POSTED bersifat immutable.
```

---

## Hasil & tindak lanjut

- Hasil Gemini Canvas: lihat tangkapan layar `bukti/gemini_canvas_*.png` dan berkas
  `soal3/web/gemini_canvas_output.html` (kode asli dari Canvas).
- Versi final (`soal3/web/index.html`) adalah hasil penyempurnaan rancangan Canvas:
  disesuaikan dengan kontrak RPC Supabase, ditambah login (agar `created_by` terisi
  dari JWT), daftar jurnal, audit log, verifikasi hash, dan mode demo.
- Prinsip penting: **validasi di browser hanya untuk kenyamanan pengguna**; semua aturan
  ditegakkan ulang di database (RPC + trigger), sehingga request yang melewati UI tetap ditolak.
