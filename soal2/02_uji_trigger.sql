-- =====================================================================
-- SOAL 2.1 - Skrip Uji Trigger (jalankan setelah 01_inventory_trigger.sql)
-- =====================================================================
\set ON_ERROR_STOP off
\set VERBOSITY default

\echo '=== UJI 1: PURCHASE 10 unit Palet Kayu @150.000 -> stok 0 -> 10, jurnal Dr Persediaan / Cr Utang Usaha'
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'PURCHASE', 10);

\echo '=== UJI 2: SALE 4 unit -> stok 10 -> 6, jurnal Dr HPP / Cr Persediaan'
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 4);

\echo '=== UJI 3: ADJUSTMENT -1 (barang rusak saat stock opname) -> stok 6 -> 5'
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'ADJUSTMENT', -1);

\echo '=== UJI 4: SALE 6 unit padahal stok 5 -> HARUS DITOLAK (RAISE EXCEPTION), stok tetap 5'
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 6);

\echo '=== UJI 5: SALE qty negatif (trik mengakali stok) -> HARUS DITOLAK'
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', -3);

\echo '=== UJI 6: Rollback menyeluruh - 2 penjualan dalam 1 transaksi, yang kedua gagal'
BEGIN;
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 3);  -- ok (stok 5 -> 2)
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 3);  -- gagal (2 < 3)
COMMIT;   -- otomatis menjadi ROLLBACK; penjualan pertama ikut batal
\echo '    -> stok harus tetap 5 (penjualan pertama ikut dibatalkan)'

\set VERBOSITY terse
\echo '=== POSISI STOK'
SELECT item_id, item_name, stock_qty, unit_cost, stock_qty * unit_cost AS nilai_persediaan
  FROM inventory_items ORDER BY item_id;

\echo '=== LOG MUTASI & TAUTAN JURNAL'
SELECT t.trx_id, t.item_id, t.trx_type, t.qty, h.reference_no, h.posting_status
  FROM inventory_transactions t
  LEFT JOIN journal_headers h ON h.id = t.journal_header_id
 ORDER BY t.trx_id;

\echo '=== JURNAL OTOMATIS DI BUKU BESAR'
SELECT h.reference_no, a.account_code, a.account_name, l.debit, l.credit
  FROM journal_headers h
  JOIN journal_lines l     ON l.header_id = h.id
  JOIN chart_of_accounts a ON a.account_id = l.account_id
 WHERE h.reference_no LIKE 'INV-%'
 ORDER BY h.id, l.id;

\echo '=== REKONSILIASI: saldo akun Persediaan (GL) = nilai stok fisik?'
SELECT
  (SELECT SUM(l.debit - l.credit) FROM journal_lines l
     JOIN chart_of_accounts a ON a.account_id = l.account_id
    WHERE a.account_code = '1301')                         AS saldo_gl_persediaan,
  (SELECT SUM(stock_qty * unit_cost) FROM inventory_items) AS nilai_stok_fisik;
