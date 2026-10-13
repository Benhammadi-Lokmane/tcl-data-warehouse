/*
===============================================================================
Vehicle Report
===============================================================================
Purpose:
    - Consolidate the key metrics of every vehicle in one view: fleet attributes, age, use,
      punctuality and passengers carried. Vehicles are simulated.

Business questions:
    - How old is each vehicle, and does it have a passenger counter?
    - How many runs, lines and service days did each vehicle make, and how long is its service day?
    - How punctual were its passages?
    - How many passengers did it carry (equipped vehicles only)?

Columns (one row per vehicle; all 2,037 rows of dim_vehicles):
    - Vehicle:       vehicle_key, vehicle_id, vehicle_type, capacity, depot, in_service_date, age_years,
                     has_passenger_counter
    - Use:           planned_runs, operated_runs, cancelled_runs, lines_served, service_days, avg_daily_span_h
    - Punctuality:   planned_passages, operated_passages, avg_delay_s, on_time_pct, late_pct
    - Passengers:    counted_passages, boardings_equipped, alightings_equipped

SQL Functions Used:
    - CTE (WITH), CREATE OR ALTER VIEW, LEFT JOIN, CROSS JOIN
    - COUNT(), COUNT(DISTINCT), SUM(), AVG(), MIN(), MAX(), CASE WHEN, COALESCE(), NULLIF(), CAST()
    - DATEDIFF(), DATEADD()

Notes:
    - vehicle_key 0 is 'n/a': cancelled runs (no vehicle) and vehicles missing from the fleet. It keeps the
      totals equal to the fact table, so every cancelled run is on it; filter it out with vehicle_key <> 0.
    - A run always has a single vehicle, so runs add up across vehicles.
    - Age in whole years at the last service day (not GETDATE()). Daily span = first actual departure to last
      actual arrival of the vehicle in a service day, averaged over its service days.
    - has_passenger_counter = at least one passage counted (boardings or alightings).

Usage Example:
    SELECT vehicle_type, AVG(age_years) AS avg_age, AVG(late_pct) FROM analytics.report_vehicles
    WHERE operated_runs > 0 AND vehicle_key <> 0 GROUP BY vehicle_type;
===============================================================================
*/
USE TclDataWarehouse;
GO

IF SCHEMA_ID('analytics') IS NULL
    EXEC('CREATE SCHEMA analytics');
GO

CREATE OR ALTER VIEW analytics.report_vehicles AS
WITH base AS (
    -- 1) Base: one row per passage, with its vehicle and line
    SELECT
        f.vehicle_key,
        f.run_id,
        f.date_key,
        l.line_code,
        f.status,
        f.delay_s,
        f.boardings,
        f.alightings,
        f.actual_departure,
        f.actual_arrival
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
), runs AS (
    -- 2a) Runs: one row per run (a run has a single vehicle)
    SELECT
        vehicle_key,
        run_id,
        date_key,
        MIN(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled,
        MAX(CASE WHEN status = 'OPERATED'  THEN 1 ELSE 0 END) AS is_operated
    FROM base
    GROUP BY vehicle_key, run_id, date_key
), run_totals AS (
    SELECT
        vehicle_key,
        COUNT(*)          AS planned_runs,
        SUM(is_operated)  AS operated_runs,
        SUM(is_cancelled) AS cancelled_runs
    FROM runs
    GROUP BY vehicle_key
), passage_totals AS (
    -- 2b) Aggregation of the passages per vehicle (delay conditions are only true on operated passages)
    SELECT
        vehicle_key,
        COUNT(DISTINCT line_code)                                            AS lines_served,
        COUNT(DISTINCT date_key)                                             AS service_days,
        COUNT(*)                                                             AS planned_passages,
        SUM(CASE WHEN status = 'OPERATED' THEN 1 ELSE 0 END)                 AS operated_passages,
        SUM(CASE WHEN status = 'OPERATED' THEN CAST(delay_s AS BIGINT) ELSE 0 END) AS delay_sum_s,
        SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END)         AS on_time_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)                       AS late_passages,
        SUM(CASE WHEN boardings IS NOT NULL OR alightings IS NOT NULL THEN 1 ELSE 0 END) AS counted_passages,
        SUM(COALESCE(boardings, 0))                                          AS boardings_sum,
        SUM(COALESCE(alightings, 0))                                         AS alightings_sum
    FROM base
    GROUP BY vehicle_key
), daily_spans AS (
    -- 2c) Service span of each vehicle in each service day (operated passages have actual times)
    SELECT
        vehicle_key,
        date_key,
        DATEDIFF(minute, MIN(actual_departure), MAX(actual_arrival)) AS span_minutes
    FROM base
    WHERE status = 'OPERATED'
    GROUP BY vehicle_key, date_key
), spans AS (
    SELECT
        vehicle_key,
        AVG(span_minutes / 60.0) AS avg_daily_span_h
    FROM daily_spans
    GROUP BY vehicle_key
), reference AS (
    -- Ages are measured at the last service day
    SELECT
        full_date AS last_service_day
    FROM gold.dim_dates
    WHERE date_key = (SELECT MAX(date_key) FROM gold.fact_trips)
)
-- 3) Final: every vehicle of dim_vehicles; counts are 0 for the vehicles not used, averages stay NULL
SELECT
    v.vehicle_key,
    v.vehicle_id,
    v.vehicle_type,
    v.capacity,
    v.depot,
    v.in_service_date,
    -- DATEDIFF(year) counts year boundaries: subtract 1 before the anniversary
    DATEDIFF(year, v.in_service_date, ref.last_service_day)
        - CASE
              WHEN DATEADD(year, DATEDIFF(year, v.in_service_date, ref.last_service_day), v.in_service_date) > ref.last_service_day
              THEN 1
              ELSE 0
          END                                                                            AS age_years,
    CASE WHEN p.counted_passages > 0 THEN 1 ELSE 0 END                                   AS has_passenger_counter,
    COALESCE(r.planned_runs, 0)                                                          AS planned_runs,
    COALESCE(r.operated_runs, 0)                                                         AS operated_runs,
    COALESCE(r.cancelled_runs, 0)                                                        AS cancelled_runs,
    COALESCE(p.lines_served, 0)                                                          AS lines_served,
    COALESCE(p.service_days, 0)                                                          AS service_days,
    CAST(sp.avg_daily_span_h AS DECIMAL(4, 1))                                           AS avg_daily_span_h,
    COALESCE(p.planned_passages, 0)                                                      AS planned_passages,
    COALESCE(p.operated_passages, 0)                                                     AS operated_passages,
    CAST(1.0 * p.delay_sum_s / NULLIF(p.operated_passages, 0) AS DECIMAL(8, 1))          AS avg_delay_s,
    CAST(100.0 * p.on_time_passages / NULLIF(p.operated_passages, 0) AS DECIMAL(5, 1))   AS on_time_pct,
    CAST(100.0 * p.late_passages / NULLIF(p.operated_passages, 0) AS DECIMAL(5, 1))      AS late_pct,
    COALESCE(p.counted_passages, 0)                                                      AS counted_passages,
    CASE WHEN p.counted_passages > 0 THEN p.boardings_sum END                            AS boardings_equipped,
    CASE WHEN p.counted_passages > 0 THEN p.alightings_sum END                           AS alightings_equipped
FROM gold.dim_vehicles v
CROSS JOIN reference ref
LEFT JOIN run_totals r
    ON r.vehicle_key = v.vehicle_key
LEFT JOIN passage_totals p
    ON p.vehicle_key = v.vehicle_key
LEFT JOIN spans sp
    ON sp.vehicle_key = v.vehicle_key;
GO
