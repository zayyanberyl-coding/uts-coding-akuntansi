-- =====================================================================
-- SOAL 1 - Skrip Uji (jalankan setelah 01_schema_general_ledger.sql)
-- psql: \i soal1/02_uji_soal1.sql   (tiap uji berdiri sendiri)
-- =====================================================================
\set ON_ERROR_STOP off
\set VERBOSITY terse

\echo '=== UJI 1: Jurnal seimbang (Debit 500.000 = Kredit 500.000) -> HARUS BERHASIL'
BEGIN;
INSERT INTO journal_headers (transaction_date, reference_no, description)
VALUES ('2026-10-01', 'JU-0001', 'Pembayaran sewa bulan Oktober');
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
    ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0001'),
     (SELECT account_id FROM chart_of_accounts WHERE account_code = '6103'), 500000, 0),
    ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0001'),
     (SELECT account_id FROM chart_of_accounts WHERE account_code = '1101'), 0, 500000);
UPDATE journal_headers SET posting_status = 'POSTED' WHERE reference_no = 'JU-0001';
COMMIT;

\echo '=== UJI 2: Jurnal TIDAK seimbang dikirim langsung (simulasi API) -> HARUS DITOLAK saat COMMIT'
BEGIN;
INSERT INTO journal_headers (transaction_date, reference_no, description)
VALUES ('2026-10-02', 'JU-0002', 'Transaksi lewat API tanpa pasangan valid');
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
    ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0002'),
     (SELECT account_id FROM chart_of_accounts WHERE account_code = '6102'), 750000, 0),
    ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0002'),
     (SELECT account_id FROM chart_of_accounts WHERE account_code = '1101'), 0, 700000);
COMMIT;

\echo '=== UJI 3: Nominal debit negatif -> HARUS DITOLAK (ck_lines_debit_nonneg)'
INSERT INTO journal_lines (header_id, account_id, debit, credit)
VALUES ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0001'), 1, -100, 0);

\echo '=== UJI 4: Debit dan kredit sama-sama nol -> HARUS DITOLAK (ck_lines_not_both_zero)'
INSERT INTO journal_lines (header_id, account_id, debit, credit)
VALUES ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0001'), 1, 0, 0);

\echo '=== UJI 5: Hapus akun Kas yang sudah dipakai jurnal -> HARUS DITOLAK (ON DELETE RESTRICT)'
DELETE FROM chart_of_accounts WHERE account_code = '1101';

\echo '=== UJI 6: Hapus header jurnal yang punya baris -> HARUS DITOLAK (ON DELETE RESTRICT)'
DELETE FROM journal_headers WHERE reference_no = 'JU-0001';

\echo '=== UJI 7: Posting jurnal yang baru punya 0 baris -> HARUS DITOLAK'
BEGIN;
INSERT INTO journal_headers (transaction_date, reference_no, description)
VALUES ('2026-10-03', 'JU-0003', 'Jurnal kosong');
UPDATE journal_headers SET posting_status = 'POSTED' WHERE reference_no = 'JU-0003';
ROLLBACK;

\echo '=== UJI 8: Akun tidak terdaftar di bagan akun -> HARUS DITOLAK (FOREIGN KEY)'
INSERT INTO journal_lines (header_id, account_id, debit, credit)
VALUES ((SELECT id FROM journal_headers WHERE reference_no = 'JU-0001'), 9999, 100, 0);

\echo '=== HASIL AKHIR: hanya jurnal JU-0001 yang tersimpan, dan seimbang'
SELECT h.reference_no, h.posting_status, a.account_code, a.account_name, l.debit, l.credit
  FROM journal_headers h
  JOIN journal_lines l     ON l.header_id = h.id
  JOIN chart_of_accounts a ON a.account_id = l.account_id
 ORDER BY h.id, l.id;

SELECT h.reference_no, SUM(l.debit) AS total_debit, SUM(l.credit) AS total_kredit
  FROM journal_headers h JOIN journal_lines l ON l.header_id = h.id
 GROUP BY h.reference_no;
