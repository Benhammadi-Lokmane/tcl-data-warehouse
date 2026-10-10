/*
===============================================================================
DDL Script: Create Gold Views
===============================================================================
Script Purpose:
    This script creates views for the Gold layer in the data warehouse.
    The Gold layer represents the final dimension and fact tables: a fact
    constellation where two facts share the same (conformed) dimensions.

        fact_trips      -> dim_dates, dim_lines, dim_stops, dim_vehicles
        fact_line_stops -> dim_lines, dim_stops

    Each view performs transformations and combines data from the Silver layer
    to produce a clean, enriched, and business-ready dataset.

    Surrogate keys are ROW_NUMBER() over a unique order, so a dimension gives
    the same keys every time it is queried (the facts and the checks join on them).
    Key 0 is the 'n/a' member: a fact row whose stop or vehicle is unknown points to it.

Usage:
    - These views can be queried directly for analytics and reporting.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- =============================================================================
-- Create Dimension: gold.dim_dates
-- =============================================================================
IF OBJECT_ID('gold.dim_dates', 'V') IS NOT NULL
    DROP VIEW gold.dim_dates;
GO

CREATE VIEW gold.dim_dates AS
WITH bounds AS (
    -- Whole calendar years covering the service days loaded in silver
    SELECT
        DATEFROMPARTS(YEAR(MIN(trp_dt)), 1, 1)   AS first_day,
        DATEFROMPARTS(YEAR(MAX(trp_dt)), 12, 31) AS last_day
    FROM silver.ops_trips
), calendar AS (
    SELECT
        DATEADD(day, s.value, b.first_day) AS full_date
    FROM bounds b
    CROSS APPLY GENERATE_SERIES(0, DATEDIFF(day, b.first_day, b.last_day)) AS s
)
SELECT
    CAST(CONVERT(CHAR(8), full_date, 112) AS INT)  AS date_key,      -- yyyymmdd, e.g. 20260908
    full_date,
    DAY(full_date)                                 AS day,
    -- Monday = 1 ... Sunday = 7, whatever the session's language or DATEFIRST (1900-01-01 was a Monday)
    CHOOSE(DATEDIFF(day, '19000101', full_date) % 7 + 1,
           'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') AS day_name,
    DATEDIFF(day, '19000101', full_date) % 7 + 1   AS day_of_week,
    CASE
        WHEN DATEDIFF(day, '19000101', full_date) % 7 + 1 IN (6, 7) THEN 'true'
        ELSE 'false'
    END                                            AS is_weekend,
    DATEPART(iso_week, full_date)                  AS week_of_year,
    MONTH(full_date)                               AS month,
    CHOOSE(MONTH(full_date),
           'January', 'February', 'March', 'April', 'May', 'June',
           'July', 'August', 'September', 'October', 'November', 'December') AS month_name,
    DATEPART(quarter, full_date)                   AS quarter,
    YEAR(full_date)                                AS year
FROM calendar;
GO

-- =============================================================================
-- Create Dimension: gold.dim_lines
-- =============================================================================
IF OBJECT_ID('gold.dim_lines', 'V') IS NOT NULL
    DROP VIEW gold.dim_lines;
GO

CREATE VIEW gold.dim_lines AS
SELECT
    ROW_NUMBER() OVER (ORDER BY ln.ln_code, ln.ln_dir) AS line_key,  -- Surrogate key
    ln.ln_code                    AS line_code,
    ln.ln_dir                     AS direction,
    ln.ln_name                    AS line_name,
    ln.ln_color                   AS color,
    COALESCE(mc.mode, 'n/a')      AS mode,
    COALESCE(mc.category, 'n/a')  AS category,
    ln.ln_start_dt                AS start_date                       -- start of the current version
FROM silver.network_lines ln
LEFT JOIN silver.ops_mode_category mc
    ON ln.ln_mode_cat_id = mc.id
WHERE ln.ln_end_dt IS NULL; -- Current version only: no history in gold
GO

-- =============================================================================
-- Create Dimension: gold.dim_stops
-- =============================================================================
IF OBJECT_ID('gold.dim_stops', 'V') IS NOT NULL
    DROP VIEW gold.dim_stops;
GO

CREATE VIEW gold.dim_stops AS
SELECT
    0      AS stop_key,                 -- 'n/a' member: trips whose stop was not recorded
    NULL   AS stop_id,
    'n/a'  AS stop_name,
    'n/a'  AS address,
    'n/a'  AS city,
    'n/a'  AS fare_zone,
    'n/a'  AS wheelchair_accessible,
    NULL   AS latitude,
    NULL   AS longitude
UNION ALL
SELECT
    ROW_NUMBER() OVER (ORDER BY stp_id) AS stop_key,  -- Surrogate key
    stp_id,
    stp_name,
    stp_address,
    stp_city,
    stp_zone,
    stp_pmr,
    stp_lat,
    stp_lon
FROM silver.network_stops;
GO

-- =============================================================================
-- Create Dimension: gold.dim_vehicles
-- =============================================================================
IF OBJECT_ID('gold.dim_vehicles', 'V') IS NOT NULL
    DROP VIEW gold.dim_vehicles;
GO

CREATE VIEW gold.dim_vehicles AS
SELECT
    0      AS vehicle_key,              -- 'n/a' member: no vehicle (cancelled run) or vehicle missing from the fleet
    'n/a'  AS vehicle_id,
    'n/a'  AS vehicle_type,
    NULL   AS capacity,
    'n/a'  AS depot,
    NULL   AS in_service_date
UNION ALL
SELECT
    ROW_NUMBER() OVER (ORDER BY LEN(veh_id), veh_id) AS vehicle_key,  -- Surrogate key (numbers in numeric order)
    veh_id,
    veh_type,
    cap,
    depot,
    first_in_service                    -- first entry into service, over all versions of the vehicle
FROM (
    SELECT
        *,
        MIN(in_service) OVER (PARTITION BY veh_id) AS first_in_service
    FROM silver.ops_vehicles
) v
WHERE out_service IS NULL; -- Current version only: no history in gold
GO

-- =============================================================================
-- Create Fact Table: gold.fact_trips
-- =============================================================================
IF OBJECT_ID('gold.fact_trips', 'V') IS NOT NULL
    DROP VIEW gold.fact_trips;
GO

CREATE VIEW gold.fact_trips AS
SELECT
    t.trp_run                                     AS run_id,
    t.trp_pos                                     AS stop_position,
    CAST(CONVERT(CHAR(8), t.trp_dt, 112) AS INT)  AS date_key,          -- service day (a run after midnight belongs to the day before)
    ln.line_key                                   AS line_key,
    COALESCE(st.stop_key, 0)                      AS stop_key,
    COALESCE(ve.vehicle_key, 0)                   AS vehicle_key,
    t.trp_status                                  AS status,
    t.trp_plan_arr                                AS planned_arrival,
    t.trp_plan_dep                                AS planned_departure,
    t.trp_arr                                     AS actual_arrival,
    t.trp_dep                                     AS actual_departure,
    DATEPART(hour, t.trp_plan_arr)                AS planned_hour,      -- clock hour 0-23, for peak / off-peak analysis
    t.trp_delay_s                                 AS delay_s,
    t.trp_dwell_s                                 AS dwell_s,
    t.trp_board                                   AS boardings,
    t.trp_alight                                  AS alightings
FROM silver.ops_trips t
LEFT JOIN gold.dim_lines ln
    ON t.trp_line_code = ln.line_code
   AND t.trp_dir = ln.direction
LEFT JOIN gold.dim_stops st
    ON t.trp_stop = st.stop_id
LEFT JOIN gold.dim_vehicles ve
    ON t.trp_veh = ve.vehicle_id;
GO

-- =============================================================================
-- Create Fact Table: gold.fact_line_stops (route structure: no measures, no dates)
-- =============================================================================
IF OBJECT_ID('gold.fact_line_stops', 'V') IS NOT NULL
    DROP VIEW gold.fact_line_stops;
GO

CREATE VIEW gold.fact_line_stops AS
SELECT
    ln.line_key               AS line_key,
    COALESCE(st.stop_key, 0)  AS stop_key,
    ls.ls_pos                 AS stop_position
FROM silver.network_line_stop ls
LEFT JOIN gold.dim_lines ln
    ON ls.ls_line = ln.line_code
   AND ls.ls_dir = ln.direction
LEFT JOIN gold.dim_stops st
    ON ls.ls_stop = st.stop_id;
GO
