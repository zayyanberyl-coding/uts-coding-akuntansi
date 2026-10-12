-- =====================================================================
-- Data demo (tanpa perintah psql) - dijalankan di Supabase SQL Editor
-- =====================================================================
-- Jurnal umum seimbang (Soal 1)
DO $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO journal_headers (transaction_date, reference_no, description)
    VALUES (CURRENT_DATE, 'JU-0001', 'Pembayaran sewa bulan Oktober') RETURNING id INTO v_id;
    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_id, account_id, 500000, 0 FROM chart_of_accounts WHERE account_code = '6103'
    UNION ALL
    SELECT v_id, account_id, 0, 500000 FROM chart_of_accounts WHERE account_code = '1101';
    UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v_id;
END $$;

-- Mutasi persediaan (Soal 2) -> trigger membuat jurnal INV-xxxxxx otomatis
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'PURCHASE', 10);
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'SALE', 4);
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001', 'ADJUSTMENT', -1);
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-002', 'PURCHASE', 1);

-- Jalankan pemeriksaan keseimbangan (constraint trigger DEFERRED) sekarang,
-- karena SQL Editor Supabase mengeksekusi seluruh skrip dalam SATU transaksi
-- dan ALTER TABLE tidak boleh dilakukan selagi ada trigger event tertunda.
SET CONSTRAINTS ALL IMMEDIATE;
