/*
===============================================================================
Part-to-Whole Analysis
===============================================================================
Purpose:
    - Measure the contribution of each mode, line, city and time band to the whole network.
    - Compare a group's share of the service with its share of lateness or cancellations.

Business questions:
    - Which modes produce more lateness than their share of the service?
    - How concentrated is lateness: how many lines make 50 % and 80 % of late passages?
    - What share of counted boardings does each city take?
    - Where do cancellations come from (by mode, category and time band)?

SQL Functions Used:
    - SUM() OVER (), SUM(SUM()) OVER (), SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING)
    - ROW_NUMBER(), COUNT(), SUM(), CASE WHEN, NULLIF(), CAST()

Notes:
    - The warehouse has no cancellation reason: cancellations are split by mode, category and time band instead.
    - Window functions run after WHERE: shares are calculated over every group first, then filtered.
    - Late = delay > 180 s on operated passages; cancellations are counted per run.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. By mode: share of the service vs share of lateness
-- ============================================================================
-- late_index > 1 = the mode makes more lateness than its share of the service
-- Expectation: Bus 78.0 % of passages / 89.0 % of late passages; Tram 9.4 / 6.5; Metro 7.1 / 0; Trolleybus 5.2 / 4.5;
-- 136,896 late passages in total
WITH mode_totals AS (
    SELECT
        l.mode,
        COUNT(*)                                       AS operated_passages,
        SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
    GROUP BY l.mode
), shares AS (
    SELECT
        *,
        100.0 * operated_passages / SUM(operated_passages) OVER () AS passages_pct,
        100.0 * late_passages / SUM(late_passages) OVER ()         AS late_passages_pct
    FROM mode_totals
)
SELECT
    mode,
    operated_passages,
    CAST(passages_pct AS DECIMAL(5, 1))                                 AS passages_pct,
    late_passages,
    CAST(late_passages_pct AS DECIMAL(5, 1))                            AS late_passages_pct,
    CAST(late_passages_pct / NULLIF(passages_pct, 0) AS DECIMAL(4, 2))  AS late_index
FROM shares
ORDER BY operated_passages DESC;

-- ============================================================================
-- 2. By line: concentration of lateness (Pareto)
-- ============================================================================
-- Each line's share of late passages and the running share (lines sorted from most to least late passages)
-- Expectation: C5 4.0 % (running 4.0 %), C25 2.1 %, T2 2.0 %...; top 10 = 19.9 %
WITH line_late AS (
    SELECT
        l.line_code,
        l.mode,
        SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
    GROUP BY l.line_code, l.mode
), pareto AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY late_passages DESC, line_code)                        AS line_rank,
        100.0 * late_passages / SUM(late_passages) OVER ()                                 AS late_pct,
        -- line_code breaks ties so the running total is the same on every run
        100.0 * SUM(late_passages) OVER (ORDER BY late_passages DESC, line_code ROWS UNBOUNDED PRECEDING)
              / SUM(late_passages) OVER ()                                                 AS running_late_pct
    FROM line_late
)
SELECT
    line_rank,
    line_code,
    mode,
    late_passages,
    CAST(late_pct AS DECIMAL(5, 1))         AS late_pct,
    CAST(running_late_pct AS DECIMAL(5, 1)) AS running_late_pct
FROM pareto
WHERE line_rank <= 20
ORDER BY line_rank;

-- Number of lines that make 50 % and 80 % of late passages
-- Expectation: 36 lines for 50 %, 83 lines for 80 %; 774 lines ran, 615 had at least one late passage
WITH line_late AS (
    SELECT
        l.line_code,
        SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
    GROUP BY l.line_code
), pareto AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY late_passages DESC, line_code) AS line_rank,
        100.0 * SUM(late_passages) OVER (ORDER BY late_passages DESC, line_code ROWS UNBOUNDED PRECEDING)
              / SUM(late_passages) OVER ()                         AS running_late_pct
    FROM line_late
)
SELECT
    (SELECT TOP 1 line_rank FROM pareto WHERE running_late_pct >= 50 ORDER BY line_rank) AS lines_for_50_pct,
    (SELECT TOP 1 line_rank FROM pareto WHERE running_late_pct >= 80 ORDER BY line_rank) AS lines_for_80_pct,
    (SELECT COUNT(*) FROM pareto)                                                         AS lines_run,
    (SELECT COUNT(*) FROM pareto WHERE late_passages > 0)                                 AS lines_with_late_passages;

-- ============================================================================
-- 3. By city: share of counted boardings (equipped vehicles)
-- ============================================================================
-- Shares over every city, 'n/a' included (the unknown stop has city 'n/a' too)
-- Expectation: Lyon 3e 10.9 %, Lyon 9e 10.2 %, Villeurbanne 9.9 %; shares add up to 100 %
WITH city_totals AS (
    SELECT
        s.city,
        COUNT(*)         AS operated_passages,
        SUM(f.boardings) AS boardings_equipped
    FROM gold.fact_trips f
    JOIN gold.dim_stops s
        ON s.stop_key = f.stop_key
    WHERE f.status = 'OPERATED'
    GROUP BY s.city
)
SELECT
    city,
    boardings_equipped,
    CAST(100.0 * boardings_equipped / SUM(boardings_equipped) OVER () AS DECIMAL(5, 1)) AS boardings_pct,
    CAST(100.0 * operated_passages / SUM(operated_passages) OVER () AS DECIMAL(5, 1))   AS passages_pct
FROM city_totals
ORDER BY boardings_equipped DESC;

-- Share of the 'n/a' city: calculated over every city first, filtered after
-- (WHERE city = 'n/a' inside the same query would make the window see only that row: 100 %)
-- Expectation: 4.7 % of counted boardings (27,475) and 8.2 % of passages, although 46 % of stops have no city
WITH city_totals AS (
    SELECT
        s.city,
        COUNT(*)         AS operated_passages,
        SUM(f.boardings) AS boardings_equipped
    FROM gold.fact_trips f
    JOIN gold.dim_stops s
        ON s.stop_key = f.stop_key
    WHERE f.status = 'OPERATED'
    GROUP BY s.city
), shares AS (
    SELECT
        *,
        100.0 * boardings_equipped / SUM(boardings_equipped) OVER () AS boardings_pct,
        100.0 * operated_passages / SUM(operated_passages) OVER ()   AS passages_pct
    FROM city_totals
)
SELECT
    city,
    boardings_equipped,
    CAST(boardings_pct AS DECIMAL(5, 1)) AS boardings_pct,
    CAST(passages_pct AS DECIMAL(5, 1))  AS passages_pct
FROM shares
WHERE city = 'n/a';

-- Shares among known cities only (here the filter is meant to change the denominator)
-- Expectation: Lyon 3e 11.4 %, Lyon 9e 10.7 %, Villeurbanne 10.4 %
SELECT
    s.city,
    SUM(f.boardings)                                                                       AS boardings_equipped,
    CAST(100.0 * SUM(f.boardings) / SUM(SUM(f.boardings)) OVER () AS DECIMAL(5, 1))        AS boardings_pct_known_cities
FROM gold.fact_trips f
JOIN gold.dim_stops s
    ON s.stop_key = f.stop_key
WHERE f.status = 'OPERATED'
  AND s.city <> 'n/a'
GROUP BY s.city
ORDER BY boardings_equipped DESC;

-- ============================================================================
-- 4. Cancellations: share of runs vs share of cancelled runs
-- ============================================================================
-- By mode
-- Expectation: Bus 71.5 % of runs / 85.3 % of cancelled runs (157 of 184); Metro 11.9 % / 2.2 %
WITH runs AS (
    SELECT
        f.run_id,
        f.date_key,
        l.mode,
        MIN(CASE WHEN f.status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    GROUP BY f.run_id, f.date_key, l.mode
)
SELECT
    mode,
    COUNT(*)                                                                   AS runs,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1))            AS runs_pct,
    SUM(is_cancelled)                                                          AS cancelled_runs,
    CAST(100.0 * SUM(is_cancelled) / SUM(SUM(is_cancelled)) OVER () AS DECIMAL(5, 1)) AS cancelled_runs_pct
FROM runs
GROUP BY mode
ORDER BY runs DESC;

-- By line category
-- Expectation: Regular 92.7 % of runs / 90.8 % of cancelled runs; School 7.0 % / 9.2 %
WITH runs AS (
    SELECT
        f.run_id,
        f.date_key,
        l.category,
        MIN(CASE WHEN f.status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    GROUP BY f.run_id, f.date_key, l.category
)
SELECT
    category,
    COUNT(*)                                                                   AS runs,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1))            AS runs_pct,
    SUM(is_cancelled)                                                          AS cancelled_runs,
    CAST(100.0 * SUM(is_cancelled) / SUM(SUM(is_cancelled)) OVER () AS DECIMAL(5, 1)) AS cancelled_runs_pct
FROM runs
GROUP BY category
ORDER BY runs DESC;

-- By time band (each run in the band of its first planned passage)
-- Expectation: Morning peak 16.5 % of runs / 23.9 % of cancelled runs; Evening peak 23.7 % / 31.5 %;
-- Off-peak 59.8 % / 44.6 %
WITH runs AS (
    SELECT
        f.run_id,
        f.date_key,
        MIN(f.planned_arrival)                                  AS run_start,
        MIN(CASE WHEN f.status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled
    FROM gold.fact_trips f
    GROUP BY f.run_id, f.date_key
), banded AS (
    SELECT
        r.is_cancelled,
        CASE
            WHEN DATEDIFF(hour, d.full_date, r.run_start) BETWEEN 7 AND 8   THEN 1
            WHEN DATEDIFF(hour, d.full_date, r.run_start) BETWEEN 16 AND 18 THEN 2
            ELSE 3
        END AS band_order
    FROM runs r
    JOIN gold.dim_dates d
        ON d.date_key = r.date_key
)
SELECT
    CHOOSE(band_order, 'Morning peak', 'Evening peak', 'Off-peak')            AS time_band,
    COUNT(*)                                                                   AS runs,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1))            AS runs_pct,
    SUM(is_cancelled)                                                          AS cancelled_runs,
    CAST(100.0 * SUM(is_cancelled) / SUM(SUM(is_cancelled)) OVER () AS DECIMAL(5, 1)) AS cancelled_runs_pct
FROM banded
GROUP BY band_order
ORDER BY band_order;

-- ============================================================================
-- 5. Peak vs off-peak: share of passages vs share of late passages
-- ============================================================================
-- Expectation: Peak 38.1 % of passages / 45.3 % of late passages; Off-peak 61.9 % / 54.7 %
WITH banded AS (
    SELECT
        f.delay_s,
        CASE
            WHEN DATEDIFF(hour, d.full_date, f.planned_arrival) BETWEEN 7 AND 8
              OR DATEDIFF(hour, d.full_date, f.planned_arrival) BETWEEN 16 AND 18 THEN 1
            ELSE 2
        END AS band_order
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
)
SELECT
    CHOOSE(band_order, 'Peak', 'Off-peak')                                                            AS time_band,
    COUNT(*)                                                                                          AS operated_passages,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1))                                   AS passages_pct,
    SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)                                                    AS late_passages,
    CAST(100.0 * SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)
         / SUM(SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)) OVER () AS DECIMAL(5, 1))             AS late_passages_pct
FROM banded
GROUP BY band_order
ORDER BY band_order;
