-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id          SERIAL PRIMARY KEY,
    loan_id           INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE NULL,
    new_returned_on   DATE NULL,
    changed_at        TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES ('Database System Concepts'), ('Clean Code'), ('Computer Networks');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));       -- earlier of the two
    RETURN 2.00 * GREATEST(v_end - v_due, 0);                -- K2 per day, min 0
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_due DATE; v_ret DATE;
BEGIN
    SELECT borrowed_on, due_on, returned_on INTO v_borrowed, v_due, v_ret
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
    END IF;
    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Invalid return date % (borrowed on %)', p_returned_on, v_borrowed;
    END IF;
    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = 2.00 * GREATEST(p_returned_on - v_due, 0)   -- same statement
     WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a) continued: six loans (dates relative to today so the data stays valid)
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Mary Zulu',    CURRENT_DATE - 30, CURRENT_DATE - 16),  -- open, overdue
 (2, 'John Tembo',   CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- open, on time
 (3, 'Grace Lungu',  CURRENT_DATE - 40, CURRENT_DATE - 26),  -- returned late
 (1, 'Peter Sakala', CURRENT_DATE - 20, CURRENT_DATE - 6),   -- returned on due date
 (2, 'Ann Mumba',    CURRENT_DATE - 14, CURRENT_DATE - 4),   -- open, overdue
 (3, 'Chola Kunda',  CURRENT_DATE - 2,  CURRENT_DATE + 12);  -- open, on time
CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late => K12
CALL pr_return_loan(4, CURRENT_DATE - 6);    -- on due date => K0

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);        -- already returned
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);  -- before borrowed_on
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;   -- unchanged: no audit
SELECT * FROM loan_audit ORDER BY audit_id;                    -- exactly 2 rows
SELECT loan_id, returned_on, fine_amount FROM loans ORDER BY loan_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- (f) Index ----------------------------------------------------------------
-- Partial index: only unreturned loans are indexed (small, always relevant),
-- keyed by book_id for "this book's unreturned loans".
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- Loans unreturned as of p_as_of (never returned, or returned after that date)
-- and already past due on that date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
      FROM loans
     WHERE borrowed_on <= p_as_of
       AND (returned_on IS NULL OR returned_on > p_as_of)
       AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);     -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_overdue_daily', '10 0 * * *',
            $cron$CALL pr_refresh_overdue(CURRENT_DATE)$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_overdue_daily'', ''10 0 * * *'', $$CALL pr_refresh_overdue(CURRENT_DATE)$$);';
    END IF;
END $do$;
