# Soal 3: Purwarupa Web Full-Stack & Orkestrasi AI Tools

**Purwarupa online:** https://zayyanberyl-coding.github.io/uts-coding-akuntansi/soal3/web/
(tambahkan `?demo` untuk mencoba tanpa login)
**Basis data cloud:** Supabase (PostgreSQL), project `uts-coding-akuntansi`

Arsitektur:

```
Browser (HTML + Tailwind + JS)  --supabase.rpc()-->  Supabase PostgREST  -->  PostgreSQL
  - live balanced indicator                           (JWT pengguna)          - RPC SECURITY DEFINER
  - checklist aturan bisnis                                                    - trigger immutability
  - Submit terkunci s.d. valid                                                 - hash SHA-256 berantai
                                                                               - audit_log append-only
```

## 3.1 Orkestrasi AI Tools

### a. Gemini Canvas: formulir entri jurnal dinamis

Prompt lengkap, riwayat percobaan, dan evaluasi kode ada di `soal3/prompts/01_gemini_canvas_prompt.md`.

- **Prompt** disusun dengan pola *peran → batasan teknis → aturan bisnis bernomor → kontrak
  payload → desain*. Tujuh aturan bisnis ditulis sebagai kriteria yang dapat diuji (total
  otomatis, indikator SEIMBANG/TIDAK SEIMBANG + selisih, nominal non-negatif & satu sisi,
  kas hanya di kredit, tanggal tidak di masa depan, tombol Submit terkunci + checklist,
  perhitungan dalam sen).
- **Hasil Gemini** (Gemini 3.6 Flash + Canvas, setelah dua percobaan dengan Gemini Pro gagal):
  formulir lengkap dengan indikator **SEIMBANG (BALANCED)**, checklist 5 aturan, dan payload JSON.
- **Code review** menemukan bug yang halus: konversi sen tanpa pembulatan (`0.29*100 = 28.999…`),
  "hari ini" dihitung dalam UTC (salah untuk WIB 00.00–07.00), sen terpotong di payload, dan
  validasi hanya di browser.
- **Versi final** (`soal3/web/index.html`) memakai rancangan tersebut dengan perbaikan bug,
  lalu diintegrasikan ke Supabase: login (created_by dari JWT), pilihan aktivitas arus kas,
  daftar jurnal POSTED + hash, tombol jurnal pembalik, audit log, dan tombol verifikasi hash.

Inti logika indikator seimbang (JavaScript):

```js
function cents(v) { return Math.round((Number(v) || 0) * 100); }   // hindari galat desimal
const totalD = filled.reduce((s, l) => s + cents(l.debit), 0);
const totalC = filled.reduce((s, l) => s + cents(l.credit), 0);
const balanced = totalD > 0 && totalD === totalC;                  // zero-discrepancy
$('btnSubmit').disabled = !rules.every(r => r[1]);                 // semua aturan wajib ✓
```

Hasil uji otomatis (Playwright): Submit **terkunci** saat selisih Rp100.000 dan saat akun Kas
didebit, **aktif** saat Debit = Kredit = Rp1.000.000, tidak ada error JavaScript, dan tampilan
HP (390 px) tanpa scroll horizontal.

### b. NotebookLM: verifikasi aturan bisnis terhadap PSAK

Log lengkap ada di `soal3/prompts/02_notebooklm_log.md`.

**Sumber (6):** artikel BINUS tentang PSAK 2 (Laporan Arus Kas) dan tentang setara kas & overdraft,
ringkasan IAS 7 (IAS Plus/Deloitte), dokumen IAI tentang penomoran ulang PSAK
(PSAK 2 → **PSAK 207**, berlaku 1 Januari 2024), spesifikasi aturan bisnis kode, dan file SQL backend.

**Ringkasan verifikasi dari NotebookLM:**

| Aturan dalam kode | Status | Inti alasan |
|---|---|---|
| Definisi akun kas (Kas, Bank/giro, Kas Kecil) | Perlu perbaikan | Ketiga akun sudah tepat sebagai *kas*, tetapi **setara kas** (investasi sangat likuid, jatuh tempo ≤ 3 bulan **sejak tanggal perolehan**, risiko perubahan nilai tidak signifikan) dan **cerukan bank** belum dimodelkan. |
| Voucher kas keluar: kas hanya di kredit | Perlu perbaikan | Aturan ini benar untuk kas keluar. Namun **mutasi antar pos kas/setara kas** (Bank → Kas Kecil, Bank → deposito 3 bulan) **bukan arus kas** menurut PSAK 207, sehingga perlu jalur tersendiri. Klasifikasi aktivitas operasi/investasi/pendanaan juga belum ada. |
| Penguncian POSTED, storno, hash | Di luar cakupan PSAK 207, mendukung keandalan (PSAK 208) | Data arus kas tidak dapat dimanipulasi retroaktif. Koreksi dilakukan lewat jurnal pembalik yang saling meniadakan tanpa menghapus jejak audit. |

