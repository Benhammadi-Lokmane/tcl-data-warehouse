/*
===============================================================================
Quality Checks
===============================================================================
Script Purpose:
    This script performs quality checks to validate the integrity, consistency,
    and accuracy of the Gold Layer. These checks ensure:
    - Uniqueness of surrogate keys and business keys in dimension tables.
    - Referential integrity between fact and dimension tables.
    - Completeness of the facts compared with the Silver layer.
    - Validation of relationships in the data model for analytical purposes.

Usage Notes:
    - Run these checks after creating the Gold views (scripts/gold/ddl_gold.sql).
    - Investigate and resolve any discrepancies found during the checks.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ====================================================================
-- Checking 'gold.dim_dates'
-- ====================================================================
-- Check for Uniqueness of Date Key
-- Expectation: No results
SELECT
    date_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_dates
GROUP BY date_key
HAVING COUNT(*) > 1;

-- Check for a Continuous Calendar (one row per day between the first and the last date)
-- Expectation: No results
SELECT
    MIN(full_date) AS first_day,
    MAX(full_date) AS last_day,
    COUNT(*)       AS days
FROM gold.dim_dates
HAVING COUNT(*) <> DATEDIFF(day, MIN(full_date), MAX(full_date)) + 1;

-- Days of the Week
-- Expectation: 7 rows, Monday = 1 ... Sunday = 7, weekend = Saturday and Sunday
SELECT DISTINCT
    day_of_week,
    day_name,
    is_weekend
FROM gold.dim_dates
ORDER BY day_of_week;

-- ====================================================================
-- Checking 'gold.dim_lines'
-- ====================================================================
-- Check for Uniqueness of Line Key
-- Expectation: No results
SELECT
    line_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_lines
GROUP BY line_key
HAVING COUNT(*) > 1;

-- Check for Uniqueness of the Business Key (line code + direction)
-- Expectation: No results
SELECT
    line_code,
    direction,
    COUNT(*) AS duplicate_count
FROM gold.dim_lines
GROUP BY line_code, direction
HAVING COUNT(*) > 1;

-- Check for Lines without Mode or Category
-- Expectation: No results
SELECT
    *
FROM gold.dim_lines
WHERE mode = 'n/a' OR category = 'n/a';

-- Data Standardization & Consistency
SELECT
    mode,
    category,
    COUNT(*) AS lines
FROM gold.dim_lines
GROUP BY mode, category
ORDER BY mode, category;

-- ====================================================================
-- Checking 'gold.dim_stops'
-- ====================================================================
-- Check for Uniqueness of Stop Key
-- Expectation: No results
SELECT
    stop_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_stops
GROUP BY stop_key
HAVING COUNT(*) > 1;

-- Check for Uniqueness of the Business Key (stop id)
-- Expectation: No results
SELECT
    stop_id,
    COUNT(*) AS duplicate_count
FROM gold.dim_stops
WHERE stop_id IS NOT NULL
GROUP BY stop_id
HAVING COUNT(*) > 1;

-- Check for Exactly One 'n/a' Member (key 0)
-- Expectation: No results
SELECT
    COUNT(*) AS na_members
FROM gold.dim_stops
WHERE stop_key = 0
HAVING COUNT(*) <> 1;

-- ====================================================================
-- Checking 'gold.dim_vehicles'
-- ====================================================================
-- Check for Uniqueness of Vehicle Key
-- Expectation: No results
SELECT
    vehicle_key,
    COUNT(*) AS duplicate_count
FROM gold.dim_vehicles
GROUP BY vehicle_key
HAVING COUNT(*) > 1;

-- Check for Uniqueness of the Business Key (vehicle id)
-- Expectation: No results
SELECT
    vehicle_id,
    COUNT(*) AS duplicate_count
FROM gold.dim_vehicles
GROUP BY vehicle_id
HAVING COUNT(*) > 1;

-- Check for Exactly One 'n/a' Member (key 0)
-- Expectation: No results
SELECT
    COUNT(*) AS na_members
FROM gold.dim_vehicles
WHERE vehicle_key = 0
HAVING COUNT(*) <> 1;

-- Data Standardization & Consistency
SELECT
    vehicle_type,
    COUNT(*) AS vehicles
FROM gold.dim_vehicles
GROUP BY vehicle_type
ORDER BY vehicle_type;

-- ====================================================================
-- Checking 'gold.fact_trips'
-- ====================================================================
-- Check for Completeness: same number of rows as silver
-- Expectation: No results
SELECT
    (SELECT COUNT(*) FROM gold.fact_trips)   AS gold_rows,
    (SELECT COUNT(*) FROM silver.ops_trips)  AS silver_rows
WHERE (SELECT COUNT(*) FROM gold.fact_trips) <> (SELECT COUNT(*) FROM silver.ops_trips);

-- Check for Uniqueness of the Grain (run + service day + stop position)
-- Expectation: No results
SELECT
    run_id,
    date_key,
    stop_position,
    COUNT(*) AS duplicate_count
FROM gold.fact_trips
GROUP BY run_id, date_key, stop_position
HAVING COUNT(*) > 1;

-- Check the data model connectivity between fact and dimensions
-- Expectation: No results
SELECT TOP 100
    *
FROM gold.fact_trips f
LEFT JOIN gold.dim_dates d
    ON d.date_key = f.date_key
LEFT JOIN gold.dim_lines l
    ON l.line_key = f.line_key
LEFT JOIN gold.dim_stops s
    ON s.stop_key = f.stop_key
LEFT JOIN gold.dim_vehicles v
    ON v.vehicle_key = f.vehicle_key
WHERE d.date_key IS NULL
   OR l.line_key IS NULL
   OR s.stop_key IS NULL
   OR v.vehicle_key IS NULL;

-- Rows Pointing to the 'n/a' Members, by Status
-- Expectation: review (every CANCELLED row has no vehicle; the other n/a rows are unknown stops or vehicles)
SELECT
    status,
    COUNT(*)                                          AS fact_rows,
    SUM(CASE WHEN vehicle_key = 0 THEN 1 ELSE 0 END)  AS no_vehicle,
    SUM(CASE WHEN stop_key = 0 THEN 1 ELSE 0 END)     AS no_stop
FROM gold.fact_trips
GROUP BY status;

-- Check the Measures: only on OPERATED rows, never negative, hour between 0 and 23
-- Expectation: No results
SELECT TOP 100
    *
FROM gold.fact_trips
WHERE (status <> 'OPERATED' AND (delay_s IS NOT NULL OR dwell_s IS NOT NULL OR boardings IS NOT NULL OR alightings IS NOT NULL))
   OR dwell_s < 0
   OR boardings < 0
   OR alightings < 0
   OR planned_hour NOT BETWEEN 0 AND 23;

-- ====================================================================
-- Checking 'gold.fact_line_stops'
-- ====================================================================
-- Check for Uniqueness of the Grain (line + stop position)
-- Expectation: No results
SELECT
    line_key,
    stop_position,
    COUNT(*) AS duplicate_count
FROM gold.fact_line_stops
GROUP BY line_key, stop_position
HAVING COUNT(*) > 1;

-- Check the data model connectivity between fact and dimensions
-- Expectation: No results
SELECT
    *
FROM gold.fact_line_stops f
LEFT JOIN gold.dim_lines l
    ON l.line_key = f.line_key
LEFT JOIN gold.dim_stops s
    ON s.stop_key = f.stop_key
WHERE l.line_key IS NULL
   OR s.stop_key IS NULL
   OR f.stop_key = 0;

-- Lines without a Stop Sequence
-- Expectation: No results
SELECT
    l.*
FROM gold.dim_lines l
WHERE NOT EXISTS (
    SELECT 1 FROM gold.fact_line_stops f
    WHERE f.line_key = l.line_key
);
