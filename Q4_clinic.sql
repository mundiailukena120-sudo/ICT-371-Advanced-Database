-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

CREATE TABLE patients (patient_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE doctors  (doctor_id  SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL
        CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Esther Mwale'), ('Kelvin Nkhoma'), ('Bwalya Chisenga');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Phiri'), ('Dr. Mulenga');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    RETURN (SELECT COUNT(*)::INT FROM appointments
             WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED');
END $$;

-- (d) Trigger (created before the procedure is used) -----------------------
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
         WHERE a.doctor_id = NEW.doctor_id
           AND a.appointment_day = NEW.appointment_day
           AND a.slot_time = NEW.slot_time
           AND a.status <> 'CANCELLED'
           AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)  -- exclude self on UPDATE
    ) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_appointment_clash();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- clash caught by trigger
END $$;

-- (a) continued: six appointments
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '11:00');
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
VALUES (3, 3, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
       (1, 1, CURRENT_DATE,     '09:00', 'CANCELLED');   -- same slot as #1, allowed because cancelled

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE) AS dr1_today,        -- 2 (cancelled excluded)
       fn_daily_load(2, CURRENT_DATE + 5) AS no_bookings;  -- 0
DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');   -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE - 1, '09:00');  -- past
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE + 2, '13:00');  -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
-- UPDATE that moves onto an occupied slot is rejected; updating a row in place is fine
DO $$ BEGIN UPDATE appointments SET slot_time = '09:00' WHERE patient_id = 2 AND doctor_id = 1 AND status = 'BOOKED';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;   -- self excluded: OK
SELECT * FROM appointments ORDER BY appointment_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id, p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';
SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index ----------------------------------------------------------------
-- Non-unique (a doctor has several slots a day). appointment_day first because
-- day lookups are used for reports/summaries; doctor_id narrows within the day.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count = EXCLUDED.booked_count,
           attended_count = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END $$;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);     -- rerun replaces
SELECT * FROM clinic_summary;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
            $cron$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_clinic_summary_daily'', ''0 1 * * *'', $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);';
    END IF;
END $do$;
