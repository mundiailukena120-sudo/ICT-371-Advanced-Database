-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1234', 10000,  9000),    -- 1,000 km since service
 ('BAZ 5678', 20000, 14000),    -- 6,000 km: already due
 ('CAK 9012', 30000, 25200);    -- 4,800 km: close to threshold

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_cur INT; v_last INT;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_cur, v_last
      FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN (v_cur - v_last) >= 5000;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cur INT;
BEGIN
    SELECT current_odometer INTO v_cur FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.end_odometer IS NULL OR NEW.start_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must exceed start)',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;
    IF NEW.start_odometer <> v_cur THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                        NEW.start_odometer, v_cur;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;  -- once
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- (c) Procedure (does NOT touch vehicles; the trigger does) -----------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date is required';
    END IF;
    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (a) continued: six trips through the procedure (trigger already installed)
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10200);
CALL pr_record_trip(1, CURRENT_DATE - 4, 10200, 10500);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 3, 20300, 20500);
CALL pr_record_trip(3, CURRENT_DATE - 2, 30000, 30050);
CALL pr_record_trip(3, CURRENT_DATE - 1, 30050, 30150);

-- Tests
SELECT vehicle_id, current_odometer, current_odometer - last_service_odometer AS km_since_service,
       fn_service_due(vehicle_id) AS due
FROM vehicles ORDER BY vehicle_id;       -- 1: f (1500) | 2: t (6500) | 3: f (4950)
DO $$ BEGIN PERFORM fn_service_due(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 10000, 10100);   -- wrong start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 10500, 10400);   -- end <= start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT * FROM trips ORDER BY trip_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;

-- (f) Index ----------------------------------------------------------------
-- Equality on vehicle_id then range on trip_on: one contiguous index range.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- insert or update one alert per due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service, flagged_on = EXCLUDED.flagged_on;
    -- remove alerts for vehicles no longer due (serviced)
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                        WHERE v.vehicle_id = sa.vehicle_id
                          AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- vehicle 2 only
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;   -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- alert removed

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
            $cron$CALL pr_refresh_service_alerts()$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_service_alerts_weekly'', ''0 6 * * 1'', $$CALL pr_refresh_service_alerts()$$);';
    END IF;
END $do$;
