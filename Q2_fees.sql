-- ICT371 Advanced Database | Question 2: University Fee Payments (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
 ('202401001', 'Chanda Mwila',   5000.00),
 ('202401002', 'Mutale Banda',   3000.00),
 ('202401003', 'Natasha Phiri',  2000.00);   -- will have no payments

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments WHERE student_id = p_student_id), 0);
END $$;

-- (c) Procedure (audit row is written by the trigger only) -----------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise per student
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
    END IF;
    INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

-- (a) continued: six payments through the procedure
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);   -- student 2 fully settled

-- Tests
SELECT fn_fee_balance(1) AS bal_1, fn_fee_balance(2) AS bal_2, fn_fee_balance(3) AS bal_3_full_fee;
DO $$ BEGIN PERFORM fn_fee_balance(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 99999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT * FROM students ORDER BY student_id;        -- fee_due unchanged
SELECT * FROM payment_audit ORDER BY audit_id;     -- 6 rows written by trigger

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name, fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;
SELECT * FROM v_fee_balances;

-- (f) Index ----------------------------------------------------------------
-- Equality on student_id then range on paid_on => one contiguous index range;
-- also serves the SUM() in fn_fee_balance.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0) FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
       SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);     -- rerun replaces row
SELECT * FROM daily_collections;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_collections_daily', '0 1 * * *',
            $cron$CALL pr_refresh_collections(CURRENT_DATE - 1)$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_collections_daily'', ''0 1 * * *'', $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);';
    END IF;
END $do$;
