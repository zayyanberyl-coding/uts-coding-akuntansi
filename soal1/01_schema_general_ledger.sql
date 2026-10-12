-- =====================================================================
-- SOAL 1 - Desain Arsitektur Data, Normalisasi & Asas Berpasangan
-- Modul General Ledger (PostgreSQL / Supabase)
-- Zayyan Beryl - 12030124140283 - Pengkodean dan Pemrograman Kelas E
-- =====================================================================
-- Urutan eksekusi repo: soal1 -> soal2 -> soal3

-- ---------------------------------------------------------------------
-- 1. CHART OF ACCOUNTS (Bagan Akun)
-- ---------------------------------------------------------------------
-- normal_balance disimpan per akun (bukan diturunkan dari kelompok akun)
-- karena ada akun kontra, mis. Akumulasi Penyusutan (kelompok ASET tetapi
-- saldo normal KREDIT). Jenis laporan (Neraca / Laba Rugi) TIDAK disimpan
-- karena dapat diturunkan dari report_classification -> menghindari
-- ketergantungan transitif (syarat 3NF).
CREATE TABLE chart_of_accounts (
    account_id            INTEGER GENERATED ALWAYS AS IDENTITY,
    account_code          VARCHAR(10)  NOT NULL,
    account_name          VARCHAR(100) NOT NULL,
    normal_balance        VARCHAR(6)   NOT NULL,
    report_classification VARCHAR(12)  NOT NULL,
    is_active             BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT pk_coa                 PRIMARY KEY (account_id),
    CONSTRAINT uq_coa_code            UNIQUE (account_code),
    CONSTRAINT ck_coa_normal_balance  CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    CONSTRAINT ck_coa_classification  CHECK (report_classification IN
                                       ('ASET', 'LIABILITAS', 'EKUITAS', 'PENDAPATAN', 'BEBAN'))
);

-- ---------------------------------------------------------------------
-- 2. JOURNAL HEADERS (Kepala Jurnal / Bukti Transaksi)
-- ---------------------------------------------------------------------
CREATE TABLE journal_headers (
    id               BIGINT GENERATED ALWAYS AS IDENTITY,
    transaction_date DATE         NOT NULL,
    reference_no     VARCHAR(30)  NOT NULL,          -- nomor bukti
    description      TEXT         NOT NULL,
    posting_status   VARCHAR(10)  NOT NULL DEFAULT 'DRAFT',

    CONSTRAINT pk_journal_headers   PRIMARY KEY (id),
    CONSTRAINT uq_journal_reference UNIQUE (reference_no),   -- cegah bukti ganda
    CONSTRAINT ck_journal_status    CHECK (posting_status IN ('DRAFT', 'POSTED'))
);

-- ---------------------------------------------------------------------
-- 3. JOURNAL LINES (Baris Jurnal / Detail Debit-Kredit)
-- ---------------------------------------------------------------------
CREATE TABLE journal_lines (
    id         BIGINT GENERATED ALWAYS AS IDENTITY,
    header_id  BIGINT        NOT NULL,
    account_id INTEGER       NOT NULL,
    debit      NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit     NUMERIC(18,2) NOT NULL DEFAULT 0,

    CONSTRAINT pk_journal_lines PRIMARY KEY (id),

    -- Foreign key dengan ON DELETE RESTRICT: header / akun yang sudah
    -- dipakai tidak bisa dihapus selama masih ada baris jurnal.
    CONSTRAINT fk_lines_header  FOREIGN KEY (header_id)
        REFERENCES journal_headers (id)       ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_lines_account FOREIGN KEY (account_id)
        REFERENCES chart_of_accounts (account_id) ON DELETE RESTRICT ON UPDATE RESTRICT,

    -- Diminta soal: nominal tidak boleh negatif ...
    CONSTRAINT ck_lines_debit_nonneg  CHECK (debit  >= 0),
    CONSTRAINT ck_lines_credit_nonneg CHECK (credit >= 0),
    -- ... dan debit & kredit tidak boleh nol secara bersamaan
    CONSTRAINT ck_lines_not_both_zero CHECK (NOT (debit = 0 AND credit = 0)),
    -- Tambahan: satu baris hanya boleh berisi satu sisi (debit ATAU kredit)
    CONSTRAINT ck_lines_one_side      CHECK (NOT (debit > 0 AND credit > 0))
);

CREATE INDEX ix_journal_lines_header  ON journal_lines (header_id);
CREATE INDEX ix_journal_lines_account ON journal_lines (account_id);

