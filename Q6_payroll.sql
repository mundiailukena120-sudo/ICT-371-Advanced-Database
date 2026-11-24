-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first of month
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Alice Mulenga', 5000, 500, 700, TRUE),
 ('Bob Chileshe',  4000, 300, 500, TRUE),
 ('Carol Ngoma',   6000, 800, 900, TRUE),    -- becomes inactive later
 ('Dan Mwape',     3000, 200, 400, TRUE);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_basic NUMERIC; v_allow NUMERIC; v_ded NUMERIC; v_net NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
      FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    v_net := v_basic + v_allow - v_ded;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (c) Procedure ------------------------------------------------------------
-- A raised exception rolls back the whole call (no partial payroll month).
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;
    FOR r IN SELECT employee_id, basic_salary + allowance AS gross
               FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);           -- raises on invalid employee calc
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows unchanged
    END LOOP;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) continued: two payroll months, then Carol becomes inactive
CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');
UPDATE employees SET active = FALSE WHERE full_name = 'Carol Ngoma';
CALL pr_process_payroll('2026-11-01');            -- Carol excluded (inactive)

-- Tests
SELECT employee_id, fn_net_pay(employee_id) AS net FROM employees ORDER BY 1;
DO $$ BEGIN PERFORM fn_net_pay(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_process_payroll('2026-11-15');       -- not month-start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
CALL pr_process_payroll('2026-10-01');                   -- reprocess: nothing changes
SELECT pay_month, COUNT(*) AS rows FROM payroll GROUP BY pay_month ORDER BY 1;
UPDATE employees SET basic_salary = 5200 WHERE full_name = 'Alice Mulenga';   -- audited
UPDATE employees SET basic_salary = basic_salary WHERE full_name = 'Bob Chileshe';  -- not audited
SELECT * FROM salary_audit;
-- Failure rolls back the whole call: make one active employee's net negative
UPDATE employees SET deduction = 99999 WHERE full_name = 'Dan Mwape';
DO $$ BEGIN CALL pr_process_payroll('2026-12-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT COUNT(*) AS dec_rows_should_be_0 FROM payroll WHERE pay_month = '2026-12-01';
UPDATE employees SET deduction = 400 WHERE full_name = 'Dan Mwape';   -- restore

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;   -- inactive staff keep history
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- (f) Index ----------------------------------------------------------------
-- UNIQUE (employee_id, pay_month) leads with employee_id, so it cannot serve a
-- search on pay_month alone. This index covers the all-employees monthly report
-- and is a different column order, so it does not duplicate the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st of each month, for the previous month ---
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('process_payroll_monthly', '0 2 1 * *',
            $cron$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''process_payroll_monthly'', ''0 2 1 * *'', $$CALL pr_process_payroll((date_trunc(''month'', CURRENT_DATE) - INTERVAL ''1 month'')::date)$$);';
    END IF;
END $do$;

-- Inspect the job and its run history (pg_cron)
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'process_payroll_monthly';
-- SELECT jobid, status, return_message, start_time, end_time
--   FROM cron.job_run_details
--  WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'process_payroll_monthly')
--  ORDER BY start_time DESC;
