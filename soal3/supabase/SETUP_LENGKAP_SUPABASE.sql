-- SETUP LENGKAP SUPABASE (gabungan): soal1 -> soal2 -> data demo -> soal3.2 -> keamanan
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
-- =====================================================================
-- SOAL 3.2 - Mekanisme Jejak Audit (Audit Trail & Immutability)
-- Backend: Supabase RPC (fungsi PostgreSQL yang dipanggil lewat
--          supabase.rpc(...) dari frontend / REST API PostgREST)
-- Zayyan Beryl - 12030124140283 - Pengkodean dan Pemrograman Kelas E
-- Prasyarat: soal1 (GL) dan soal2 (persediaan) sudah dijalankan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Identitas pelaku (created_by)
-- ---------------------------------------------------------------------
-- Di Supabase, setiap request REST/RPC membawa JWT pengguna yang login.
-- PostgREST menaruh isinya di setting 'request.jwt.claims'. Nilai ini
-- diambil di SISI SERVER, sehingga created_by tidak bisa dipalsukan
-- oleh klien. Di luar Supabase (psql) fallback ke nama user database.
CREATE OR REPLACE FUNCTION fn_current_actor()
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
        current_user::text
    );
$$;

-- ---------------------------------------------------------------------
-- B. Kolom audit pada journal_headers
-- ---------------------------------------------------------------------
ALTER TABLE journal_headers
    ADD COLUMN journal_type  VARCHAR(20) NOT NULL DEFAULT 'UMUM',
    ADD COLUMN created_by    TEXT        NOT NULL DEFAULT fn_current_actor(),
    ADD COLUMN created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN posted_by     TEXT,
    ADD COLUMN posted_at     TIMESTAMPTZ,
    ADD COLUMN prev_hash     CHAR(64),
    ADD COLUMN hash_checksum CHAR(64),
    ADD COLUMN reversal_of   BIGINT REFERENCES journal_headers(id) ON DELETE RESTRICT,
    ADD COLUMN reversal_reason TEXT,
    ADD CONSTRAINT ck_journal_type CHECK (journal_type IN ('UMUM', 'KAS_KELUAR', 'PERSEDIAAN', 'STORNO')),
    ADD CONSTRAINT uq_journal_reversal_of UNIQUE (reversal_of),      -- 1 jurnal hanya bisa di-storno 1x
    ADD COLUMN post_seq      BIGINT,                              -- urutan posting (urutan rantai hash)
    ADD CONSTRAINT uq_journal_post_seq UNIQUE (post_seq),
    ADD CONSTRAINT ck_storno_has_reason CHECK (reversal_of IS NULL OR reversal_reason IS NOT NULL);

CREATE SEQUENCE journal_post_seq;

-- Jurnal persediaan dari Soal 2 ditandai jenisnya
UPDATE journal_headers SET journal_type = 'PERSEDIAAN' WHERE reference_no LIKE 'INV-%';

