/*
===============================================================================
Magnitude Analysis
===============================================================================
Purpose:
    - Break down the key measures by mode, line category, fare zone and city.
    - Show where the service and the passengers are.

Business questions:
    - How are passages, runs and delays split by mode and by line category?
    - Which lines did not run on the service day?
    - How are passages and boardings spread over fare zones and cities?
    - How does passenger demand compare between modes?

SQL Functions Used:
    - COUNT(), COUNT(DISTINCT), SUM(), AVG(), MIN(), MAX(), CASE WHEN
    - PERCENTILE_CONT() OVER (PARTITION BY), NOT EXISTS, NULLIF(), CAST()

Note:
    - Passages, runs and boardings add up across groups (totals = 04_measures_exploration.sql);
      distinct counts (lines, stops) do not.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. By mode
-- ============================================================================
-- Lines, runs and passages per mode
-- Expectation: runs add up to 22,427 and passages to 471,946; Bus 754 lines / 16,041 runs / 369,005 passages
WITH runs AS (
    SELECT
        run_id,
        date_key,
        line_key,
        COUNT(*) AS passages
    FROM gold.fact_trips
    GROUP BY run_id, date_key, line_key
)
SELECT
    l.mode,
    COUNT(DISTINCT l.line_code) AS lines,
    COUNT(*)                    AS runs,
    SUM(r.passages)             AS planned_passages
FROM runs r
JOIN gold.dim_lines l
    ON l.line_key = r.line_key
GROUP BY l.mode
ORDER BY planned_passages DESC;

-- Runs on more than one line-direction (otherwise runs would be counted twice in a breakdown)
-- Expectation: No results
SELECT
    run_id,
    date_key,
    COUNT(DISTINCT line_key) AS line_directions
FROM gold.fact_trips
GROUP BY run_id, date_key
HAVING COUNT(DISTINCT line_key) > 1;

-- Delay per mode (operated passages); the median is the same on every row of a mode, hence MAX()
-- Expectation: average / median delay Bus 171.6 / 97 s, Trolleybus 120.5 / 75, Tram 95.1 / 55, Metro 9.5 / 7;
-- Metro, Funicular and River shuttle 100 % on time
WITH operated AS (
    SELECT
        l.mode,
        f.delay_s,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.delay_s) OVER (PARTITION BY l.mode) AS median_delay_s
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
)
SELECT
    mode,
    COUNT(*)                                                                                           AS operated_passages,
    CAST(AVG(delay_s * 1.0) AS DECIMAL(8, 1))                                                          AS avg_delay_s,
    MAX(median_delay_s)                                                                                AS median_delay_s,
    CAST(100.0 * SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1)) AS on_time_pct,
    CAST(100.0 * SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)              / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1)) AS late_pct
FROM operated
GROUP BY mode
ORDER BY avg_delay_s DESC;

-- ============================================================================
-- 2. By line category
-- ============================================================================
-- Lines that ran, runs, passages and cancellations per category
-- Expectation: Regular 192 lines / 20,787 runs / 167 cancelled (0.80 %); School 580 / 1,562 / 17 (1.09 %);
-- runs add up to 22,427 and cancelled runs to 184
WITH runs AS (
    SELECT
        run_id,
        date_key,
        line_key,
        COUNT(*)                                              AS passages,
        MIN(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips
    GROUP BY run_id, date_key, line_key
)
SELECT
    l.category,
    COUNT(DISTINCT l.line_code)                                           AS lines_run,
    COUNT(*)                                                              AS runs,
    SUM(r.passages)                                                       AS planned_passages,
    SUM(r.is_cancelled)                                                   AS cancelled_runs,
    CAST(100.0 * SUM(r.is_cancelled) / NULLIF(COUNT(*), 0) AS DECIMAL(5, 2)) AS cancellation_rate_pct
FROM runs r
JOIN gold.dim_lines l
    ON l.line_key = r.line_key
GROUP BY l.category
ORDER BY runs DESC;

-- ============================================================================
-- 3. Lines that did not run
-- ============================================================================
-- Lines with no run in any direction (NOT EXISTS: NOT IN would return nothing if line_key were NULL)
-- Expectation: 27 lines: Regular 13, School 9, Event 2 (1 bus, 1 tram), one per replacement category
WITH lines_run AS (
    SELECT DISTINCT
        l.line_code
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
)
SELECT
    l.category,
    l.mode,
    COUNT(DISTINCT l.line_code) AS lines_not_run
FROM gold.dim_lines l
WHERE NOT EXISTS (
    SELECT 1
    FROM lines_run r
    WHERE r.line_code = l.line_code
)
GROUP BY l.category, l.mode
ORDER BY lines_not_run DESC, l.category;

-- List of the lines that did not run
-- Expectation: 27 rows (night lines PL1-PL4, N18x shuttles, event shuttles, replacement buses, school lines)
WITH lines_run AS (
    SELECT DISTINCT
        l.line_code
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
)
SELECT
    l.line_code,
    l.mode,
    l.category,
    MIN(l.line_name) AS line_name,
    COUNT(*)         AS directions
FROM gold.dim_lines l
WHERE NOT EXISTS (
    SELECT 1
    FROM lines_run r
    WHERE r.line_code = l.line_code
)
GROUP BY l.line_code, l.mode, l.category
ORDER BY l.category, l.line_code;

-- ============================================================================
-- 4. By fare zone
-- ============================================================================
-- Stops, passages and boardings per zone ('n/a' = the unknown stop)
-- Expectation: Zone 1 has 406,873 passages and 538,492 boardings; passages add up to 471,946, boardings to 578,899
SELECT
    s.fare_zone,
    COUNT(DISTINCT f.stop_key) AS stops_with_passages,
    COUNT(*)                   AS planned_passages,
    SUM(f.boardings)           AS boardings_equipped
FROM gold.fact_trips f
JOIN gold.dim_stops s
    ON s.stop_key = f.stop_key
GROUP BY s.fare_zone
ORDER BY s.fare_zone;

-- ============================================================================
-- 5. By city (46 % of stops have no city: 'n/a')
-- ============================================================================
-- Passages and boardings per city
-- Expectation: most boardings in Lyon 3e (62,930), Lyon 9e (59,016) and Villeurbanne (57,570)
SELECT
    s.city,
    COUNT(DISTINCT f.stop_key) AS stops_with_passages,
    COUNT(*)                   AS planned_passages,
    SUM(f.boardings)           AS boardings_equipped
FROM gold.fact_trips f
JOIN gold.dim_stops s
    ON s.stop_key = f.stop_key
GROUP BY s.city
ORDER BY boardings_equipped DESC;

-- Lines and stops per city, from the routes (fact_line_stops)
-- Expectation: 'n/a' 435 lines, then Lyon 9e with 56
SELECT
    s.city,
    COUNT(DISTINCT l.line_code) AS lines,
    COUNT(DISTINCT s.stop_key)  AS stops
FROM gold.fact_line_stops ls
JOIN gold.dim_stops s
    ON s.stop_key = ls.stop_key
JOIN gold.dim_lines l
    ON l.line_key = ls.line_key
GROUP BY s.city
ORDER BY lines DESC;

-- Distinct counts do not add up: a line crossing 3 cities is counted in each of them
-- Expectation: 1,758 lines summed over cities vs 801 distinct lines
WITH lines_by_city AS (
    SELECT
        s.city,
        COUNT(DISTINCT l.line_code) AS lines
    FROM gold.fact_line_stops ls
    JOIN gold.dim_stops s
        ON s.stop_key = ls.stop_key
    JOIN gold.dim_lines l
        ON l.line_key = ls.line_key
    GROUP BY s.city
)
SELECT
    SUM(lines)                                                  AS sum_of_lines_by_city,
    (SELECT COUNT(DISTINCT line_code) FROM gold.dim_lines)      AS distinct_lines
FROM lines_by_city;

-- ============================================================================
-- 6. Passenger demand by mode (equipped vehicles)
-- ============================================================================
-- Total boardings depend on how many vehicles have a counter: compare boardings per counted passage
-- Expectation: about 25 % counted in every mode except Funicular (0 %) and River shuttle (75 %);
-- boardings per counted passage Metro 28.5, Tram 9.1, Trolleybus 6.0, River shuttle 2.8, Bus 2.2
SELECT
    l.mode,
    COUNT(*)                                                                                 AS operated_passages,
    SUM(CASE WHEN f.boardings IS NOT NULL OR f.alightings IS NOT NULL THEN 1 ELSE 0 END)     AS counted_passages,
    CAST(100.0 * SUM(CASE WHEN f.boardings IS NOT NULL OR f.alightings IS NOT NULL THEN 1 ELSE 0 END)
         / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1))                                             AS counted_pct,
    SUM(f.boardings)                                                                         AS boardings_equipped,
    CAST(SUM(f.boardings) * 1.0 / NULLIF(COUNT(f.boardings), 0) AS DECIMAL(6, 1))            AS boardings_per_counted_passage
FROM gold.fact_trips f
JOIN gold.dim_lines l
    ON l.line_key = f.line_key
WHERE f.status = 'OPERATED'
GROUP BY l.mode
ORDER BY boardings_per_counted_passage DESC;
