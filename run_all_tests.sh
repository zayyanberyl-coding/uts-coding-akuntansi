#!/usr/bin/env bash
# =====================================================================
# Membangun ulang database dari nol & menjalankan seluruh uji.
# Output tiap uji disimpan di folder bukti/.
# Pemakaian (PostgreSQL lokal):  DB=uts ./run_all_tests.sh
# =====================================================================
set -e
cd "$(dirname "$0")"
DB="${DB:-uts}"
export PGTZ="Asia/Jakarta" TZ="Asia/Jakarta"
mkdir -p bukti

psql -q -X -d postgres -c "DROP DATABASE IF EXISTS $DB;" -c "CREATE DATABASE $DB;"
# role bawaan Supabase (agar 02_supabase_security.sql bisa diuji lokal)
psql -q -X -d postgres -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END \$\$;"

run () { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$1"; }
show () { echo "\$ psql -f $1"; echo; psql -X -q -d "$DB" -f "$1" 2>&1; }

run soal1/01_schema_general_ledger.sql
show soal1/02_uji_soal1.sql            | tee bukti/uji_soal1.txt

run soal2/01_inventory_trigger.sql
show soal2/02_uji_trigger.sql          | tee bukti/uji_soal2_trigger.txt
DB="$DB" ./soal2/concurrency_demo.sh 2>&1 | grep -v "^NOTICE" | tee bukti/uji_soal2_concurrency.txt

run soal3/supabase/01_audit_trail_immutability.sql
run soal3/supabase/02_supabase_security.sql
show soal3/supabase/03_uji_soal3.sql   | tee bukti/uji_soal3_audit_trail.txt
echo "SELESAI - lihat folder bukti/"
