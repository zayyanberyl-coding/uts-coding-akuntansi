#!/usr/bin/env bash
# =====================================================================
# SOAL 2.2 - Simulasi 2 kasir menjual item yang sama secara bersamaan
# Pemakaian: DB=uts ./soal2/concurrency_demo.sh   (butuh psql)
# =====================================================================
DB="${DB:-uts}"
export PGTZ="Asia/Jakarta"
PSQL="psql -q -X -d $DB -v VERBOSITY=terse"

echo "################################################################"
echo "# DEMO A - TANPA PENGUNCIAN (pola baca-cek-tulis di aplikasi)"
echo "################################################################"
$PSQL <<'SQL'
DROP TABLE IF EXISTS demo_naive_items, demo_naive_sales;
CREATE TABLE demo_naive_items (item_id TEXT PRIMARY KEY, stock_qty INT);   -- tanpa CHECK, tanpa trigger
CREATE TABLE demo_naive_sales (kasir TEXT, waktu TIMESTAMPTZ DEFAULT clock_timestamp());
INSERT INTO demo_naive_items VALUES ('BRG-002', 1);
SQL

kasir_naive () {
$PSQL -v kasir="$1" <<'SQL'
BEGIN;
SELECT stock_qty AS stok, stock_qty >= 1 AS cukup FROM demo_naive_items WHERE item_id = 'BRG-002' \gset
\echo [:kasir] membaca stok = :stok
SELECT pg_sleep(1) \g /dev/null
-- (jeda 1 detik: proses di kasir)
\if :cukup
  UPDATE demo_naive_items SET stock_qty = :stok - 1 WHERE item_id = 'BRG-002';
  INSERT INTO demo_naive_sales (kasir) VALUES (:'kasir');
  \echo [:kasir] PENJUALAN BERHASIL
\endif
COMMIT;
SQL
}
kasir_naive "Kasir A" & kasir_naive "Kasir B" & wait
$PSQL -c "SELECT (SELECT stock_qty FROM demo_naive_items) AS stok_akhir, (SELECT COUNT(*) FROM demo_naive_sales) AS unit_terjual;"
echo ">> MASALAH: 2 unit terjual padahal stok hanya 1 (overselling / phantom stock)."
echo

echo "################################################################"
echo "# DEMO B - SELECT ... FOR UPDATE (di dalam trg_update_stock_and_journal)"
echo "################################################################"
$PSQL -c "INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002','PURCHASE',1);"
$PSQL -c "SELECT item_id, item_name, stock_qty AS stok_awal FROM inventory_items WHERE item_id='BRG-002';"

kasir_lock () {
$PSQL -v kasir="$1" <<'SQL'
\set ON_ERROR_STOP on
SELECT to_char(clock_timestamp(),'HH24:MI:SS.MS') AS t \gset
\echo [:kasir] :t BEGIN + INSERT SALE 1 unit BRG-002
BEGIN;
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002', 'SALE', 1);
SELECT to_char(clock_timestamp(),'HH24:MI:SS.MS') AS t \gset
\echo [:kasir] :t INSERT lolos, baris item TERKUNCI (FOR UPDATE). Proses pembayaran 3 detik...
SELECT pg_sleep(3) \g /dev/null
COMMIT;
SELECT to_char(clock_timestamp(),'HH24:MI:SS.MS') AS t \gset
\echo [:kasir] :t COMMIT - PENJUALAN BERHASIL
SQL
}
kasir_lock "Kasir A" 2>&1 | sed 's/^\(psql:<stdin>:[0-9]*: \)\{0,1\}ERROR/[Kasir A] ERROR/' &
sleep 0.5
{ kasir_lock "Kasir B" 2>&1 | sed 's/^\(psql:<stdin>:[0-9]*: \)\{0,1\}ERROR/[Kasir B] ERROR/'
  echo "[Kasir B] $(date +%T.%3N) transaksi dibatalkan (ROLLBACK) setelah menunggu kunci Kasir A"; } &
wait
$PSQL -c "SELECT stock_qty AS stok_akhir FROM inventory_items WHERE item_id='BRG-002';"
$PSQL -c "SELECT trx_id, trx_type, qty FROM inventory_transactions WHERE item_id='BRG-002' ORDER BY trx_id;"
echo ">> HASIL: hanya 1 penjualan tersimpan, Kasir B ditolak setelah Kasir A commit. Stok = 0, tidak negatif."
echo

echo "################################################################"
echo "# DEMO C - ISOLASI SERIALIZABLE"
echo "################################################################"
$PSQL -c "UPDATE demo_naive_items SET stock_qty = 1; TRUNCATE demo_naive_sales;"
kasir_serial () {
$PSQL -v kasir="$1" <<'SQL'
\set ON_ERROR_STOP on
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT stock_qty AS stok, stock_qty >= 1 AS cukup FROM demo_naive_items WHERE item_id = 'BRG-002' \gset
\echo [:kasir] (SERIALIZABLE) membaca stok = :stok
SELECT pg_sleep(1) \g /dev/null
\if :cukup
  UPDATE demo_naive_items SET stock_qty = :stok - 1 WHERE item_id = 'BRG-002';
  INSERT INTO demo_naive_sales (kasir) VALUES (:'kasir');
\endif
COMMIT;
\echo [:kasir] COMMIT - PENJUALAN BERHASIL
SQL
}
kasir_serial "Kasir A" 2>&1 | sed 's/^\(psql:<stdin>:[0-9]*: \)\{0,1\}ERROR/[Kasir A] ERROR/' &
kasir_serial "Kasir B" 2>&1 | sed 's/^\(psql:<stdin>:[0-9]*: \)\{0,1\}ERROR/[Kasir B] ERROR/' &
wait
$PSQL -c "SELECT (SELECT stock_qty FROM demo_naive_items) AS stok_akhir, (SELECT COUNT(*) FROM demo_naive_sales) AS unit_terjual;"
echo ">> HASIL: salah satu kasir mendapat ERROR 40001 (serialization failure) dan harus retry; tidak ada overselling."
$PSQL -c "DROP TABLE demo_naive_items, demo_naive_sales;"
