-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id      SERIAL PRIMARY KEY,
    student_id          INT NOT NULL REFERENCES students(student_id),
    age_at_application  INT NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE NOT NULL,
    status              VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
 ('202406001','Chisomo Banda'), ('202406002','Mercy Zimba'), ('202406003','Felix Mukuka');

-- Six PENDING applications: qualifying, boundary and non-qualifying cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
 (1, 22, 1500.00, 85.00, CURRENT_DATE - 12, 'PENDING'),   -- qualifies
 (1, 18, 3000.00, 70.00, CURRENT_DATE - 10, 'PENDING'),   -- boundary: all minimums (qualifies)
 (2, 25, 3000.00, 70.00, CURRENT_DATE - 9,  'PENDING'),   -- boundary: age 25 (qualifies)
 (2, 26, 1000.00, 90.00, CURRENT_DATE - 7,  'PENDING'),   -- too old
 (3, 20, 3000.01, 80.00, CURRENT_DATE - 5,  'PENDING'),   -- income just over
 (3, 21, 2000.00, 69.99, CURRENT_DATE - 3,  'PENDING');   -- mark just under

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_status VARCHAR(10); v_age INT; v_inc NUMERIC; v_mark NUMERIC;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
      INTO v_status, v_age, v_inc, v_mark
      FROM applications WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, v_status;
    END IF;
    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_inc, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- Tests (function)
SELECT fn_scholarship_eligible(18, 3000, 70) AS lower_boundary,   -- t
       fn_scholarship_eligible(25, 3000, 70) AS upper_boundary,   -- t
       fn_scholarship_eligible(26, 1000, 90) AS too_old,          -- f
       fn_scholarship_eligible(20, 3000.01, 80) AS income_over,   -- f
       fn_scholarship_eligible(21, 2000, 69.99) AS mark_under;    -- f
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 50);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 50);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- (g) Scheduled job procedure (defined here so it can be tested below)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
              WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END $$;

-- Procedure tests
DO $$ BEGIN CALL pr_assess_application(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
CALL pr_assess_application(1);
DO $$ BEGIN CALL pr_assess_application(1);       -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
CALL pr_assess_pending();                        -- assesses 2..6 only
CALL pr_assess_pending();                        -- rerun: nothing pending, no new audit rows
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;  -- exactly 6 rows
UPDATE applications SET status = status WHERE application_id = 1;   -- unchanged: no audit
SELECT COUNT(*) AS audit_rows FROM decision_audit;                  -- still 6

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';                     -- household income not exposed
SELECT * FROM v_approved_applicants;

-- (f) Index ----------------------------------------------------------------
-- Equality on status first, then range on submitted_on.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Schedule: every Monday at 08:00
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('assess_pending_weekly', '0 8 * * 1',
            $cron$CALL pr_assess_pending()$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''assess_pending_weekly'', ''0 8 * * 1'', $$CALL pr_assess_pending()$$);';
    END IF;
END $do$;
