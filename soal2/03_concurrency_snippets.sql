-- =====================================================================
-- SOAL 2.2 - Penanganan Concurrency (Race Condition) - Cuplikan Kode
-- =====================================================================
-- Skenario: stok tinggal 1 unit, Kasir A dan Kasir B menjual item yang
-- sama pada detik yang sama.

-- ---------------------------------------------------------------------
-- (X) POLA SALAH - "baca, cek di aplikasi, lalu tulis" (lost update)
-- ---------------------------------------------------------------------
-- Kasir A & B sama-sama membaca stok = 1, sama-sama lolos pengecekan,
-- lalu sama-sama menulis stok = 0  ->  2 unit terjual padahal stok 1
-- (overselling / phantom stock). Lihat demo A di concurrency_demo.sh.
--
--   SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-002';   -- dapat 1
--   -- if (stok >= qty) di aplikasi ...
--   UPDATE inventory_items SET stock_qty = 0 WHERE item_id = 'BRG-002';

-- ---------------------------------------------------------------------
-- (1) PESSIMISTIC LOCKING - SELECT ... FOR UPDATE   (dipakai di trigger)
-- ---------------------------------------------------------------------
-- Baris item dikunci sejak dibaca. Transaksi kedua MENUNGGU sampai
-- transaksi pertama COMMIT, lalu membaca stok terbaru (0) dan ditolak.
BEGIN;  -- isolasi default READ COMMITTED sudah cukup

    SELECT stock_qty
      FROM inventory_items
     WHERE item_id = 'BRG-002'
       FOR UPDATE;                 -- kunci baris; kasir lain antre di sini

    -- trigger trg_update_stock_and_journal() juga melakukan FOR UPDATE
    -- dan RAISE EXCEPTION bila stok tidak cukup
    INSERT INTO inventory_transactions (item_id, trx_type, qty)
    VALUES ('BRG-002', 'SALE', 1);

COMMIT;
-- Opsi: SELECT ... FOR UPDATE NOWAIT  -> langsung error bila sedang dikunci
--       SET lock_timeout = '3s';      -> batasi lama menunggu antrean kunci

-- ---------------------------------------------------------------------
-- (2) ISOLASI SERIALIZABLE + retry
-- ---------------------------------------------------------------------
-- PostgreSQL mendeteksi bahwa dua transaksi saling bergantung; salah satu
-- dibatalkan dengan SQLSTATE 40001 (serialization_failure) dan aplikasi
-- WAJIB mengulang (retry) transaksi tersebut.
BEGIN ISOLATION LEVEL SERIALIZABLE;

    SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-002';
    UPDATE inventory_items SET stock_qty = stock_qty - 1 WHERE item_id = 'BRG-002';

COMMIT;  -- kasir kedua: ERROR 40001 could not serialize access ... -> retry

-- ---------------------------------------------------------------------
-- (3) ATOMIC CONDITIONAL UPDATE (alternatif ringkas)
-- ---------------------------------------------------------------------
-- Pengecekan dan pengurangan dalam SATU perintah. Baris yang sedang
-- diubah transaksi lain akan ditunggu lalu kondisi WHERE dievaluasi ulang.
UPDATE inventory_items
   SET stock_qty = stock_qty - 1
 WHERE item_id = 'BRG-002'
   AND stock_qty >= 1
RETURNING stock_qty;        -- 0 baris kembali = stok habis -> tolak penjualan

-- (4) Lapis terakhir: CHECK (stock_qty >= 0) pada inventory_items
--     (sudah ditambahkan di 01_inventory_trigger.sql).

-- ---------------------------------------------------------------------
-- Contoh di sisi aplikasi (Node.js + node-postgres) dengan retry 40001
-- ---------------------------------------------------------------------
-- async function jual(pool, itemId, qty) {
--   for (let percobaan = 1; percobaan <= 3; percobaan++) {
--     const client = await pool.connect();
--     try {
--       await client.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
--       await client.query(
--         'INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ($1, $2, $3)',
--         [itemId, 'SALE', qty]);
--       await client.query('COMMIT');
--       return { ok: true };
--     } catch (err) {
--       await client.query('ROLLBACK');
--       if (err.code === '40001' && percobaan < 3) continue;   // konflik -> ulangi
--       return { ok: false, pesan: err.message };              // mis. stok tidak cukup
--     } finally {
--       client.release();
--     }
--   }
-- }
