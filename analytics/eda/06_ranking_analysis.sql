/*
===============================================================================
Ranking Analysis
===============================================================================
Purpose:
    - Rank lines, stations and cities by punctuality, demand, service and cancellations.
    - Compare TOP with the ranking window functions, and how each one handles ties.

Business questions:
    - Which Regular lines are the most late and the most punctual (overall and within each mode)?
    - Which stations are the busiest, and which cities get the most service?
    - Which lines have the highest cancellation rate?

SQL Functions Used:
    - TOP, TOP WITH TIES, ORDER BY
    - RANK(), DENSE_RANK(), ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)
    - COUNT(), COUNT(DISTINCT), SUM(), CASE WHEN, CONCAT(), NULLIF(), CAST()

Notes:
    - Lines are ranked on Regular lines with at least 20 runs (163 lines): tiny lines would top every ranking.
    - Ranks use the exact percentage; the rounded one is only displayed.
    - On ties: RANK 1, 1, 3 (skips) / DENSE_RANK 1, 1, 2 (no gap) / ROW_NUMBER 1, 2, 3 (unique, needs a tie-breaker).
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Most late lines
-- ============================================================================
-- Top 10 with TOP
-- Expectation: 80 (55.1 %), 217 (54.6 %), 77 (51.2 %)...: 10 bus lines
WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key))                    AS runs,  -- run = (run_id, date_key)
        COUNT(*)                                                             AS operated_passages,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
)
SELECT TOP 10
    line_code,
    mode,
    runs,
    CAST(late_pct AS DECIMAL(5, 1)) AS late_pct
FROM line_punctuality
ORDER BY late_pct DESC;

-- Same top 10 with RANK (a window function cannot be filtered in WHERE: rank in a CTE, filter outside)
-- Expectation: same 10 lines, ranks 1 to 10
WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key))                    AS runs,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
), ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY late_pct DESC) AS late_rank
    FROM line_punctuality
)
SELECT
    late_rank,
    line_code,
    mode,
    runs,
    CAST(late_pct AS DECIMAL(5, 1)) AS late_pct
FROM ranked
WHERE late_rank <= 10
ORDER BY late_rank;

-- ============================================================================
-- 2. Most punctual lines (ties)
-- ============================================================================
-- TOP 5 cuts a 7-way tie at 0 % late at random; TOP 5 WITH TIES keeps every tied line
-- Expectation: 5 rows, then 7 rows (metro A-D, funicular F1-F2, river shuttle NAVI1)
WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
)
SELECT TOP 5
    line_code,
    mode,
    CAST(late_pct AS DECIMAL(5, 1)) AS late_pct
FROM line_punctuality
ORDER BY late_pct;

WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
)
SELECT TOP 5 WITH TIES
    line_code,
    mode,
    CAST(late_pct AS DECIMAL(5, 1)) AS late_pct
FROM line_punctuality
ORDER BY late_pct;

-- RANK vs DENSE_RANK vs ROW_NUMBER on the same order
-- Expectation: the 7 tied lines get RANK 1 / DENSE_RANK 1 / ROW_NUMBER 1 to 7;
-- the next line (T7, 8.1 %) gets RANK 8 / DENSE_RANK 2 / ROW_NUMBER 8
WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
), ranked AS (
    SELECT
        *,
        RANK()       OVER (ORDER BY late_pct)            AS rank_position,
        DENSE_RANK() OVER (ORDER BY late_pct)            AS dense_rank_position,
        ROW_NUMBER() OVER (ORDER BY late_pct, line_code) AS row_number_position  -- line_code breaks the ties
    FROM line_punctuality
)
SELECT
    line_code,
    mode,
    CAST(late_pct AS DECIMAL(5, 1)) AS late_pct,
    rank_position,
    dense_rank_position,
    row_number_position
FROM ranked
WHERE row_number_position <= 10
ORDER BY row_number_position;

-- ============================================================================
-- 3. Most late lines within each mode
-- ============================================================================
-- Top 3 per mode with PARTITION BY (modes are not compared with each other)
-- Expectation: Bus 80 / 217 / 77; Tram T2 / T4 / T1; Trolleybus C14 / C13 / C2;
-- every metro and funicular line tied at rank 1 (0 % late)
WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key))                    AS runs,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
), ranked AS (
    SELECT
        *,
        RANK() OVER (PARTITION BY mode ORDER BY late_pct DESC) AS late_rank_in_mode
    FROM line_punctuality
)
SELECT
    mode,
    late_rank_in_mode,
    line_code,
    runs,
    CAST(late_pct AS DECIMAL(5, 1)) AS late_pct
FROM ranked
WHERE late_rank_in_mode <= 3
ORDER BY mode, late_rank_in_mode, line_code;

-- ============================================================================
-- 4. Busiest stations (counted boardings, equipped vehicles)
-- ============================================================================
-- A station = all the platforms (stops) with the same name
-- Expectation: Gorge de Loup 16,262 (21 platforms), Saxe - Gambetta 16,255, Gare de Vaise-G.Collomb 15,609
SELECT TOP 10
    s.stop_name,
    COUNT(DISTINCT s.stop_key) AS platforms,
    COUNT(*)                   AS operated_passages,
    SUM(f.boardings)           AS boardings_equipped
FROM gold.fact_trips f
JOIN gold.dim_stops s
    ON s.stop_key = f.stop_key
WHERE f.status = 'OPERATED'
  AND f.stop_key <> 0
GROUP BY s.stop_name
ORDER BY boardings_equipped DESC;

-- Same ranking with DENSE_RANK
-- Expectation: same 10 stations, ranks 1 to 10
WITH stations AS (
    SELECT
        s.stop_name,
        COUNT(DISTINCT s.stop_key) AS platforms,
        SUM(f.boardings)           AS boardings_equipped
    FROM gold.fact_trips f
    JOIN gold.dim_stops s
        ON s.stop_key = f.stop_key
    WHERE f.status = 'OPERATED'
      AND f.stop_key <> 0
    GROUP BY s.stop_name
), ranked AS (
    SELECT
        *,
        DENSE_RANK() OVER (ORDER BY boardings_equipped DESC) AS boardings_rank
    FROM stations
)
SELECT
    boardings_rank,
    stop_name,
    platforms,
    boardings_equipped
FROM ranked
WHERE boardings_rank <= 10
ORDER BY boardings_rank;

-- ============================================================================
-- 5. Cities with the most service
-- ============================================================================
-- Operated passages per city ('n/a' excluded from the ranking: it is not a city)
-- Expectation: Villeurbanne 33,619, Lyon 3e 28,905, Lyon 9e 25,910
WITH cities AS (
    SELECT
        s.city,
        COUNT(*)                                          AS operated_passages,
        COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) AS runs
    FROM gold.fact_trips f
    JOIN gold.dim_stops s
        ON s.stop_key = f.stop_key
    WHERE f.status = 'OPERATED'
      AND s.city <> 'n/a'
    GROUP BY s.city
), ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY operated_passages DESC) AS service_rank
    FROM cities
)
SELECT
    service_rank,
    city,
    operated_passages,
    runs
FROM ranked
WHERE service_rank <= 10
ORDER BY service_rank;

-- ============================================================================
-- 6. Highest cancellation rate
-- ============================================================================
-- Without a minimum volume: lines with 2 runs and 1 cancellation (50 %) take the top
-- Expectation: 5 school lines at 50 %
WITH runs AS (
    SELECT
        f.run_id,
        f.date_key,
        l.line_code,
        MIN(CASE WHEN f.status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    GROUP BY f.run_id, f.date_key, l.line_code
)
SELECT TOP 5
    line_code,
    COUNT(*)                                                              AS runs,
    SUM(is_cancelled)                                                     AS cancelled_runs,
    CAST(100.0 * SUM(is_cancelled) / NULLIF(COUNT(*), 0) AS DECIMAL(5, 2)) AS cancellation_rate_pct
FROM runs
GROUP BY line_code
ORDER BY cancellation_rate_pct DESC, runs DESC;

-- With at least 20 runs
-- Expectation: 80 (5.56 %, 5 of 90), 130 (5.00 %, 1 of 20), 138 (3.92 %), 115 (3.59 %), 144 (3.57 %)
WITH runs AS (
    SELECT
        f.run_id,
        f.date_key,
        l.line_code,
        l.mode,
        l.category,
        MIN(CASE WHEN f.status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    GROUP BY f.run_id, f.date_key, l.line_code, l.mode, l.category
), line_cancellations AS (
    SELECT
        line_code,
        mode,
        category,
        COUNT(*)                                 AS runs,
        SUM(is_cancelled)                        AS cancelled_runs,
        100.0 * SUM(is_cancelled) / COUNT(*)     AS cancellation_rate_pct
    FROM runs
    GROUP BY line_code, mode, category
    HAVING COUNT(*) >= 20
), ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY cancellation_rate_pct DESC) AS cancellation_rank
    FROM line_cancellations
)
SELECT
    cancellation_rank,
    line_code,
    mode,
    category,
    runs,
    cancelled_runs,
    CAST(cancellation_rate_pct AS DECIMAL(5, 2)) AS cancellation_rate_pct
FROM ranked
WHERE cancellation_rank <= 5
ORDER BY cancellation_rank;
