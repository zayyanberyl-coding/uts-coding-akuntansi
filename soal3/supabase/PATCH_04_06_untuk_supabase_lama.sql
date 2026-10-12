-- =====================================================================
-- SOAL 3.1b - Tindak lanjut temuan verifikasi NotebookLM (PSAK 207)
-- Temuan: (1) setara kas belum dimodelkan, (2) mutasi antar pos kas/setara
-- kas tertolak oleh aturan kas keluar padahal bukan arus kas, (3) cerukan
-- bank belum ditangani, (4) belum ada klasifikasi aktivitas arus kas.
-- Prasyarat: soal1, soal2, soal3/01, soal3/02 sudah dijalankan.
-- =====================================================================

-- (1) Akun setara kas: investasi sangat likuid, jatuh tempo <= 3 bulan
--     SEJAK TANGGAL PEROLEHAN (PSAK 207). Deposito > 3 bulan BUKAN setara kas.
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_classification)
VALUES ('1104', 'Setara Kas - Deposito Berjangka <= 3 Bulan', 'DEBIT', 'ASET'),
       ('1105', 'Deposito Berjangka > 3 Bulan (bukan setara kas)', 'DEBIT', 'ASET');

-- Daftar akun kas & setara kas disimpan di tabel (bukan di-hardcode) agar
-- frontend, RPC dan laporan memakai definisi yang SAMA.
CREATE TABLE cash_equivalent_accounts (
    account_code VARCHAR(10) PRIMARY KEY REFERENCES chart_of_accounts(account_code) ON DELETE RESTRICT,
    category     VARCHAR(12) NOT NULL CHECK (category IN ('KAS', 'SETARA_KAS'))
);
INSERT INTO cash_equivalent_accounts VALUES
    ('1101', 'KAS'), ('1102', 'KAS'), ('1103', 'KAS'), ('1104', 'SETARA_KAS');
ALTER TABLE cash_equivalent_accounts ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON cash_equivalent_accounts FROM anon, authenticated;

-- (4) Klasifikasi aktivitas arus kas per jurnal
ALTER TABLE journal_headers DROP CONSTRAINT ck_journal_type;
ALTER TABLE journal_headers
    ADD CONSTRAINT ck_journal_type CHECK (journal_type IN
        ('UMUM', 'KAS_KELUAR', 'PERSEDIAAN', 'STORNO', 'MUTASI_KAS')),
    ADD COLUMN cash_flow_activity VARCHAR(10)
        CHECK (cash_flow_activity IN ('OPERASI', 'INVESTASI', 'PENDANAAN'));
-- Catatan: kolom baru dibuat SETELAH jurnal lama tersegel, jadi tidak masuk
-- payload hash (hash lama tetap valid). Nilainya diisi saat INSERT (DRAFT).

