# Soal 2: Otomasi Bisnis, Stored Procedure & Database Trigger Persediaan

File terkait: `soal2/01_inventory_trigger.sql`, `soal2/02_uji_trigger.sql`, `soal2/03_concurrency_snippets.sql`, `soal2/concurrency_demo.sh`, `bukti/uji_soal2_trigger.txt`, `bukti/uji_soal2_concurrency.txt`

## 2.1 Otomatisasi Mutasi via Database Trigger

### Cara kerja `trg_update_stock_and_journal()`

Trigger dipasang `BEFORE INSERT ... FOR EACH ROW` pada `inventory_transactions`. Untuk setiap mutasi, langkahnya:

1. **Validasi qty.** `PURCHASE` dan `SALE` wajib > 0. `ADJUSTMENT` boleh bertanda (+ untuk barang masuk atau retur, − untuk rusak atau hilang) tetapi tidak boleh 0. Ini mencegah trik "SALE qty negatif" untuk menambah stok.
2. **Mengunci baris item** dengan `SELECT ... FOR UPDATE`. Transaksi lain pada item yang sama harus antre (lihat 2.2).
3. **Menghitung saldo baru**: `stock_qty + delta` (PURCHASE +, SALE −, ADJUSTMENT ±).
4. **Anti-negative inventory**: bila saldo baru < 0, dijalankan `RAISE EXCEPTION`. Seluruh transaksi database **dibatalkan** (rollback), termasuk baris mutasi dan jurnalnya, sehingga tidak ada data setengah jadi.
5. **Memperbarui `inventory_items.stock_qty`.**
6. **Memutakhirkan buku besar secara otomatis.** Ini menjawab akar masalah PT Diponegoro Logistik Utama (saldo fisik berubah tetapi akun Persediaan/HPP terlambat diperbarui). Jurnal dibuat dalam transaksi yang **sama** dengan mutasi stok:

| Jenis mutasi | Debit | Kredit |
|---|---|---|
| PURCHASE | 1301 Persediaan Barang Dagang | 2101 Utang Usaha |
| SALE | 5101 Beban Pokok Pendapatan (HPP) | 1301 Persediaan Barang Dagang |
| ADJUSTMENT (+) | 1301 Persediaan Barang Dagang | 4901 Pendapatan Selisih Persediaan |
| ADJUSTMENT (−) | 5901 Beban Selisih Persediaan | 1301 Persediaan Barang Dagang |

Nilai jurnal = qty × `unit_cost`. Nomor jurnal `INV-<trx_id>` disimpan di kolom `journal_header_id`, sehingga setiap mutasi bisa ditelusuri ke jurnalnya dan sebaliknya.

Kode inti:

```sql
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_item inventory_items%ROWTYPE;  v_delta INT;  v_new_stock INT;
BEGIN
    SELECT * INTO v_item FROM inventory_items
     WHERE item_id = NEW.item_id FOR UPDATE;            -- kunci baris

    v_delta := CASE NEW.trx_type WHEN 'PURCHASE' THEN NEW.qty
                                 WHEN 'SALE'     THEN -NEW.qty
                                 ELSE NEW.qty END;
    v_new_stock := v_item.stock_qty + v_delta;

    IF v_new_stock < 0 THEN                              -- (b) anti-negative
        RAISE EXCEPTION 'Transaksi % ditolak: stok % hanya % unit, diminta % unit.',
              NEW.trx_type, v_item.item_id, v_item.stock_qty, ABS(v_delta);
    END IF;

    UPDATE inventory_items SET stock_qty = v_new_stock    -- (a) update stok
     WHERE item_id = NEW.item_id;

    -- (+) jurnal Persediaan/HPP otomatis -> NEW.journal_header_id
    ...
    RETURN NEW;
END; $$;

CREATE TRIGGER trg_update_stock_and_journal
    BEFORE INSERT ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();
```

Sebagai lapis pengaman terakhir ditambahkan juga `CHECK (stock_qty >= 0)` pada `inventory_items`, sehingga stok tidak bisa negatif walaupun ada kode lain yang meng-UPDATE stok tanpa melalui trigger.

### Hasil uji (`bukti/uji_soal2_trigger.txt`)

