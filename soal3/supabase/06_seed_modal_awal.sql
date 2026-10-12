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
