-- =====================================================================
-- SOAL 2 - Otomasi Persediaan Perpetual via Database Trigger
-- PT Diponegoro Logistik Utama
-- Zayyan Beryl - 12030124140283 - Pengkodean dan Pemrograman Kelas E
-- Prasyarat: soal1/01_schema_general_ledger.sql (tabel GL & bagan akun)
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Struktur tabel sesuai soal (tidak diubah)
-- ---------------------------------------------------------------------
CREATE TABLE inventory_items (
    item_id   VARCHAR(10) PRIMARY KEY,
    item_name VARCHAR(100),
    stock_qty INT NOT NULL DEFAULT 0,
    unit_cost NUMERIC(15, 2) NOT NULL
);

CREATE TABLE inventory_transactions (
    trx_id   SERIAL PRIMARY KEY,
    item_id  VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty      INT NOT NULL,
    trx_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- B. Penguatan tambahan (defense in depth)
-- ---------------------------------------------------------------------
-- Lapis pengaman terakhir: walaupun ada kode lain yang meng-UPDATE stok
-- langsung (tanpa lewat trigger), stok tetap tidak bisa negatif.
ALTER TABLE inventory_items
    ADD CONSTRAINT ck_items_stock_nonneg CHECK (stock_qty >= 0),
    ADD CONSTRAINT ck_items_cost_nonneg  CHECK (unit_cost >= 0);

-- Item & jenis transaksi wajib diisi; tautan ke jurnal buku besar
-- yang dibuat otomatis (jejak audit dua arah: mutasi <-> jurnal).
ALTER TABLE inventory_transactions
    ALTER COLUMN item_id  SET NOT NULL,
    ALTER COLUMN trx_type SET NOT NULL,
    ADD COLUMN journal_header_id BIGINT REFERENCES journal_headers(id) ON DELETE RESTRICT;

-- ---------------------------------------------------------------------
-- C. Helper: membuat jurnal 2 baris (DRAFT -> isi baris -> POSTED)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_post_simple_journal(
    p_date        DATE,
    p_reference   VARCHAR,
    p_description TEXT,
    p_debit_acc   VARCHAR,     -- kode akun yang didebit
    p_credit_acc  VARCHAR,     -- kode akun yang dikredit
    p_amount      NUMERIC
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_header_id BIGINT;
BEGIN
    INSERT INTO journal_headers (transaction_date, reference_no, description)
    VALUES (p_date, p_reference, p_description)
    RETURNING id INTO v_header_id;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_header_id, account_id, p_amount, 0 FROM chart_of_accounts WHERE account_code = p_debit_acc
    UNION ALL
    SELECT v_header_id, account_id, 0, p_amount FROM chart_of_accounts WHERE account_code = p_credit_acc;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v_header_id;
    RETURN v_header_id;
END;
$$;

-- =====================================================================
-- 2.1  TRIGGER FUNCTION trg_update_stock_and_journal()
-- =====================================================================
-- Dijalankan BEFORE INSERT setiap baris inventory_transactions:
--   a. Mengunci baris item (SELECT ... FOR UPDATE) -> aman dari race condition
--   b. Menghitung saldo baru & memperbarui inventory_items.stock_qty
--   c. RAISE EXCEPTION bila SALE (atau ADJUSTMENT keluar) membuat stok < 0
--      -> seluruh transaksi dibatalkan (rollback), tidak ada data setengah jadi
--   d. Membuat jurnal Persediaan / HPP otomatis di buku besar, sehingga
--      saldo fisik dan saldo akun tidak pernah "terlambat dimutakhirkan".
--
-- Pemetaan jurnal (nilai = qty x unit_cost):
--   PURCHASE          : Dr 1301 Persediaan            / Cr 2101 Utang Usaha
--   SALE              : Dr 5101 HPP                   / Cr 1301 Persediaan
--   ADJUSTMENT (+)    : Dr 1301 Persediaan            / Cr 4901 Pendapatan Selisih Persediaan
--   ADJUSTMENT (-)    : Dr 5901 Beban Selisih Persed. / Cr 1301 Persediaan
-- Konvensi qty: PURCHASE & SALE wajib positif; ADJUSTMENT bertanda
-- (+ = barang masuk/retur penjualan, - = barang keluar/rusak/hilang).
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_item      inventory_items%ROWTYPE;
    v_delta     INT;            -- perubahan stok (+ masuk, - keluar)
    v_new_stock INT;
    v_amount    NUMERIC(18,2);
    v_debit     VARCHAR(10);
    v_credit    VARCHAR(10);
    v_desc      TEXT;
BEGIN
    -- 1) Validasi kuantitas sesuai jenis transaksi
    IF NEW.trx_type IN ('PURCHASE', 'SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'Qty % untuk transaksi % harus lebih dari 0', NEW.qty, NEW.trx_type;
    ELSIF NEW.trx_type = 'ADJUSTMENT' AND NEW.qty = 0 THEN
        RAISE EXCEPTION 'Qty ADJUSTMENT tidak boleh 0';
    END IF;

    -- 2) Kunci baris item. Transaksi lain pada item yang SAMA harus
    --    menunggu sampai transaksi ini COMMIT/ROLLBACK (lihat Soal 2.2).
    SELECT * INTO v_item
      FROM inventory_items
     WHERE item_id = NEW.item_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % tidak terdaftar', NEW.item_id;
    END IF;

    -- 3) Hitung saldo baru
    v_delta := CASE NEW.trx_type
                   WHEN 'PURCHASE'   THEN  NEW.qty
                   WHEN 'SALE'       THEN -NEW.qty
                   WHEN 'ADJUSTMENT' THEN  NEW.qty
               END;
    v_new_stock := v_item.stock_qty + v_delta;

    -- 4) Anti-negative inventory prevention
    IF v_new_stock < 0 THEN
        RAISE EXCEPTION
            'Transaksi % ditolak: stok % (%) hanya % unit, diminta % unit. Stok tidak boleh negatif.',
            NEW.trx_type, v_item.item_id, v_item.item_name, v_item.stock_qty, ABS(v_delta)
            USING ERRCODE = 'check_violation',
                  HINT    = 'Periksa stok fisik atau catat PURCHASE/ADJUSTMENT terlebih dahulu.';
    END IF;

    -- 5) Mutakhirkan saldo fisik
    UPDATE inventory_items
       SET stock_qty = v_new_stock
     WHERE item_id = NEW.item_id;

    -- 6) Mutakhirkan buku besar secara otomatis (Persediaan & HPP)
    v_amount := ABS(v_delta) * v_item.unit_cost;

    IF NEW.trx_type = 'PURCHASE' THEN
        v_debit := '1301'; v_credit := '2101';
        v_desc  := 'Pembelian persediaan';
    ELSIF NEW.trx_type = 'SALE' THEN
        v_debit := '5101'; v_credit := '1301';
        v_desc  := 'HPP atas penjualan';
    ELSIF v_delta > 0 THEN
        v_debit := '1301'; v_credit := '4901';
        v_desc  := 'Penyesuaian persediaan (tambah)';
    ELSE
        v_debit := '5901'; v_credit := '1301';
        v_desc  := 'Penyesuaian persediaan (kurang)';
    END IF;

    IF v_amount > 0 THEN
        NEW.journal_header_id := fn_post_simple_journal(
            COALESCE(NEW.trx_date, CURRENT_TIMESTAMP)::DATE,
            'INV-' || LPAD(NEW.trx_id::TEXT, 6, '0'),
            format('%s %s x %s @ Rp%s', v_desc, ABS(v_delta), v_item.item_name, v_item.unit_cost),
            v_debit, v_credit, v_amount);
    END IF;

    RETURN NEW;   -- baris mutasi disimpan bersama tautan jurnalnya
END;
$$;

CREATE TRIGGER trg_update_stock_and_journal
    BEFORE INSERT ON inventory_transactions
    FOR EACH ROW
    EXECUTE FUNCTION trg_update_stock_and_journal();

-- Data contoh
INSERT INTO inventory_items (item_id, item_name, stock_qty, unit_cost) VALUES
    ('BRG-001', 'Palet Kayu Standar', 0, 150000),
    ('BRG-002', 'Stretch Film 50cm',  0,  85000),
    ('BRG-003', 'Kardus Ekspor Besar',0,  12500);
