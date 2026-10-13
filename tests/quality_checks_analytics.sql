/*
===============================================================================
Quality Checks
===============================================================================
Script Purpose:
    This script performs quality checks on the report views of the 'analytics'
    schema. These checks ensure:
    - The views exist and the 'analyst' role can read them, and only them.
    - Each view has one row per member of its dimension (completeness, uniqueness).
    - The totals of each view equal the totals of gold.fact_trips (no row lost
      or counted twice).
    - The measures are in range and the segments follow their definitions.

Usage Notes:
    - Run after the report views and the analyst role are created
      (analytics/reports/12 to 15) and after each EXEC gold.load_gold.
    - Investigate and resolve any discrepancies found during the checks.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ====================================================================
-- Checking Objects and Access
-- ====================================================================
-- Check that the Report Views Exist
-- Expectation: No results
SELECT
    v.view_name
FROM (VALUES ('report_lines'), ('report_stops'), ('report_vehicles')) AS v(view_name)
WHERE OBJECT_ID('analytics.' + v.view_name, 'V') IS NULL;

-- Check the Permissions of the 'analyst' Role (as the test user 'analyst_demo')
-- Expectation: No results (SELECT on the analytics views, nothing on gold, silver or bronze)
EXECUTE AS USER = 'analyst_demo';
SELECT
    object_name,
    expected,
    actual
FROM (VALUES
    ('analytics.report_lines',    1, COALESCE(HAS_PERMS_BY_NAME('analytics.report_lines',    'OBJECT', 'SELECT'), 0)),
    ('analytics.report_stops',    1, COALESCE(HAS_PERMS_BY_NAME('analytics.report_stops',    'OBJECT', 'SELECT'), 0)),
    ('analytics.report_vehicles', 1, COALESCE(HAS_PERMS_BY_NAME('analytics.report_vehicles', 'OBJECT', 'SELECT'), 0)),
    ('gold.fact_trips',           0, COALESCE(HAS_PERMS_BY_NAME('gold.fact_trips',           'OBJECT', 'SELECT'), 0)),
    ('silver.ops_trips',          0, COALESCE(HAS_PERMS_BY_NAME('silver.ops_trips',          'OBJECT', 'SELECT'), 0)),
    ('bronze.ops_trips',          0, COALESCE(HAS_PERMS_BY_NAME('bronze.ops_trips',          'OBJECT', 'SELECT'), 0))
) AS p(object_name, expected, actual)
WHERE actual <> expected;

-- The analyst can read a view although it has no right on the gold tables behind it (ownership chaining)
-- Expectation: 801 rows
SELECT
    COUNT(*) AS report_lines_rows
FROM analytics.report_lines;
REVERT;
GO

-- ====================================================================
-- Checking Completeness and Uniqueness
-- ====================================================================
-- One Row per Member of the Dimension (all lines, stops and vehicles, 'n/a' members included)
-- Expectation: No results
SELECT
    view_name,
    view_rows,
    expected_rows
FROM (
    SELECT 'report_lines' AS view_name,
           (SELECT COUNT(*) FROM analytics.report_lines) AS view_rows,
           (SELECT COUNT(DISTINCT line_code) FROM gold.dim_lines) AS expected_rows
    UNION ALL
    SELECT 'report_stops',
           (SELECT COUNT(*) FROM analytics.report_stops),
           (SELECT COUNT(*) FROM gold.dim_stops)
    UNION ALL
    SELECT 'report_vehicles',
           (SELECT COUNT(*) FROM analytics.report_vehicles),
           (SELECT COUNT(*) FROM gold.dim_vehicles)
) t
WHERE view_rows <> expected_rows;

-- Check for Uniqueness of the Grain of each View
-- Expectation: No results
SELECT 'report_lines' AS view_name, line_code AS member, COUNT(*) AS duplicate_count
FROM analytics.report_lines
GROUP BY line_code
HAVING COUNT(*) > 1
UNION ALL
SELECT 'report_stops', CAST(stop_key AS VARCHAR(50)), COUNT(*)
FROM analytics.report_stops
GROUP BY stop_key
HAVING COUNT(*) > 1
UNION ALL
SELECT 'report_vehicles', CAST(vehicle_key AS VARCHAR(50)), COUNT(*)
FROM analytics.report_vehicles
GROUP BY vehicle_key
HAVING COUNT(*) > 1;

-- ====================================================================
-- Checking Totals against gold.fact_trips
-- ====================================================================
-- Passages, passengers, runs and cancelled runs of each view vs the fact table
-- (stops have no runs: NULL is not compared)
-- Expectation: No results
WITH fact_passages AS (
    SELECT
        COUNT(*)                                              AS planned_passages,
        SUM(CASE WHEN status = 'OPERATED' THEN 1 ELSE 0 END)  AS operated_passages,
        SUM(COALESCE(boardings, 0))                           AS boardings,
        SUM(COALESCE(alightings, 0))                          AS alightings
    FROM gold.fact_trips
), fact_runs AS (
    SELECT
        COUNT(*)          AS planned_runs,
        SUM(is_cancelled) AS cancelled_runs
    FROM (
        SELECT
            run_id,
            date_key,
            MIN(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
        FROM gold.fact_trips
        GROUP BY run_id, date_key
    ) r
), view_totals AS (
    SELECT 'report_lines' AS view_name,
           SUM(planned_passages)                AS planned_passages,
           SUM(operated_passages)               AS operated_passages,
           SUM(COALESCE(boardings_equipped, 0))  AS boardings,
           SUM(COALESCE(alightings_equipped, 0)) AS alightings,
           SUM(planned_runs)                    AS planned_runs,
           SUM(cancelled_runs)                  AS cancelled_runs
    FROM analytics.report_lines
    UNION ALL
    SELECT 'report_stops',
           SUM(planned_passages),
           SUM(operated_passages),
           SUM(COALESCE(boardings_equipped, 0)),
           SUM(COALESCE(alightings_equipped, 0)),
           NULL,
           NULL
    FROM analytics.report_stops
    UNION ALL
    SELECT 'report_vehicles',
           SUM(planned_passages),
           SUM(operated_passages),
           SUM(COALESCE(boardings_equipped, 0)),
           SUM(COALESCE(alightings_equipped, 0)),
           SUM(planned_runs),
           SUM(cancelled_runs)
    FROM analytics.report_vehicles
)
SELECT
    v.*,
    fp.planned_passages  AS fact_planned_passages,
    fp.operated_passages AS fact_operated_passages,
    fp.boardings         AS fact_boardings,
    fp.alightings        AS fact_alightings,
    fr.planned_runs      AS fact_planned_runs,
    fr.cancelled_runs    AS fact_cancelled_runs
FROM view_totals v
CROSS JOIN fact_passages fp
CROSS JOIN fact_runs fr
WHERE v.planned_passages  <> fp.planned_passages
   OR v.operated_passages <> fp.operated_passages
   OR v.boardings         <> fp.boardings
   OR v.alightings        <> fp.alightings
   OR v.planned_runs      <> fr.planned_runs
   OR v.cancelled_runs    <> fr.cancelled_runs;

-- ====================================================================
-- Checking 'analytics.report_lines'
-- ====================================================================
-- Check the Measures: counts consistent, percentages between 0 and 100, shares adding up to 100 %
-- (rounded to 0.1: a gap of 0.2 is allowed), median <= 95th percentile
-- Expectation: No results
SELECT
    *
FROM analytics.report_lines
WHERE operated_runs > planned_runs
   OR cancelled_runs > planned_runs
   OR operated_passages + skipped_passages > planned_passages
   OR cancellation_rate_pct NOT BETWEEN 0 AND 100
   OR on_time_pct NOT BETWEEN 0 AND 100
   OR late_pct NOT BETWEEN 0 AND 100
   OR early_pct NOT BETWEEN 0 AND 100
   OR ABS(on_time_pct + late_pct + early_pct - 100) > 0.2
   OR median_delay_s > p95_delay_s
   OR (operated_passages = 0 AND avg_delay_s IS NOT NULL)
   OR (counted_passages = 0 AND boardings_equipped IS NOT NULL);

-- Check the Segments follow their Definitions (late_pct is rounded: boundaries are inclusive on both sides)
-- Expectation: No results
SELECT
    line_code,
    is_rated,
    late_pct,
    punctuality_segment,
    is_in_difficulty,
    is_priority
FROM analytics.report_lines
WHERE (is_rated = 0 AND punctuality_segment <> 'Not rated')
   OR (is_rated = 1 AND punctuality_segment = 'Not rated')
   OR (is_rated = 1 AND (category <> 'Regular' OR operated_runs < 20))
   OR (punctuality_segment = 'Good'          AND late_pct > 10)
   OR (punctuality_segment = 'Watch'         AND late_pct NOT BETWEEN 10 AND 20)
   OR (punctuality_segment = 'In difficulty' AND late_pct < 20)
   OR (is_in_difficulty = 1 AND punctuality_segment <> 'In difficulty')
   OR (is_in_difficulty = 0 AND punctuality_segment = 'In difficulty')
   OR (is_priority = 1 AND is_in_difficulty = 0);

-- Segment Distribution
-- Expectation: review (Good 9, Watch 12, In difficulty 142 of which 76 priority, Not rated 638)
SELECT
    punctuality_segment,
    COUNT(*)         AS lines,
    SUM(is_priority) AS priority_lines
FROM analytics.report_lines
GROUP BY punctuality_segment
ORDER BY lines DESC;

-- ====================================================================
-- Checking 'analytics.report_stops'
-- ====================================================================
-- Check the Measures: every passage has one status, percentages between 0 and 100, busiest hour consistent
-- Expectation: No results
SELECT
    *
FROM analytics.report_stops
WHERE operated_passages + skipped_passages + cancelled_passages <> planned_passages
   OR on_time_pct NOT BETWEEN 0 AND 100
   OR late_pct NOT BETWEEN 0 AND 100
   OR busiest_hour_passages > planned_passages
   OR busiest_service_hour NOT BETWEEN 0 AND 24
   OR (planned_passages > 0 AND busiest_service_hour IS NULL)
   OR (counted_passages = 0 AND boardings_equipped IS NOT NULL);

-- Check the Demand Segments follow their Definitions
-- Expectation: No results
SELECT
    stop_key,
    stop_name,
    operated_passages,
    counted_passages,
    boardings_equipped,
    demand_segment
FROM analytics.report_stops
WHERE (stop_key = 0 AND demand_segment <> 'n/a')
   OR (stop_key <> 0 AND demand_segment = 'n/a')
   OR (demand_segment = 'Not served' AND operated_passages > 0)
   OR (demand_segment = 'No count'   AND (operated_passages = 0 OR counted_passages > 0))
   OR (demand_segment = 'High'       AND boardings_equipped < 100)
   OR (demand_segment = 'Medium'     AND boardings_equipped NOT BETWEEN 20 AND 99)
   OR (demand_segment = 'Low'        AND boardings_equipped >= 20);

-- Segment Distribution
-- Expectation: review (High 874, Medium 2,221, Low 3,471, No count 2,906, Not served 301, n/a 1)
SELECT
    demand_segment,
    COUNT(*)                AS stops,
    SUM(boardings_equipped) AS boardings_equipped
FROM analytics.report_stops
GROUP BY demand_segment
ORDER BY stops DESC;

-- ====================================================================
-- Checking 'analytics.report_vehicles'
-- ====================================================================
-- Check the Measures: cancelled runs only on the 'n/a' vehicle (cancelled runs have no vehicle),
-- counter flag consistent, age known only when the date is known, daily span between 0 and 25 hours
-- (a service day is longer than 24 hours: 00:00 to 00:44 the next day)
-- Expectation: No results
SELECT
    *
FROM analytics.report_vehicles
WHERE operated_runs > planned_runs
   OR (vehicle_key <> 0 AND cancelled_runs > 0)
   OR (has_passenger_counter = 1 AND counted_passages = 0)
   OR (has_passenger_counter = 0 AND counted_passages > 0)
   OR (age_years IS NULL AND in_service_date IS NOT NULL AND vehicle_key <> 0)
   OR age_years < 0
   OR avg_daily_span_h NOT BETWEEN 0 AND 25
   OR on_time_pct NOT BETWEEN 0 AND 100
   OR late_pct NOT BETWEEN 0 AND 100;

-- Fleet in Service
-- Expectation: review (1,985 vehicles used, 495 with a passenger counter, 'n/a' member excluded)
SELECT
    COUNT(*)                   AS vehicles,
    SUM(CASE WHEN planned_runs > 0 THEN 1 ELSE 0 END) AS vehicles_used,
    SUM(has_passenger_counter) AS vehicles_with_counter
FROM analytics.report_vehicles
WHERE vehicle_key <> 0;
