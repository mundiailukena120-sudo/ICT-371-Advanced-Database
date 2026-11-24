-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Mulenga Water Co-op'), ('Agnes Chola'), ('Brian Katongo');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;
    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);                    -- first 10 units: K5
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);        -- above 10: K8
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_reading_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;      -- row stored only if we reach here
END $$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_reading_check();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
      FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END $$;

-- (a) continued: six readings (0, exactly 10, and above 10 units)
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100, 100),   -- 0 units
 (1, '2026-10-01', 100, 110),   -- exactly 10
 (2, '2026-09-01',  50,  65),   -- 15
 (2, '2026-10-01',  65,  70),   -- 5
 (3, '2026-09-01', 200, 210),   -- exactly 10
 (3, '2026-10-01', 210, 230);   -- 20

CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 20);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(4, CURRENT_DATE - 10);
CALL pr_generate_bill(5, CURRENT_DATE + 5);
CALL pr_generate_bill(6, CURRENT_DATE + 10);
UPDATE bills SET amount_paid = charge WHERE reading_id = 2;   -- fully paid
UPDATE bills SET amount_paid = 10     WHERE reading_id = 4;   -- part paid

-- Tests
SELECT fn_water_charge(0) AS u0, fn_water_charge(10) AS u10, fn_water_charge(15.5) AS u15_5;  -- 0.00, 50.00, 94.00
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);     -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110, 100);          -- backwards reading, direct SQL
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_still_6 FROM readings;
SELECT * FROM bills ORDER BY bill_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills ORDER BY due_on;

-- (f) Index ----------------------------------------------------------------
-- Partial index: only unpaid bills are indexed, ordered by due_on, so
-- "overdue" range scans touch just the small unpaid subset.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();     -- rerun replaces the same date
SELECT * FROM receivable_snapshot;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_receivables_daily', '30 0 * * *',
            $cron$CALL pr_refresh_receivables()$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_receivables_daily'', ''30 0 * * *'', $$CALL pr_refresh_receivables()$$);';
    END IF;
END $do$;