| No | Skenario | Stok | Hasil |
|---|---|---|---|
| 1 | PURCHASE 10 Palet Kayu @150.000 | 0 → 10 | ✅ Jurnal Dr Persediaan 1.500.000 / Cr Utang Usaha |
| 2 | SALE 4 | 10 → 6 | ✅ Jurnal Dr HPP 600.000 / Cr Persediaan |
| 3 | ADJUSTMENT −1 (rusak saat opname) | 6 → 5 | ✅ Jurnal Dr Beban Selisih 150.000 / Cr Persediaan |
| 4 | SALE 6 padahal stok 5 | tetap 5 | ❌ `RAISE EXCEPTION` stok tidak boleh negatif |
| 5 | SALE qty −3 | tetap 5 | ❌ Qty harus > 0 |
| 6 | Dua SALE (3 + 3) dalam satu transaksi | tetap 5 | ❌ SALE kedua gagal, **SALE pertama ikut dibatalkan** |

**Rekonsiliasi:** saldo akun 1301 Persediaan di buku besar = Rp750.000 = nilai stok fisik (5 × Rp150.000). Tidak ada selisih saat stock opname.

## 2.2 Penanganan Concurrency (Race Condition)

### Masalahnya

Misalnya stok tinggal 1 unit. Kasir A dan Kasir B sama-sama membaca stok = 1, sama-sama lolos pengecekan "stok ≥ 1", lalu sama-sama menulis stok = 0. Hasilnya **2 unit terjual padahal stok hanya 1**. Ini disebut *lost update* yang menimbulkan *overselling / phantom stock*.

### Teknik yang diterapkan

**1. Pessimistic locking: `SELECT ... FOR UPDATE` (dipakai di dalam trigger).**
Baris item dikunci sejak dibaca. Kasir B tidak bisa membaca-untuk-mengubah baris yang sama sampai Kasir A selesai (COMMIT/ROLLBACK). Setelah itu Kasir B membaca stok **terbaru** (0) dan ditolak oleh `RAISE EXCEPTION`. Isolasi default `READ COMMITTED` sudah cukup karena penguncian bersifat eksplisit.

```sql
BEGIN;
  SELECT stock_qty FROM inventory_items
   WHERE item_id = 'BRG-002'
     FOR UPDATE;                     -- kasir lain antre di sini
  INSERT INTO inventory_transactions (item_id, trx_type, qty)
  VALUES ('BRG-002', 'SALE', 1);     -- trigger: cek stok & update
COMMIT;
-- opsional: FOR UPDATE NOWAIT  atau  SET lock_timeout = '3s';
```

**2. Isolasi `SERIALIZABLE` + retry.**
PostgreSQL mendeteksi bahwa dua transaksi saling bergantung, lalu membatalkan salah satunya dengan `ERROR 40001 could not serialize access`. Aplikasi **wajib mengulang** (retry) transaksi yang gagal.

```sql
BEGIN ISOLATION LEVEL SERIALIZABLE;
  SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-002';
  UPDATE inventory_items SET stock_qty = stock_qty - 1 WHERE item_id = 'BRG-002';
COMMIT;   -- transaksi yang kalah: SQLSTATE 40001 -> retry
```

Contoh retry di sisi aplikasi (Node.js) ada di `soal2/03_concurrency_snippets.sql`.

**3. Alternatif ringkas: atomic conditional update.**
`UPDATE ... SET stock_qty = stock_qty - 1 WHERE item_id = $1 AND stock_qty >= 1 RETURNING stock_qty;` Pengecekan dan pengurangan terjadi dalam satu perintah. Bila tidak ada baris yang kembali, stok habis.

**4. Lapis terakhir:** `CHECK (stock_qty >= 0)`.

### Bukti simulasi dua kasir (`soal2/concurrency_demo.sh` → `bukti/uji_soal2_concurrency.txt`)

| Demo | Teknik | Hasil |
|---|---|---|
| A | Tanpa penguncian (baca-cek-tulis di aplikasi) | ❌ Kedua kasir berhasil: **2 unit terjual, stok 1** (overselling) |
| B | `SELECT ... FOR UPDATE` di trigger | ✅ Kasir B mulai 0,5 detik setelah A, **tertahan ±2,5 detik** sampai A commit, lalu ditolak "stok hanya 0 unit". Hanya 1 penjualan tersimpan. |
| C | `SERIALIZABLE` | ✅ Kasir B mendapat `ERROR 40001`, hanya 1 unit terjual |

**Rekomendasi:** gunakan `FOR UPDATE` di dalam trigger (sudah diterapkan) karena sederhana, deterministik, dan tidak memerlukan logika retry. `SERIALIZABLE` cocok untuk transaksi kompleks yang membaca banyak baris, asalkan aplikasi menyediakan mekanisme retry.