-- =====================================================================
-- 4. PENEGAKAN ASAS BERPASANGAN DI LEVEL DATABASE (nilai tambah)
-- =====================================================================
-- CHECK constraint hanya bisa melihat SATU baris. Keseimbangan
-- Total Debit = Total Kredit melibatkan BANYAK baris, sehingga dipakai
-- CONSTRAINT TRIGGER yang DEFERRABLE INITIALLY DEFERRED: pemeriksaan
-- dilakukan saat COMMIT, setelah semua baris jurnal dimasukkan.
-- Akibatnya transaksi yang dikirim langsung lewat API (melewati validasi
-- frontend) tetap DITOLAK bila tidak seimbang.

CREATE OR REPLACE FUNCTION fn_assert_journal_balanced(p_header_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_lines  INTEGER;
    v_debit  NUMERIC(18,2);
    v_credit NUMERIC(18,2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
      INTO v_lines, v_debit, v_credit
      FROM journal_lines
     WHERE header_id = p_header_id;

    IF v_lines > 0 AND (v_lines < 2 OR v_debit <> v_credit) THEN
        RAISE EXCEPTION
            'Jurnal % tidak seimbang: % baris, Total Debit = %, Total Kredit = %',
            p_header_id, v_lines, v_debit, v_credit
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_trg_journal_lines_balance()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM fn_assert_journal_balanced(OLD.header_id);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM fn_assert_journal_balanced(NEW.header_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_journal_lines_balance
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_trg_journal_lines_balance();

-- Aturan posting: jurnal wajib dibuat sebagai DRAFT, diisi barisnya,
-- lalu di-POSTED. Saat posting, jurnal harus punya >= 2 baris & seimbang.
CREATE OR REPLACE FUNCTION fn_trg_journal_posting_rules()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.posting_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal baru harus berstatus DRAFT; posting dilakukan setelah baris jurnal lengkap.';
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.posting_status = 'POSTED'
       AND OLD.posting_status IS DISTINCT FROM 'POSTED' THEN
        IF (SELECT COUNT(*) FROM journal_lines WHERE header_id = NEW.id) < 2 THEN
            RAISE EXCEPTION 'Jurnal % tidak dapat di-POSTED: minimal 2 baris (debit & kredit).', NEW.id;
        END IF;
        PERFORM fn_assert_journal_balanced(NEW.id);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_journal_posting_rules
    BEFORE INSERT OR UPDATE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_trg_journal_posting_rules();

-- =====================================================================
-- 5. DATA AWAL BAGAN AKUN (dipakai juga oleh Soal 2 dan Soal 3)
-- =====================================================================
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_classification) VALUES
    ('1101', 'Kas',                                 'DEBIT',  'ASET'),
    ('1102', 'Bank',                                'DEBIT',  'ASET'),
    ('1103', 'Kas Kecil',                           'DEBIT',  'ASET'),
    ('1201', 'Piutang Usaha',                       'DEBIT',  'ASET'),
    ('1301', 'Persediaan Barang Dagang',            'DEBIT',  'ASET'),
    ('1401', 'Sewa Dibayar di Muka',                'DEBIT',  'ASET'),
    ('1501', 'Peralatan',                           'DEBIT',  'ASET'),
    ('1509', 'Akumulasi Penyusutan Peralatan',      'CREDIT', 'ASET'),   -- akun kontra
    ('2101', 'Utang Usaha',                         'CREDIT', 'LIABILITAS'),
    ('2102', 'Utang Gaji',                          'CREDIT', 'LIABILITAS'),
    ('3101', 'Modal Pemilik',                       'CREDIT', 'EKUITAS'),
    ('4101', 'Pendapatan Penjualan',                'CREDIT', 'PENDAPATAN'),
    ('4901', 'Pendapatan Selisih Persediaan',       'CREDIT', 'PENDAPATAN'),
    ('5101', 'Beban Pokok Pendapatan (HPP)',        'DEBIT',  'BEBAN'),
    ('5901', 'Beban Selisih/Kerugian Persediaan',   'DEBIT',  'BEBAN'),
    ('6101', 'Beban Gaji',                          'DEBIT',  'BEBAN'),
    ('6102', 'Beban Listrik, Air & Telepon',        'DEBIT',  'BEBAN'),
    ('6103', 'Beban Sewa',                          'DEBIT',  'BEBAN'),
    ('6104', 'Beban Perlengkapan Kantor',           'DEBIT',  'BEBAN'),
    ('6105', 'Beban Transportasi',                  'DEBIT',  'BEBAN');

-- Tampilan pembantu: jenis laporan diturunkan, bukan disimpan (3NF)
CREATE OR REPLACE VIEW v_chart_of_accounts AS
SELECT account_id, account_code, account_name, normal_balance, report_classification,
       CASE WHEN report_classification IN ('ASET', 'LIABILITAS', 'EKUITAS')
            THEN 'NERACA' ELSE 'LABA RUGI' END AS financial_statement
  FROM chart_of_accounts;
