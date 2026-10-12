-- =====================================================================
-- SOAL 3.2 - Skrip Uji Audit Trail & Immutability
-- Simulasi pengguna login: request.jwt.claims diisi seperti yang
-- dilakukan Supabase/PostgREST untuk setiap request.
-- =====================================================================
\set ON_ERROR_STOP off
\set VERBOSITY terse
\pset format aligned
SELECT set_config('request.jwt.claims', '{"sub":"0000-demo","email":"zayyan@demo.uts","role":"authenticated"}', false) \g /dev/null

\echo '=== UJI 1: Voucher kas keluar seimbang via RPC -> BERHASIL, created_by & hash terisi otomatis'
SELECT jsonb_pretty(rpc_create_cash_voucher(CURRENT_DATE, 'BKK-2026-10-001',
  'Pembayaran listrik & telepon kantor Oktober',
  '[{"account_code":"6102","debit":750000,"credit":0},
    {"account_code":"6105","debit":250000,"credit":0},
    {"account_code":"1101","debit":0,"credit":1000000}]'));

\echo '=== UJI 2: Voucher tidak seimbang dikirim langsung ke API -> DITOLAK'
SELECT rpc_create_cash_voucher(CURRENT_DATE, 'BKK-2026-10-002', 'Tes tidak seimbang',
  '[{"account_code":"6102","debit":750000,"credit":0},{"account_code":"1101","debit":0,"credit":700000}]');

\echo '=== UJI 3: "Kas keluar" yang justru mendebit Kas -> DITOLAK (aturan bisnis)'
SELECT rpc_create_cash_voucher(CURRENT_DATE, 'BKK-2026-10-003', 'Tes salah arah',
  '[{"account_code":"1101","debit":500000,"credit":0},{"account_code":"4101","debit":0,"credit":500000}]');

\echo '=== UJI 4: Voucher tanpa akun kas/bank di sisi kredit -> DITOLAK'
SELECT rpc_create_cash_voucher(CURRENT_DATE, 'BKK-2026-10-004', 'Bukan kas keluar',
  '[{"account_code":"6102","debit":500000,"credit":0},{"account_code":"2101","debit":0,"credit":500000}]');

\echo '=== UJI 5: UPDATE nominal / deskripsi jurnal POSTED -> DITOLAK'
UPDATE journal_headers SET description = 'diubah diam-diam' WHERE reference_no = 'BKK-2026-10-001';
UPDATE journal_lines   SET debit = 75000
 WHERE header_id = (SELECT id FROM journal_headers WHERE reference_no = 'BKK-2026-10-001') AND debit = 750000;

\echo '=== UJI 6: DELETE jurnal POSTED / barisnya -> DITOLAK'
DELETE FROM journal_lines WHERE header_id = (SELECT id FROM journal_headers WHERE reference_no = 'BKK-2026-10-001');
DELETE FROM journal_headers WHERE reference_no = 'BKK-2026-10-001';

\echo '=== UJI 7: Menyisipkan baris baru ke jurnal POSTED -> DITOLAK'
INSERT INTO journal_lines (header_id, account_id, debit, credit)
VALUES ((SELECT id FROM journal_headers WHERE reference_no = 'BKK-2026-10-001'), 1, 1, 0);

\echo '=== UJI 8: TRUNCATE tabel jurnal -> DITOLAK'
TRUNCATE journal_lines;

\echo '=== UJI 9: Klien mencoba memalsukan created_by -> diabaikan, diisi server'
BEGIN;
INSERT INTO journal_headers (transaction_date, reference_no, description, created_by, created_at)
VALUES (CURRENT_DATE, 'DRAFT-TES', 'tes pemalsuan', 'direktur@palsu.com', '2020-01-01');
SELECT reference_no, created_by, created_at::date = CURRENT_DATE AS created_at_hari_ini
  FROM journal_headers WHERE reference_no = 'DRAFT-TES';
ROLLBACK;

\echo '=== UJI 10: Koreksi lewat jurnal pembalik (storno) -> BERHASIL'
SELECT jsonb_pretty(rpc_reverse_journal(
  (SELECT id FROM journal_headers WHERE reference_no = 'BKK-2026-10-001'),
  'Salah input: tagihan listrik seharusnya Rp705.000'));

\echo '=== UJI 11: Storno kedua kali atas jurnal yang sama -> DITOLAK'
SELECT rpc_reverse_journal((SELECT id FROM journal_headers WHERE reference_no = 'BKK-2026-10-001'), 'ulang');

\echo '=== UJI 12: Input ulang voucher yang benar'
SELECT rpc_create_cash_voucher(CURRENT_DATE, 'BKK-2026-10-001R', 'Pembayaran listrik & telepon kantor Oktober (koreksi)',
  '[{"account_code":"6102","debit":705000,"credit":0},
    {"account_code":"6105","debit":250000,"credit":0},
    {"account_code":"1101","debit":0,"credit":955000}]') ->> 'reference_no' AS voucher_baru;

\echo '=== JEJAK: original, storno, dan koreksi (net efek = voucher koreksi saja)'
SELECT h.reference_no, h.journal_type, a.account_code, a.account_name, l.debit, l.credit
  FROM journal_headers h
  JOIN journal_lines l     ON l.header_id = h.id
  JOIN chart_of_accounts a ON a.account_id = l.account_id
 WHERE h.reference_no LIKE '%BKK-2026-10-001%'
 ORDER BY h.id, l.id;

\echo '=== UJI 13: Verifikasi integritas seluruh jurnal POSTED (hash & rantai)'
SELECT reference_no, left(stored_hash, 16) || '...' AS hash_tersimpan,
       left(computed_hash, 16) || '...' AS hash_dihitung_ulang, hash_valid, chain_valid
  FROM rpc_verify_journal_integrity();

\echo '=== UJI 14: Simulasi peretas/DBA nakal mematikan trigger & mengubah nominal langsung'
BEGIN;
ALTER TABLE journal_lines DISABLE TRIGGER USER;
UPDATE journal_lines SET credit = 100000
 WHERE header_id = (SELECT id FROM journal_headers WHERE reference_no = 'JU-0001') AND credit > 0;
UPDATE journal_lines SET debit = 100000
 WHERE header_id = (SELECT id FROM journal_headers WHERE reference_no = 'JU-0001') AND debit > 0;
\echo '    -> hasil verifikasi setelah manipulasi:'
SELECT reference_no, hash_valid, chain_valid FROM rpc_verify_journal_integrity() WHERE NOT hash_valid OR NOT chain_valid;
ROLLBACK;
\echo '    -> (ROLLBACK: data dikembalikan seperti semula)'

\echo '=== UJI 15: Mengubah / menghapus audit_log -> DITOLAK'
UPDATE audit_log SET actor = 'orang lain' WHERE id = 1;
DELETE FROM audit_log;

\echo '=== CUPLIKAN AUDIT LOG (10 terbaru)'
SELECT id, table_name, record_id, action, actor, summary FROM rpc_list_audit_log(10);

\echo '=== DAFTAR JURNAL POSTED: created_by, created_at, hash'
SELECT reference_no, journal_type, created_by, to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') AS created_at,
       left(prev_hash, 10) || '...' AS prev_hash, left(hash_checksum, 10) || '...' AS hash_checksum
  FROM journal_headers WHERE posting_status = 'POSTED' ORDER BY post_seq;
