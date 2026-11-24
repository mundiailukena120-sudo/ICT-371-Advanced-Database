-- ICT371 Advanced Database | Question 5: Hostel Room Allocation (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id),
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT ck_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
 ('202405001','Mwansa Chilufya'), ('202405002','Thandiwe Moyo'), ('202405003','Joseph Kalaba'),
 ('202405004','Ruth Siame'),      ('202405005','Patrick Daka'),  ('202405006','Lubasi Mubita');
INSERT INTO rooms (room_number, capacity) VALUES ('R101',2), ('R102',3), ('R103',2), ('R104',1);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    RETURN v_cap - (SELECT COUNT(*)::INT FROM allocations
                     WHERE room_id = p_room_id AND status = 'ACTIVE');
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_cnt INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;  -- serialise per room
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;
        IF EXISTS (SELECT 1 FROM allocations
                    WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                      AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN   -- exclude row being updated
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
        SELECT COUNT(*) INTO v_cnt FROM allocations
         WHERE room_id = NEW.room_id AND status = 'ACTIVE'
           AND allocation_id IS DISTINCT FROM NEW.allocation_id;
        IF v_cnt >= v_cap THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- Seed: R101 full (2/2), R102 partly (1/3), R103 empty (history only), R104 full (1/1)
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 29);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);
CALL pr_allocate_room(4, 4, CURRENT_DATE - 10);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (5, 3, CURRENT_DATE - 90, CURRENT_DATE - 60, 'ENDED');   -- history: no bed used

-- Tests
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;
DO $$ BEGIN PERFORM fn_free_beds(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);        -- full room
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 2, CURRENT_DATE);        -- already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)   -- direct SQL, full room
            VALUES (6, 4, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT * FROM allocations ORDER BY allocation_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)::INT              AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id))::INT AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;
SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index ----------------------------------------------------------------
-- Partial index on ACTIVE rows only: occupancy/capacity checks always filter
-- status = 'ACTIVE' and room_id, and history rows never need to be scanned.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
-- Extra safety net for "one ACTIVE allocation per student" under concurrency
CREATE UNIQUE INDEX uq_alloc_active_student ON allocations (student_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();     -- rerun: values replaced, no duplicate rows
SELECT * FROM occupancy_snapshot ORDER BY room_id;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_occupancy_daily', '55 23 * * *',
            $cron$CALL pr_refresh_occupancy()$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_occupancy_daily'', ''55 23 * * *'', $$CALL pr_refresh_occupancy()$$);';
    END IF;
END $do$;