-- ---------------------------------------------------------------------
-- C. hash_checksum (SHA-256) berantai
-- ---------------------------------------------------------------------
-- Payload kanonik = data header + seluruh baris (urut id) + hash jurnal
-- POSTED sebelumnya. Mengubah 1 angka saja (mis. via akses langsung ke
-- disk/backup) membuat hash tidak cocok, dan karena berantai, seluruh
-- jurnal sesudahnya ikut terdeteksi (tamper-evident, seperti blockchain).
CREATE OR REPLACE FUNCTION fn_journal_payload(
    p_id BIGINT, p_date DATE, p_reference TEXT, p_description TEXT, p_type TEXT,
    p_created_by TEXT, p_created_at TIMESTAMPTZ, p_reversal_of BIGINT, p_prev_hash TEXT
) RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT concat_ws('|',
        p_id, to_char(p_date, 'YYYY-MM-DD'), p_reference, p_description, p_type,
        p_created_by, to_char(p_created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
        COALESCE(p_reversal_of::text, '-'),
        (SELECT string_agg(a.account_code || ':' || l.debit::text || ':' || l.credit::text, ';' ORDER BY l.id)
           FROM journal_lines l JOIN chart_of_accounts a ON a.account_id = l.account_id
          WHERE l.header_id = p_id),
        COALESCE(p_prev_hash, 'GENESIS'));
$$;

-- Versi ringkas: hitung payload dari baris yang sudah tersimpan
CREATE OR REPLACE FUNCTION fn_journal_payload_of(p_header_id BIGINT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT fn_journal_payload(h.id, h.transaction_date, h.reference_no, h.description, h.journal_type,
                              h.created_by, h.created_at, h.reversal_of, h.prev_hash)
      FROM journal_headers h WHERE h.id = p_header_id;
$$;

CREATE OR REPLACE FUNCTION fn_sha256_hex(p_text TEXT)
RETURNS CHAR(64) LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(sha256(convert_to(p_text, 'UTF8')), 'hex');
$$;

-- Segel (seal) hash pada saat status berubah menjadi POSTED
CREATE OR REPLACE FUNCTION fn_trg_journal_seal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- created_by/created_at selalu diisi server, abaikan kiriman klien
        NEW.created_by    := fn_current_actor();
        NEW.created_at    := now();
        NEW.posted_by     := NULL;
        NEW.posted_at     := NULL;
        NEW.hash_checksum := NULL;
        NEW.prev_hash     := NULL;
        RETURN NEW;
    END IF;

    -- UPDATE pada DRAFT: kolom audit tidak boleh diubah klien
    NEW.created_by := OLD.created_by;
    NEW.created_at := OLD.created_at;

    IF NEW.posting_status = 'POSTED' AND OLD.posting_status = 'DRAFT' THEN
        -- serialisasi proses posting agar rantai hash tidak bercabang
        PERFORM pg_advisory_xact_lock(hashtext('journal_hash_chain'));
        NEW.posted_by := fn_current_actor();
        NEW.posted_at := clock_timestamp();
        NEW.post_seq  := nextval('journal_post_seq');
        SELECT hash_checksum INTO NEW.prev_hash
          FROM journal_headers
         WHERE post_seq IS NOT NULL
         ORDER BY post_seq DESC
         LIMIT 1;
        NEW.hash_checksum := fn_sha256_hex(fn_journal_payload(
            NEW.id, NEW.transaction_date, NEW.reference_no, NEW.description, NEW.journal_type,
            NEW.created_by, NEW.created_at, NEW.reversal_of, NEW.prev_hash));
    END IF;
    RETURN NEW;
END;
$$;

-- Backfill: segel jurnal POSTED yang sudah ada (dari Soal 1 & 2), urut id
DO $$
DECLARE r RECORD; v_prev TEXT := NULL;
BEGIN
    FOR r IN SELECT id FROM journal_headers WHERE posting_status = 'POSTED' ORDER BY id LOOP
        UPDATE journal_headers
           SET posted_by = created_by, posted_at = created_at,
               post_seq  = nextval('journal_post_seq'), prev_hash = v_prev
         WHERE id = r.id;
        UPDATE journal_headers SET hash_checksum = fn_sha256_hex(fn_journal_payload_of(r.id))
         WHERE id = r.id RETURNING hash_checksum INTO v_prev;
    END LOOP;
END $$;

-- Setiap jurnal POSTED wajib sudah tersegel
ALTER TABLE journal_headers ADD CONSTRAINT ck_posted_is_sealed CHECK (
    posting_status <> 'POSTED'
    OR (hash_checksum IS NOT NULL AND posted_at IS NOT NULL AND posted_by IS NOT NULL AND post_seq IS NOT NULL));

-- Nama trigger menentukan urutan eksekusi (alfabetis):
--   trg_journal_headers_immutable -> trg_journal_posting_rules (Soal 1) -> trg_journal_seal
CREATE TRIGGER trg_journal_seal
    BEFORE INSERT OR UPDATE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_trg_journal_seal();

-- ---------------------------------------------------------------------
-- D. IMMUTABILITY: jurnal POSTED tidak bisa di-UPDATE / DELETE
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_trg_journal_headers_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.posting_status = 'POSTED' THEN
        RAISE EXCEPTION
            'Jurnal % (%) sudah POSTED dan bersifat final: % ditolak. Gunakan jurnal pembalik: SELECT rpc_reverse_journal(%, ''alasan'');',
            OLD.id, OLD.reference_no, TG_OP, OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_journal_headers_immutable
    BEFORE UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_trg_journal_headers_immutable();

CREATE OR REPLACE FUNCTION fn_trg_journal_lines_immutable()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_status TEXT;
BEGIN
    SELECT posting_status INTO v_status FROM journal_headers
     WHERE id = CASE WHEN TG_OP = 'INSERT' THEN NEW.header_id ELSE OLD.header_id END;
    IF v_status = 'POSTED' THEN
        RAISE EXCEPTION 'Baris jurnal milik jurnal POSTED tidak dapat di-% . Gunakan jurnal pembalik (storno).', TG_OP
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.header_id <> OLD.header_id THEN
        SELECT posting_status INTO v_status FROM journal_headers WHERE id = NEW.header_id;
        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Tidak boleh memindahkan baris ke jurnal POSTED.';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_journal_lines_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_trg_journal_lines_immutable();

-- TRUNCATE melewati trigger baris, jadi diblokir terpisah
CREATE OR REPLACE FUNCTION fn_trg_block_truncate()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE pada tabel % dilarang (jejak audit).', TG_TABLE_NAME;
END;
$$;
CREATE TRIGGER trg_journal_headers_no_truncate BEFORE TRUNCATE ON journal_headers
    FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_block_truncate();
CREATE TRIGGER trg_journal_lines_no_truncate BEFORE TRUNCATE ON journal_lines
    FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_block_truncate();

-- ---------------------------------------------------------------------
-- E. AUDIT LOG (riwayat setiap perubahan, append-only)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name TEXT        NOT NULL,
    record_id  BIGINT      NOT NULL,
    action     TEXT        NOT NULL,     -- INSERT / UPDATE / DELETE
    actor      TEXT        NOT NULL DEFAULT fn_current_actor(),
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    old_data   JSONB,
    new_data   JSONB
);

CREATE OR REPLACE FUNCTION fn_trg_audit_log()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, old_data, new_data)
    VALUES (TG_TABLE_NAME,
            CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
            TG_OP,
            CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_journal_headers AFTER INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION fn_trg_audit_log();
CREATE TRIGGER trg_audit_journal_lines AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION fn_trg_audit_log();

-- audit_log sendiri juga tidak boleh diubah / dihapus
CREATE OR REPLACE FUNCTION fn_trg_audit_log_readonly()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log bersifat append-only: % ditolak.', TG_OP;
END;
$$;
CREATE TRIGGER trg_audit_log_readonly BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION fn_trg_audit_log_readonly();
CREATE TRIGGER trg_audit_log_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION fn_trg_block_truncate();

-- =====================================================================
-- F. FUNGSI BACKEND (Supabase RPC)
-- =====================================================================

-- F.1  Simpan & posting Voucher Kas Keluar (dipanggil form web)
--      p_lines: [{"account_code":"6102","debit":750000,"credit":0}, ...]
CREATE OR REPLACE FUNCTION rpc_create_cash_voucher(
    p_transaction_date DATE,
    p_reference_no     TEXT,
    p_description      TEXT,
    p_lines            JSONB
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_id       BIGINT;
    v_line     JSONB;
    v_acc      chart_of_accounts%ROWTYPE;
    v_debit    NUMERIC(18,2) := 0;
    v_credit   NUMERIC(18,2) := 0;
    v_cash_cr  NUMERIC(18,2) := 0;
    v_row      journal_headers%ROWTYPE;
BEGIN
    -- Validasi aturan bisnis (sama dengan frontend, tetapi TIDAK bergantung padanya)
    IF p_transaction_date IS NULL OR p_transaction_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Tanggal transaksi wajib diisi dan tidak boleh di masa depan.';
    END IF;
    IF COALESCE(trim(p_reference_no), '') = '' OR COALESCE(trim(p_description), '') = '' THEN
        RAISE EXCEPTION 'Nomor bukti dan deskripsi wajib diisi.';
    END IF;
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'Voucher minimal terdiri dari 2 baris (debit & kredit).';
    END IF;

    INSERT INTO journal_headers (transaction_date, reference_no, description, journal_type)
    VALUES (p_transaction_date, trim(p_reference_no), trim(p_description), 'KAS_KELUAR')
    RETURNING id INTO v_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        SELECT * INTO v_acc FROM chart_of_accounts
         WHERE account_code = v_line ->> 'account_code' AND is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Akun % tidak terdaftar / tidak aktif.', v_line ->> 'account_code';
        END IF;

        INSERT INTO journal_lines (header_id, account_id, debit, credit)
        VALUES (v_id, v_acc.account_id,
                COALESCE((v_line ->> 'debit')::NUMERIC, 0),
                COALESCE((v_line ->> 'credit')::NUMERIC, 0));

        v_debit  := v_debit  + COALESCE((v_line ->> 'debit')::NUMERIC, 0);
        v_credit := v_credit + COALESCE((v_line ->> 'credit')::NUMERIC, 0);
        IF v_acc.account_code IN ('1101', '1102', '1103') THEN
            IF COALESCE((v_line ->> 'debit')::NUMERIC, 0) > 0 THEN
                RAISE EXCEPTION 'Voucher kas KELUAR tidak boleh mendebit akun kas/bank (%).', v_acc.account_name;
            END IF;
            v_cash_cr := v_cash_cr + COALESCE((v_line ->> 'credit')::NUMERIC, 0);
        END IF;
    END LOOP;

    IF v_debit <> v_credit THEN
        RAISE EXCEPTION 'Zero-discrepancy dilanggar: Total Debit % <> Total Kredit %', v_debit, v_credit;
    END IF;
    IF v_cash_cr = 0 THEN
        RAISE EXCEPTION 'Voucher kas keluar wajib mengkredit akun Kas/Bank/Kas Kecil.';
    END IF;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v_id
    RETURNING * INTO v_row;

    RETURN jsonb_build_object(
        'id', v_row.id, 'reference_no', v_row.reference_no, 'total', v_debit,
        'created_by', v_row.created_by, 'created_at', v_row.created_at,
        'hash_checksum', v_row.hash_checksum);
END;
$$;

-- F.2  Jurnal pembalik (storno) - satu-satunya cara "mengoreksi" jurnal POSTED
CREATE OR REPLACE FUNCTION rpc_reverse_journal(
    p_header_id BIGINT,
    p_reason    TEXT,
    p_date      DATE DEFAULT CURRENT_DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_orig journal_headers%ROWTYPE;
    v_id   BIGINT;
    v_row  journal_headers%ROWTYPE;
BEGIN
    SELECT * INTO v_orig FROM journal_headers WHERE id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Jurnal % tidak ditemukan.', p_header_id;
    ELSIF v_orig.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang perlu dibalik; jurnal DRAFT cukup diedit.';
    ELSIF v_orig.journal_type = 'STORNO' THEN
        RAISE EXCEPTION 'Jurnal storno tidak dapat dibalik lagi.';
    ELSIF EXISTS (SELECT 1 FROM journal_headers WHERE reversal_of = p_header_id) THEN
        RAISE EXCEPTION 'Jurnal % sudah pernah dibalik.', v_orig.reference_no;
    ELSIF COALESCE(trim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'Alasan pembalikan wajib diisi.';
    END IF;

    INSERT INTO journal_headers (transaction_date, reference_no, description, journal_type,
                                 reversal_of, reversal_reason)
    VALUES (p_date, 'STORNO-' || v_orig.reference_no,
            'Pembalik atas ' || v_orig.reference_no || ': ' || trim(p_reason),
            'STORNO', v_orig.id, trim(p_reason))
    RETURNING id INTO v_id;

    -- Debit <-> Kredit ditukar
    INSERT INTO journal_lines (header_id, account_id, debit, credit)
    SELECT v_id, account_id, credit, debit
      FROM journal_lines WHERE header_id = v_orig.id ORDER BY id;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE id = v_id
    RETURNING * INTO v_row;

    RETURN jsonb_build_object('id', v_row.id, 'reference_no', v_row.reference_no,
                              'reversal_of', v_orig.reference_no,
                              'hash_checksum', v_row.hash_checksum);
END;
$$;

-- F.3  Verifikasi integritas: hitung ulang hash & cek rantai
CREATE OR REPLACE FUNCTION rpc_verify_journal_integrity()
RETURNS TABLE (id BIGINT, reference_no VARCHAR, stored_hash CHAR(64),
               computed_hash CHAR(64), hash_valid BOOLEAN, chain_valid BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH posted AS (
        SELECT h.*, LAG(h.hash_checksum) OVER (ORDER BY h.post_seq) AS expected_prev
          FROM journal_headers h
         WHERE h.posting_status = 'POSTED'
    )
    SELECT p.id, p.reference_no, p.hash_checksum,
           fn_sha256_hex(fn_journal_payload_of(p.id)),
           p.hash_checksum = fn_sha256_hex(fn_journal_payload_of(p.id)),
           p.prev_hash IS NOT DISTINCT FROM p.expected_prev
      FROM posted p
     ORDER BY p.post_seq;
$$;

-- F.4  Data untuk frontend
CREATE OR REPLACE FUNCTION rpc_list_accounts()
RETURNS TABLE (account_code VARCHAR, account_name VARCHAR, normal_balance VARCHAR,
               report_classification VARCHAR)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT account_code, account_name, normal_balance, report_classification
      FROM chart_of_accounts WHERE is_active ORDER BY account_code;
$$;

CREATE OR REPLACE FUNCTION rpc_list_journals(p_limit INT DEFAULT 50)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE(jsonb_agg(j ORDER BY j.id DESC), '[]'::jsonb) FROM (
        SELECT h.id, h.transaction_date, h.reference_no, h.description, h.journal_type,
               h.posting_status, h.created_by, h.created_at, h.posted_at,
               h.hash_checksum, h.prev_hash,
               (SELECT reference_no FROM journal_headers r WHERE r.id = h.reversal_of) AS reversal_of_ref,
               (SELECT reference_no FROM journal_headers r WHERE r.reversal_of = h.id) AS reversed_by_ref,
               (SELECT SUM(debit) FROM journal_lines l WHERE l.header_id = h.id) AS total,
               (SELECT jsonb_agg(jsonb_build_object('account_code', a.account_code,
                        'account_name', a.account_name, 'debit', l.debit, 'credit', l.credit) ORDER BY l.id)
                  FROM journal_lines l JOIN chart_of_accounts a ON a.account_id = l.account_id
                 WHERE l.header_id = h.id) AS lines
          FROM journal_headers h
         ORDER BY h.id DESC
         LIMIT p_limit) j;
$$;

CREATE OR REPLACE FUNCTION rpc_list_audit_log(p_limit INT DEFAULT 30)
RETURNS TABLE (id BIGINT, table_name TEXT, record_id BIGINT, action TEXT, actor TEXT,
               logged_at TIMESTAMPTZ, summary TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT a.id, a.table_name, a.record_id, a.action, a.actor, a.logged_at,
           CASE WHEN a.table_name = 'journal_headers'
                THEN COALESCE(a.new_data, a.old_data) ->> 'reference_no' || ' [' ||
                     COALESCE(a.new_data ->> 'posting_status', '-') || ']'
                ELSE 'akun#' || (COALESCE(a.new_data, a.old_data) ->> 'account_id') ||
                     ' D:' || (COALESCE(a.new_data, a.old_data) ->> 'debit') ||
                     ' K:' || (COALESCE(a.new_data, a.old_data) ->> 'credit') END
      FROM audit_log a ORDER BY a.id DESC LIMIT p_limit;
$$;
-- =====================================================================
-- SOAL 3.2 (lanjutan) - Hak akses di Supabase
-- Prinsip: klien (browser) TIDAK boleh menulis tabel secara langsung.
-- Semua penulisan lewat fungsi RPC yang memvalidasi aturan bisnis.
-- Role 'anon' & 'authenticated' adalah role bawaan Supabase.
-- =====================================================================

-- 1) Aktifkan Row Level Security tanpa policy tulis -> akses REST
--    langsung ke tabel ditolak untuk anon/authenticated.
ALTER TABLE chart_of_accounts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_headers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines          ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log              ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_transactions ENABLE ROW LEVEL SECURITY;

-- 2) Cabut hak tulis langsung (lapis kedua selain RLS)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON
    chart_of_accounts, journal_headers, journal_lines, audit_log,
    inventory_items, inventory_transactions
FROM anon, authenticated;

-- 3) Fungsi RPC hanya untuk pengguna yang sudah login (authenticated)
REVOKE EXECUTE ON FUNCTION
    rpc_create_cash_voucher(DATE, TEXT, TEXT, JSONB),
    rpc_reverse_journal(BIGINT, TEXT, DATE),
    rpc_verify_journal_integrity(),
    rpc_list_accounts(),
    rpc_list_journals(INT),
    rpc_list_audit_log(INT)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
    rpc_create_cash_voucher(DATE, TEXT, TEXT, JSONB),
    rpc_reverse_journal(BIGINT, TEXT, DATE),
    rpc_verify_journal_integrity(),
    rpc_list_accounts(),
    rpc_list_journals(INT),
    rpc_list_audit_log(INT)
TO authenticated;
