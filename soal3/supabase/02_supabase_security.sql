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
