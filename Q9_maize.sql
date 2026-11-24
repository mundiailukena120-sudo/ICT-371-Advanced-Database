-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,      -- supplied by the trigger
    total_value  NUMERIC(12,2) NOT NULL,      -- supplied by the trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001', 'Mwamba Lungu'), ('F002', 'Ireen Sikazwe'), ('F003', 'Boniface Tonga');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;
    IF p_grade = 'A' THEN RETURN 5.00;
    ELSIF p_grade = 'B' THEN RETURN 4.00;
    ELSIF p_grade = 'C' THEN RETURN 3.00;
    END IF;
    RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade::TEXT);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_pricing();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    PERFORM fn_maize_rate(p_grade);                 -- rejects NULL / unsupported grade
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    -- unit_rate/total_value are supplied by the BEFORE trigger (placeholders only)
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 0, 0, p_date, FALSE);
END $$;

-- (a) continued: six deliveries, all grades, then some marked paid
CALL pr_receive_delivery(1, 'A', 100,   CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 50.5,  CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'C', 200,   CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 75.25, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 120,   CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C', 80,    CURRENT_DATE - 1);
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3);   -- trigger re-prices identically

-- Tests
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
-- Direct SQL follows the same pricing rule (supplied wrong rate is overwritten)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (1, 'C', 10, 99, 99, CURRENT_DATE - 5);          -- becomes 3.00 / 30.00
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
            VALUES (1, 'A', 0, 5, 0, CURRENT_DATE);     -- non-positive weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT * FROM deliveries ORDER BY delivery_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name, COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index ----------------------------------------------------------------
-- Equality on farmer_id then range on delivered_on => contiguous range scan.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
      FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;  -- replace
END $$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);     -- rerun: same totals
SELECT * FROM daily_purchases;

DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_purchases_daily', '30 1 * * *',
            $cron$CALL pr_refresh_purchases(CURRENT_DATE - 1)$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_purchases_daily'', ''30 1 * * *'', $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);';
    END IF;
END $do$;
