/*
===============================================================================
Measures Exploration (Key Metrics)
===============================================================================
Purpose:
    - Calculate the headline numbers of the network for the service period.
    - Combine them into one key-metrics report: every later breakdown must add up to these totals.

Business questions:
    - How many passages and runs were planned, operated, cancelled or skipped?
    - How many lines, stops and vehicles took part in the service?
    - What are the average and median delay, and the share of passages on time, late and early?
    - How many passengers were counted (vehicles with a passenger counter only)?

SQL Functions Used:
    - COUNT(), COUNT(DISTINCT), SUM(), AVG(), MIN(), MAX(), CASE WHEN
    - PERCENTILE_CONT() OVER (), APPROX_PERCENTILE_CONT(), NULLIF(), CAST()
    - UNION ALL, CTE (WITH)

Notes:
    - Passage = one run at one stop (one row of fact_trips). Run = (run_id, date_key).
    - Delay measures use OPERATED passages only. On time = -60 to +180 s, late > 180 s, early < -60 s.
    - Passenger measures cover equipped vehicles only (boardings is NULL elsewhere).
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Passages
-- ============================================================================
-- Passages by status, in one scan of the fact table
-- Expectation: 471,946 planned = 464,281 operated + 4,373 cancelled + 3,292 skipped
SELECT
    COUNT(*)                                               AS planned_passages,
    SUM(CASE WHEN status = 'OPERATED'  THEN 1 ELSE 0 END)  AS operated_passages,
    SUM(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END)  AS cancelled_passages,
    SUM(CASE WHEN status = 'SKIPPED'   THEN 1 ELSE 0 END)  AS skipped_passages
FROM gold.fact_trips;

-- ============================================================================
-- 2. Runs
-- ============================================================================
-- One row per run, with flags; a run is cancelled when ALL its passages are cancelled
-- Expectation: 22,427 planned runs, 184 cancelled (0.82 %), 0 partly cancelled, 1,952 with a skipped stop
WITH runs AS (
    SELECT
        run_id,
        date_key,
        MIN(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled,       -- all passages cancelled
        MAX(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS has_cancelled_stop, -- at least one
        MAX(CASE WHEN status = 'SKIPPED'   THEN 1 ELSE 0 END) AS has_skipped_stop
    FROM gold.fact_trips
    GROUP BY run_id, date_key
)
SELECT
    COUNT(*)                                                         AS planned_runs,
    SUM(is_cancelled)                                                AS cancelled_runs,
    SUM(has_cancelled_stop) - SUM(is_cancelled)                      AS partly_cancelled_runs,
    SUM(has_skipped_stop)                                            AS runs_with_skipped_stop,
    CAST(100.0 * SUM(is_cancelled) / NULLIF(COUNT(*), 0) AS DECIMAL(5, 2)) AS cancellation_rate_pct
FROM runs;

-- ============================================================================
-- 3. Lines, stops and vehicles in service
-- ============================================================================
-- Lines in the day's timetable (line = line_code; line-direction = line_key)
-- Expectation: 774 lines of 801, 1,523 line-directions of 1,585
SELECT
    COUNT(DISTINCT l.line_code) AS lines,
    COUNT(DISTINCT f.line_key)  AS line_directions
FROM gold.fact_trips f
JOIN gold.dim_lines l
    ON l.line_key = f.line_key;

-- Stops actually served (operated passages, without the 'n/a' member)
-- Expectation: 9,472 of 9,773
SELECT
    COUNT(DISTINCT stop_key) AS stops_served
FROM gold.fact_trips
WHERE status = 'OPERATED'
  AND stop_key <> 0;

-- Vehicles used, and vehicles with a passenger counter
-- Expectation: 1,985 used, 495 equipped
SELECT
    COUNT(DISTINCT vehicle_key)                                    AS vehicles_used,
    (SELECT COUNT(DISTINCT vehicle_key)
     FROM gold.fact_trips
     WHERE (boardings IS NOT NULL OR alightings IS NOT NULL)
       AND vehicle_key <> 0)                                       AS equipped_vehicles
FROM gold.fact_trips
WHERE vehicle_key <> 0;

-- ============================================================================
-- 4. Delay (operated passages)
-- ============================================================================
-- Average delay and punctuality shares
-- Expectation: average 149.7 s; on time 69.4 %, late 29.5 %, early 1.1 % (adding up to 100 %)
SELECT
    CAST(AVG(delay_s * 1.0) AS DECIMAL(8, 1))                                            AS avg_delay_s,  -- * 1.0: AVG of an INT is an INT
    MIN(delay_s)                                                                         AS min_delay_s,
    MAX(delay_s)                                                                         AS max_delay_s,
    CAST(100.0 * SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1)) AS on_time_pct,
    CAST(100.0 * SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)              / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1)) AS late_pct,
    CAST(100.0 * SUM(CASE WHEN delay_s < -60 THEN 1 ELSE 0 END)              / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1)) AS early_pct
FROM gold.fact_trips
WHERE status = 'OPERATED';

-- Median and 95th percentile: PERCENTILE_CONT is a window function (one value repeated on every row,
-- hence DISTINCT); APPROX_PERCENTILE_CONT is an aggregate, faster but approximate
-- Expectation: median 74 s, 95th percentile 586 s (the approximate median is close to 74 s and varies between runs)
SELECT DISTINCT
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY delay_s) OVER () AS median_delay_s,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY delay_s) OVER () AS p95_delay_s
FROM gold.fact_trips
WHERE status = 'OPERATED';

SELECT
    APPROX_PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY delay_s) AS approx_median_delay_s
FROM gold.fact_trips
WHERE status = 'OPERATED';

-- ============================================================================
-- 5. Passengers (equipped vehicles only)
-- ============================================================================
-- A counter can miss one of the two values at a stop: keep the passages where either one was counted
-- Expectation: 578,899 boardings, 578,843 alightings
SELECT
    COUNT(*)        AS counted_passages,
    SUM(boardings)  AS boardings,
    SUM(alightings) AS alightings
FROM gold.fact_trips
WHERE boardings IS NOT NULL
   OR alightings IS NOT NULL;

-- ============================================================================
-- 6. Key metrics report
-- ============================================================================
-- One row per metric; each value equals its query above
-- Every value is cast to the same type: UNION ALL needs compatible types in every branch
WITH passages AS (
    SELECT
        COUNT(*)                                              AS planned_passages,
        SUM(CASE WHEN status = 'OPERATED'  THEN 1 ELSE 0 END) AS operated_passages,
        SUM(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS cancelled_passages,
        SUM(CASE WHEN status = 'SKIPPED'   THEN 1 ELSE 0 END) AS skipped_passages
    FROM gold.fact_trips
), runs AS (
    SELECT
        run_id,
        date_key,
        MIN(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips
    GROUP BY run_id, date_key
), delays AS (
    SELECT
        AVG(delay_s * 1.0)                                                 AS avg_delay_s,
        100.0 * SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS on_time_pct,
        100.0 * SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)              / NULLIF(COUNT(*), 0) AS late_pct
    FROM gold.fact_trips
    WHERE status = 'OPERATED'
), median_delay AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY delay_s) OVER () AS median_delay_s
    FROM gold.fact_trips
    WHERE status = 'OPERATED'
), passengers AS (
    SELECT
        SUM(boardings)  AS boardings,
        SUM(alightings) AS alightings
    FROM gold.fact_trips
    WHERE boardings IS NOT NULL
       OR alightings IS NOT NULL
), report AS (
    SELECT 1 AS metric_id, 'Planned passages' AS measure_name, CAST(planned_passages AS DECIMAL(12, 2)) AS measure_value FROM passages
    UNION ALL
    SELECT 2,  'Operated passages',              CAST(operated_passages AS DECIMAL(12, 2))                 FROM passages
    UNION ALL
    SELECT 3,  'Cancelled passages',             CAST(cancelled_passages AS DECIMAL(12, 2))                FROM passages
    UNION ALL
    SELECT 4,  'Skipped passages',               CAST(skipped_passages AS DECIMAL(12, 2))                  FROM passages
    UNION ALL
    SELECT 5,  'Planned runs',                   CAST(COUNT(*) AS DECIMAL(12, 2))                          FROM runs
    UNION ALL
    SELECT 6,  'Cancelled runs',                 CAST(SUM(is_cancelled) AS DECIMAL(12, 2))                 FROM runs
    UNION ALL
    SELECT 7,  'Cancellation rate (%)',          CAST(100.0 * SUM(is_cancelled) / NULLIF(COUNT(*), 0) AS DECIMAL(12, 2)) FROM runs
    UNION ALL
    SELECT 8,  'Lines in service',               CAST(COUNT(DISTINCT l.line_code) AS DECIMAL(12, 2))       FROM gold.fact_trips f JOIN gold.dim_lines l ON l.line_key = f.line_key
    UNION ALL
    SELECT 9,  'Stops served',                   CAST(COUNT(DISTINCT stop_key) AS DECIMAL(12, 2))          FROM gold.fact_trips WHERE status = 'OPERATED' AND stop_key <> 0
    UNION ALL
    SELECT 10, 'Vehicles used',                  CAST(COUNT(DISTINCT vehicle_key) AS DECIMAL(12, 2))       FROM gold.fact_trips WHERE vehicle_key <> 0
    UNION ALL
    SELECT 11, 'Average delay (s)',              CAST(avg_delay_s AS DECIMAL(12, 2))                       FROM delays
    UNION ALL
    SELECT 12, 'Median delay (s)',               CAST(median_delay_s AS DECIMAL(12, 2))                    FROM median_delay
    UNION ALL
    SELECT 13, 'On time (%)',                    CAST(on_time_pct AS DECIMAL(12, 2))                       FROM delays
    UNION ALL
    SELECT 14, 'Late (%)',                       CAST(late_pct AS DECIMAL(12, 2))                          FROM delays
    UNION ALL
    SELECT 15, 'Boardings (equipped vehicles)',  CAST(boardings AS DECIMAL(12, 2))                         FROM passengers
    UNION ALL
    SELECT 16, 'Alightings (equipped vehicles)', CAST(alightings AS DECIMAL(12, 2))                        FROM passengers
)
-- UNION ALL returns rows in no guaranteed order: sort on metric_id
SELECT
    measure_name,
    measure_value
FROM report
ORDER BY metric_id;
