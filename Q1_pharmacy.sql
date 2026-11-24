-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales (PostgreSQL)
-- Student: ILUKENA MUNDIA (202402030)

-- (a) Tables ---------------------------------------------------------------
DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT NOT NULL,
    new_qty     INT NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 50),
 ('Amoxicillin 250mg', 8.00, 30),
 ('ORS Sachet',        1.50, 12);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;
    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END $$;

-- (c) Procedure ------------------------------------------------------------
-- Any RAISE aborts the call, so sales and medicines stay unchanged.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;
    SELECT unit_price, stock_qty INTO v_price, v_stock
      FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- lock row
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_quantity, v_stock;
    END IF;
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);          -- price stored
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;                               -- deducted once
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) continued: six valid sales loaded through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2, 15, CURRENT_DATE);
CALL pr_record_sale(3,  4, CURRENT_DATE);
CALL pr_record_sale(3,  1, CURRENT_DATE);

-- Tests
SELECT fn_sale_value(1, 4) AS sale_value;                  -- 10.00
DO $$ BEGIN PERFORM fn_sale_value(99, 1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_sale(1, 1000, CURRENT_DATE);   -- oversell
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT * FROM medicines ORDER BY medicine_id;              -- unchanged by failed call
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;
UPDATE medicines SET medicine_name = medicine_name WHERE medicine_id = 1;  -- no audit row
SELECT COUNT(*) AS audit_rows FROM stock_audit;            -- still 6

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines WHERE stock_qty < 10;

CALL pr_record_sale(3, 1, CURRENT_DATE);                   -- a further sale
SELECT * FROM v_low_stock ORDER BY medicine_id;

-- (f) Index ----------------------------------------------------------------
-- Equality on medicine_id first, then range on sold_on: one contiguous slice
-- of the B-tree answers "one medicine's sales in a date range".
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
      FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;  -- replace, never add
END $$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);                   -- rerun: same totals
SELECT * FROM daily_sales;

-- Requires the pg_cron extension (CREATE EXTENSION pg_cron; in the cron database)
DO $do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule('refresh_sales_daily', '15 0 * * *',
            $cron$CALL pr_refresh_sales(CURRENT_DATE - 1)$cron$);
    ELSE
        RAISE NOTICE 'pg_cron not installed. Run: SELECT cron.schedule(''refresh_sales_daily'', ''15 0 * * *'', $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);';
    END IF;
END $do$;
