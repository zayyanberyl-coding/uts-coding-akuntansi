-- Uji tindak lanjut temuan NotebookLM (jalankan setelah 04_perbaikan_hasil_notebooklm.sql)
\set ON_ERROR_STOP off
\set VERBOSITY terse
\i soal3/supabase/06_seed_modal_awal.sql

SELECT set_config('request.jwt.claims', '{"email":"zayyan@demo.uts","role":"authenticated"}', false) \g /dev/null

\echo '=== UJI 1: Mutasi internal Bank -> Kas Kecil lewat voucher KAS KELUAR -> DITOLAK (bukan arus kas keluar)'
SELECT rpc_create_cash_voucher(CURRENT_DATE, 'BKK-TES-MUTASI', 'Isi kas kecil',
  '[{"account_code":"1103","debit":2000000,"credit":0},{"account_code":"1102","debit":0,"credit":2000000}]');

\echo '=== UJI 2: Mutasi yang sama lewat rpc_create_cash_transfer -> BERHASIL (jenis MUTASI_KAS)'
SELECT rpc_create_cash_transfer(CURRENT_DATE, 'MK-0001', 'Pengisian kas kecil dari bank', '1102', '1103', 2000000) ->> 'reference_no' AS mutasi;

\echo '=== UJI 3: Penempatan deposito 3 bulan (setara kas) dari Bank -> BERHASIL sebagai MUTASI_KAS'
SELECT rpc_create_cash_transfer(CURRENT_DATE, 'MK-0002', 'Penempatan deposito 3 bulan', '1102', '1104', 5000000) ->> 'reference_no' AS mutasi;

\echo '=== UJI 4: Deposito > 3 bulan (1105) BUKAN setara kas -> mutasi DITOLAK'
SELECT rpc_create_cash_transfer(CURRENT_DATE, 'MK-0003', 'Deposito 6 bulan', '1102', '1105', 5000000);

\echo '=== UJI 5: Voucher kas keluar operasi dengan aktivitas eksplisit'
SELECT rpc_create_cash_voucher(CURRENT_DATE, 'BKK-TES-OPS', 'Bayar gaji', 
  '[{"account_code":"6101","debit":3000000,"credit":0},{"account_code":"1101","debit":0,"credit":3000000}]', 'OPERASI') ->> 'cash_flow_activity' AS aktivitas;

\echo '=== SALDO KAS & SETARA KAS (cerukan bank terdeteksi bila saldo Bank negatif)'
SELECT account_code, account_name, category, saldo, penyajian FROM v_kas_dan_setara_kas;

\echo '=== ARUS KAS PER AKTIVITAS (MUTASI_KAS dikecualikan)'
SELECT * FROM v_arus_kas_per_aktivitas;

\echo '=== Integritas hash setelah perubahan skema'
SELECT COUNT(*) FILTER (WHERE hash_valid AND chain_valid) AS valid, COUNT(*) AS total FROM rpc_verify_journal_integrity();