-- (2) RPC khusus mutasi internal kas <-> kas / setara kas
--     Contoh: setor Kas ke Bank, tarik Bank ke Kas Kecil, Bank -> deposito 3 bln.
--     Ditandai MUTASI_KAS agar DIKELUARKAN dari laporan arus kas.
CREATE OR REPLACE FUNCTION rpc_create_cash_transfer(
    p_transaction_date DATE,
    p_reference_no     TEXT,
    p_description      TEXT,
    p_from_account     TEXT,    -- dikredit
    p_to_account       TEXT,    -- didebit
    p_amount           NUMERIC
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id BIGINT; v_row journal_headers%ROWTYPE;
BEGIN
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'Akun asal dan tujuan tidak boleh sama.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cash_equivalent_accounts WHERE account_code = p_from_account)
       OR NOT EXISTS (SELECT 1 FROM cash_equivalent_accounts WHERE account_code = p_to_account) THEN
        RAISE EXCEPTION 'Mutasi kas hanya antar akun kas/setara kas (PSAK 207: bukan arus kas).';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Nominal mutasi harus > 0.';
    END IF;
    IF p_transaction_date IS NULL OR p_transaction_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Tanggal transaksi wajib diisi dan tidak boleh di masa depan.';
    END IF;

    INSERT INTO journal_headers (transaction_date, reference_no, description, journal_type)
    VALUES (p_transaction_date, trim(p_reference_no), trim(p_description), 'MUTASI_KAS')
    RETURNING id INTO v_id;

    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_id, account_id, p_amount, 0 FROM chart_of_accounts WHERE account_code = p_to_account
    UNION ALL
    SELECT v_id, account_id, 0, p_amount FROM chart_of_accounts WHERE account_code = p_from_account;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v_id RETURNING * INTO v_row;
    RETURN jsonb_build_object('id', v_row.id, 'reference_no', v_row.reference_no,
                              'hash_checksum', v_row.hash_checksum);
END;
$$;

-- Voucher kas keluar: kode kas kini dibaca dari tabel, bukan hardcode,
-- dan aktivitas arus kas wajib dipilih (default OPERASI).
CREATE OR REPLACE FUNCTION rpc_create_cash_voucher(
    p_transaction_date DATE,
    p_reference_no     TEXT,
    p_description      TEXT,
    p_lines            JSONB,
    p_activity         TEXT DEFAULT 'OPERASI'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_id BIGINT; v_line JSONB; v_acc chart_of_accounts%ROWTYPE;
    v_debit NUMERIC(18,2) := 0; v_credit NUMERIC(18,2) := 0; v_cash_cr NUMERIC(18,2) := 0;
    v_is_cash BOOLEAN; v_row journal_headers%ROWTYPE;
BEGIN
    IF p_transaction_date IS NULL OR p_transaction_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Tanggal transaksi wajib diisi dan tidak boleh di masa depan.';
    END IF;
    IF COALESCE(trim(p_reference_no), '') = '' OR COALESCE(trim(p_description), '') = '' THEN
        RAISE EXCEPTION 'Nomor bukti dan deskripsi wajib diisi.';
    END IF;
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'Voucher minimal terdiri dari 2 baris (debit & kredit).';
    END IF;
    IF p_activity NOT IN ('OPERASI', 'INVESTASI', 'PENDANAAN') THEN
        RAISE EXCEPTION 'Aktivitas arus kas harus OPERASI / INVESTASI / PENDANAAN.';
    END IF;

    INSERT INTO journal_headers (transaction_date, reference_no, description, journal_type, cash_flow_activity)
    VALUES (p_transaction_date, trim(p_reference_no), trim(p_description), 'KAS_KELUAR', p_activity)
    RETURNING id INTO v_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        SELECT * INTO v_acc FROM chart_of_accounts
         WHERE account_code = v_line ->> 'account_code' AND is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Akun % tidak terdaftar / tidak aktif.', v_line ->> 'account_code';
        END IF;
        INSERT INTO journal_lines (header_id, account_id, debit, credit)
        VALUES (v_id, v_acc.account_id, COALESCE((v_line ->> 'debit')::NUMERIC, 0),
                COALESCE((v_line ->> 'credit')::NUMERIC, 0));
        v_debit  := v_debit  + COALESCE((v_line ->> 'debit')::NUMERIC, 0);
        v_credit := v_credit + COALESCE((v_line ->> 'credit')::NUMERIC, 0);

        v_is_cash := EXISTS (SELECT 1 FROM cash_equivalent_accounts c WHERE c.account_code = v_acc.account_code);
        IF v_is_cash THEN
            IF COALESCE((v_line ->> 'debit')::NUMERIC, 0) > 0 THEN
                RAISE EXCEPTION 'Voucher kas KELUAR tidak boleh mendebit akun kas/setara kas (%). Gunakan rpc_create_cash_transfer untuk mutasi internal.', v_acc.account_name;
            END IF;
            v_cash_cr := v_cash_cr + COALESCE((v_line ->> 'credit')::NUMERIC, 0);
        END IF;
    END LOOP;

    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Zero-discrepancy dilanggar: Total Debit % <> Total Kredit %', v_debit, v_credit;
    END IF;
    IF v_cash_cr = 0 THEN
        RAISE EXCEPTION 'Voucher kas keluar wajib mengkredit akun kas/setara kas.';
    END IF;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v_id RETURNING * INTO v_row;
    RETURN jsonb_build_object('id', v_row.id, 'reference_no', v_row.reference_no, 'total', v_debit,
        'created_by', v_row.created_by, 'created_at', v_row.created_at,
        'hash_checksum', v_row.hash_checksum, 'cash_flow_activity', v_row.cash_flow_activity);
END;
$$;
-- versi lama (4 parameter) dihapus agar tidak ambigu bagi PostgREST
DROP FUNCTION IF EXISTS rpc_create_cash_voucher(DATE, TEXT, TEXT, JSONB);

-- (3) Saldo kas & setara kas, dengan cerukan bank (saldo kredit akun Bank)
--     disajikan sebagai liabilitas jangka pendek di neraca, namun tetap
--     mengurangi kas & setara kas di laporan arus kas bila merupakan bagian
--     dari pengelolaan kas.
CREATE OR REPLACE VIEW v_kas_dan_setara_kas AS
SELECT a.account_code, a.account_name, c.category,
       COALESCE(SUM(l.debit - l.credit) FILTER (WHERE h.posting_status = 'POSTED'), 0) AS saldo,
       CASE WHEN COALESCE(SUM(l.debit - l.credit) FILTER (WHERE h.posting_status = 'POSTED'), 0) >= 0
                 THEN 'KAS_DAN_SETARA_KAS'
            WHEN a.account_code = '1102'   -- hanya rekening bank yang dapat mengalami cerukan
                 THEN 'CERUKAN_BANK (liabilitas jangka pendek di neraca)'
            ELSE 'TIDAK_WAJAR: kas fisik tidak mungkin negatif, periksa pencatatan' END AS penyajian
  FROM cash_equivalent_accounts c
  JOIN chart_of_accounts a ON a.account_code = c.account_code
  LEFT JOIN journal_lines l   ON l.account_id = a.account_id
  LEFT JOIN journal_headers h ON h.id = l.header_id
 GROUP BY a.account_code, a.account_name, c.category
 ORDER BY a.account_code;

-- Ringkasan arus kas metode langsung per aktivitas (mutasi kas dikecualikan)
CREATE OR REPLACE VIEW v_arus_kas_per_aktivitas AS
SELECT COALESCE(h.cash_flow_activity, o.cash_flow_activity, 'BELUM_DIKLASIFIKASI') AS aktivitas,
       SUM(l.debit - l.credit) AS arus_kas_bersih
  FROM journal_headers h
  LEFT JOIN journal_headers o ON o.id = h.reversal_of      -- storno ikut aktivitas jurnal aslinya
  JOIN journal_lines l ON l.header_id = h.id
  JOIN chart_of_accounts a ON a.account_id = l.account_id
  JOIN cash_equivalent_accounts c ON c.account_code = a.account_code
 WHERE h.posting_status = 'POSTED'
   AND h.journal_type <> 'MUTASI_KAS'
 GROUP BY 1;

REVOKE ALL ON v_kas_dan_setara_kas, v_arus_kas_per_aktivitas FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION rpc_create_cash_transfer(DATE, TEXT, TEXT, TEXT, TEXT, NUMERIC),
                           rpc_create_cash_voucher(DATE, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION rpc_create_cash_transfer(DATE, TEXT, TEXT, TEXT, TEXT, NUMERIC),
                           rpc_create_cash_voucher(DATE, TEXT, TEXT, JSONB, TEXT) TO authenticated;
-- Saldo awal: setoran modal pemilik ke Kas & Bank (aktivitas PENDANAAN)
DO $$ DECLARE v BIGINT; BEGIN
  INSERT INTO journal_headers (transaction_date, reference_no, description, cash_flow_activity)
  VALUES (CURRENT_DATE, 'JU-MODAL-01', 'Setoran modal awal pemilik', 'PENDANAAN') RETURNING id INTO v;
  INSERT INTO journal_lines (header_id, account_id, debit, credit)
  SELECT v, account_id, d, c FROM (VALUES ('1101', 10000000, 0), ('1102', 20000000, 0), ('3101', 0, 30000000)) x(code, d, c)
    JOIN chart_of_accounts ON account_code = x.code;
  UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