**Tindak lanjut (sudah diimplementasikan & diuji):** akun `1104 Setara Kas (≤ 3 bulan)` dan
`1105 Deposito > 3 bulan (bukan setara kas)`, tabel `cash_equivalent_accounts` sebagai satu
sumber definisi, RPC `rpc_create_cash_transfer` (jenis `MUTASI_KAS`, dikecualikan dari arus kas),
view `v_kas_dan_setara_kas` (saldo kredit Bank → cerukan, disajikan sebagai liabilitas jangka
pendek), serta kolom `cash_flow_activity` + view `v_arus_kas_per_aktivitas`.
Saran kode NotebookLM juga dikritisi: nilai `'ASSET_LANCAR'` yang disarankannya akan melanggar
CHECK constraint, dan logika cerukan dibatasi hanya untuk akun Bank.

## 3.2 Mekanisme Jejak Audit (Audit Trail & Immutability)

Spesifikasi backend berupa **Supabase RPC** (fungsi PostgreSQL yang dipanggil `supabase.rpc()`).
Kode: `soal3/supabase/01_audit_trail_immutability.sql`, hak akses: `02_supabase_security.sql`.

### Spesifikasi fungsi

| Fungsi / objek | Spesifikasi |
|---|---|
| `rpc_create_cash_voucher(tanggal, no_bukti, deskripsi, lines jsonb, aktivitas)` | Validasi ulang semua aturan bisnis, simpan header **DRAFT** + baris, lalu ubah ke **POSTED** (memicu segel hash). Mengembalikan id, created_by, created_at, hash. |
| `rpc_reverse_journal(id, alasan)` | **Storno**: hanya untuk jurnal POSTED, alasan wajib, maksimal satu kali per jurnal (`UNIQUE reversal_of`). Membuat jurnal baru `STORNO-<no>` dengan debit/kredit ditukar. Jurnal asli tetap utuh. |
| `rpc_verify_journal_integrity()` | Menghitung ulang SHA-256 tiap jurnal POSTED dan memeriksa rantai `prev_hash`. |
| Trigger `trg_journal_headers_immutable` / `trg_journal_lines_immutable` | **UPDATE / DELETE** pada jurnal POSTED (atau barisnya) → `RAISE EXCEPTION` yang menyarankan storno. Menambah baris ke jurnal POSTED juga ditolak. |
| Trigger `*_no_truncate` | `TRUNCATE` diblokir (TRUNCATE melewati trigger baris). |
| `audit_log` + `trg_audit_*` | Setiap INSERT/UPDATE/DELETE dicatat (actor, waktu, data lama/baru dalam JSONB). Tabel ini sendiri **append-only**. |
| RLS + `REVOKE` + `GRANT EXECUTE ... TO authenticated` | Klien tidak bisa menulis tabel langsung. Hanya pengguna login yang dapat memanggil RPC. |

### created_by, created_at, hash_checksum

- **`created_by`** diisi oleh trigger dari klaim JWT Supabase
  (`current_setting('request.jwt.claims')->>'email'`), yaitu email pengguna yang login. Nilai yang
  dikirim klien **diabaikan** (uji 9: upaya memalsukan `direktur@palsu.com` tetap tercatat sebagai
  pengguna sebenarnya). Kolom ini juga tidak bisa diubah saat UPDATE.
- **`created_at`** = `now()` waktu server (bukan jam komputer pengguna), bertipe `TIMESTAMPTZ`.
  Ditambah `posted_by` dan `posted_at` saat posting.
- **`hash_checksum`** = `SHA-256( id | tanggal | no_bukti | deskripsi | jenis | created_by |
  created_at(UTC) | reversal_of | daftar akun:debit:kredit | prev_hash )`.
  Hash disegel saat status berubah menjadi POSTED. Karena memuat `prev_hash` (hash jurnal
  sebelumnya, urut `post_seq`), hash membentuk **rantai**: mengubah satu angka di jurnal mana pun
  akan terdeteksi. Proses posting diserialisasi dengan `pg_advisory_xact_lock` agar rantai tidak bercabang.

### Hasil uji (`bukti/uji_soal3_audit_trail.txt`, PostgreSQL 16 + diterapkan di Supabase)

| No | Skenario | Hasil |
|---|---|---|
| 1 | Voucher seimbang via RPC | ✅ POSTED, created_by & hash terisi otomatis |
| 2–4 | Tidak seimbang / mendebit Kas / tanpa akun kas | ❌ Ditolak RPC |
| 5–7 | UPDATE, DELETE, sisip baris pada jurnal POSTED | ❌ Ditolak trigger |
| 8 | TRUNCATE | ❌ Ditolak |
| 9 | Memalsukan created_by/created_at | ✅ Diabaikan, diisi server |
| 10–11 | Storno, lalu storno kedua kali | ✅ Berhasil / ❌ Ditolak |
| 13 | Verifikasi seluruh hash | ✅ Semua valid |
| 14 | DBA mematikan trigger & mengubah nominal langsung | ⚠️ **Terdeteksi**: `hash_valid = false` |
| 15 | Mengubah/menghapus audit_log | ❌ Ditolak |
| Supabase | Klien tanpa login memanggil RPC / insert / select | ❌ `permission denied` / data kosong |
