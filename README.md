# UTS Pemrograman / Coding — Akuntansi FEB Undip 2026/2027

| | |
|---|---|
| **Nama** | Zayyan Beryl |
| **NIM** | 12030124140283 |
| **Mata kuliah** | Pengkodean dan Pemrograman — Kelas E |
| **Dosen** | Totok Dewayanto |
| **Basis data** | PostgreSQL 16 (uji lokal) & Supabase (cloud) |

Repositori ini berisi seluruh artefak jawaban UTS: skema DDL, fungsi trigger SQL,
kode backend (Supabase RPC) & frontend, log prompt AI, serta bukti pengujian.
Jawaban naratif lengkap ada di berkas PDF jawaban.

## Struktur

```
soal1/                         Desain data, normalisasi & asas berpasangan (25%)
  01_schema_general_ledger.sql   DDL chart_of_accounts, journal_headers, journal_lines
                                 + constraint trigger keseimbangan Debit = Kredit
  02_uji_soal1.sql               8 skenario uji
  erd.mmd / erd.png              ERD (Mermaid)
  JAWABAN_SOAL1.md

soal2/                         Trigger persediaan perpetual & concurrency (40%)
  01_inventory_trigger.sql       trg_update_stock_and_journal() + jurnal HPP/Persediaan otomatis
  02_uji_trigger.sql             6 skenario uji + rekonsiliasi GL vs stok fisik
  03_concurrency_snippets.sql    SELECT ... FOR UPDATE, SERIALIZABLE + retry, atomic update
  concurrency_demo.sh            simulasi 2 kasir bersamaan (stok 1 unit)
  JAWABAN_SOAL2.md

soal3/                         Purwarupa web full-stack & orkestrasi AI (35%)
  supabase/
    SETUP_LENGKAP_SUPABASE.sql   satu skrip untuk SQL Editor Supabase (soal1+2+3)
    01_audit_trail_immutability.sql  kunci POSTED, storno, created_by/created_at, hash SHA-256 berantai, audit_log, RPC
    02_supabase_security.sql     RLS + REVOKE + GRANT RPC
    03_uji_soal3.sql             15 skenario uji
  web/index.html                 Formulir Voucher Kas Keluar (HTML + Tailwind + JS)
  prompts/                       log prompt Gemini Canvas & NotebookLM
  JAWABAN_SOAL3.md

bukti/                         output uji (txt) & tangkapan layar
run_all_tests.sh               bangun ulang DB & jalankan seluruh uji
```

## Cara menjalankan

**PostgreSQL lokal**

```bash
createdb uts
DB=uts ./run_all_tests.sh      # hasil tersimpan di bukti/
```

**Supabase**

1. Buka *SQL Editor* → tempel isi `soal3/supabase/SETUP_LENGKAP_SUPABASE.sql` → *Run*.
2. *Authentication → Users → Add user* (centang *Auto Confirm User*).
3. Buka `soal3/web/index.html` di browser lalu login.
   Tambahkan `?demo` di URL untuk mencoba tanpa database (mode demo).

## Ringkasan desain

- **Integritas di database, bukan di frontend.** CHECK, FK `ON DELETE RESTRICT`,
  constraint trigger keseimbangan (DEFERRED), dan aturan posting DRAFT → POSTED.
- **Persediaan perpetual.** Setiap mutasi stok langsung membuat jurnal
  Persediaan/HPP dalam transaksi yang sama, dan stok negatif ditolak.
- **Concurrency.** Baris item dikunci dengan `SELECT ... FOR UPDATE` di dalam trigger.
- **Jejak audit.** Jurnal POSTED immutable (UPDATE/DELETE/TRUNCATE ditolak), koreksi
  lewat storno, `created_by` diambil dari JWT di sisi server, `hash_checksum` SHA-256
  berantai, dan `audit_log` bersifat append-only.
