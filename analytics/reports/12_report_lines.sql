/*
===============================================================================
Line Report
===============================================================================
Purpose:
    - Consolidate the key metrics of every line in one view: volume, punctuality, peak penalty,
      passengers and segments, with the business definitions already applied.

Business questions:
    - How many runs and passages did each line plan and operate, and how many were cancelled?
    - How punctual is each line (average, median and 95th percentile delay, on-time and late %)?
    - How much worse is each line at peak hours?
    - Which lines are in difficulty, and which are a priority?

Columns (one row per line, both directions together; all 801 lines, 0 runs for the lines that did not run):
    - Line:          line_code, line_name, mode, category, directions
    - Volume:        planned_runs, operated_runs, cancelled_runs, cancellation_rate_pct,
                     planned_passages, operated_passages, skipped_passages
    - Punctuality:   avg_delay_s, median_delay_s, p95_delay_s, on_time_pct, late_pct, early_pct
    - Peak:          peak_late_pct, off_peak_late_pct, peak_penalty_pts
    - Passengers:    counted_passages, boardings_equipped, alightings_equipped, boardings_per_counted_passage
    - Period:        first_service_date, last_service_date, service_days
    - Segments:      is_rated, punctuality_segment, is_in_difficulty, is_priority

SQL Functions Used:
    - CTE (WITH), CREATE OR ALTER VIEW, LEFT JOIN
    - COUNT(), COUNT(DISTINCT), SUM(), MIN(), MAX(), CASE WHEN, COALESCE(), NULLIF(), CAST()
    - PERCENTILE_CONT() OVER (PARTITION BY ...)

Notes:
    - Delay measures use operated passages; on time = -60 to +180 s, late > 180 s, early < -60 s.
    - A run is cancelled when all its passages are cancelled. Peak = 07:00-08:59 and 16:00-18:59 (service hours).
    - Passenger measures cover equipped vehicles only: NULL when no passage of the line was counted.
    - Only Regular lines with at least 20 operated runs are rated (163 lines); the others are 'Not rated'.
      Priority = In difficulty and at least the median volume of the rated lines.

Usage Example:
    SELECT * FROM analytics.report_lines WHERE is_priority = 1 ORDER BY late_pct DESC;
===============================================================================
*/
USE TclDataWarehouse;
GO

-- The analytics schema is created by init_database.sql; this creates it in a database initialised before it
-- existed (CREATE SCHEMA must be alone in its batch, hence EXEC)
IF SCHEMA_ID('analytics') IS NULL
    EXEC('CREATE SCHEMA analytics');
GO

CREATE OR ALTER VIEW analytics.report_lines AS
WITH base AS (
    -- 1) Base: one row per passage, with its line, service day and peak flag
    SELECT
        l.line_code,
        f.run_id,
        f.date_key,
        d.full_date AS service_date,
        f.status,
        f.delay_s,
        f.boardings,
        f.alightings,
        CASE
            WHEN DATEDIFF(hour, d.full_date, f.planned_arrival) BETWEEN 7 AND 8
              OR DATEDIFF(hour, d.full_date, f.planned_arrival) BETWEEN 16 AND 18 THEN 1
            ELSE 0
        END AS is_peak
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
), runs AS (
    -- 2) Runs: one row per run (cancelled = all passages cancelled; operated = at least one passage operated)
    SELECT
        line_code,
        run_id,
        date_key,
        MIN(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END) AS is_cancelled,
        MAX(CASE WHEN status = 'OPERATED'  THEN 1 ELSE 0 END) AS is_operated
    FROM base
    GROUP BY line_code, run_id, date_key
), run_totals AS (
    -- 3a) Aggregation of the runs per line
    SELECT
        line_code,
        COUNT(*)          AS planned_runs,
        SUM(is_operated)  AS operated_runs,
        SUM(is_cancelled) AS cancelled_runs
    FROM runs
    GROUP BY line_code
), passage_totals AS (
    -- 3b) Aggregation of the passages per line (delay conditions are only true on operated passages)
    SELECT
        line_code,
        COUNT(*)                                                             AS planned_passages,
        SUM(CASE WHEN status = 'OPERATED' THEN 1 ELSE 0 END)                 AS operated_passages,
        SUM(CASE WHEN status = 'SKIPPED'  THEN 1 ELSE 0 END)                 AS skipped_passages,
        SUM(CASE WHEN status = 'OPERATED' THEN CAST(delay_s AS BIGINT) ELSE 0 END) AS delay_sum_s,
        SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END)         AS on_time_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)                       AS late_passages,
        SUM(CASE WHEN delay_s < -60 THEN 1 ELSE 0 END)                       AS early_passages,
        SUM(CASE WHEN status = 'OPERATED' AND is_peak = 1 THEN 1 ELSE 0 END) AS peak_passages,
        SUM(CASE WHEN delay_s > 180 AND is_peak = 1 THEN 1 ELSE 0 END)       AS peak_late_passages,
        SUM(CASE WHEN status = 'OPERATED' AND is_peak = 0 THEN 1 ELSE 0 END) AS off_peak_passages,
        SUM(CASE WHEN delay_s > 180 AND is_peak = 0 THEN 1 ELSE 0 END)       AS off_peak_late_passages,
        SUM(CASE WHEN boardings IS NOT NULL THEN 1 ELSE 0 END)               AS counted_passages,
        SUM(COALESCE(boardings, 0))                                          AS boardings_sum,
        SUM(COALESCE(alightings, 0))                                         AS alightings_sum,
        MIN(service_date)                                                    AS first_service_date,
        MAX(service_date)                                                    AS last_service_date,
        COUNT(DISTINCT date_key)                                             AS service_days
    FROM base
    GROUP BY line_code
), percentiles AS (
    -- 3c) Median and 95th percentile of the delay per line (operated passages)
    SELECT DISTINCT
        line_code,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY delay_s) OVER (PARTITION BY line_code) AS median_delay_s,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY delay_s) OVER (PARTITION BY line_code) AS p95_delay_s
    FROM base
    WHERE status = 'OPERATED'
), lines AS (
    -- Every line of the network (both directions together), including the lines that did not run
    SELECT
        line_code,
        MIN(line_name) AS line_name,
        MIN(mode)      AS mode,       -- one mode and one category per line code (checked)
        MIN(category)  AS category,
        COUNT(*)       AS directions
    FROM gold.dim_lines
    GROUP BY line_code
), line_metrics AS (
    -- 4a) Join everything per line; counts are 0 for the lines that did not run, averages stay NULL
    SELECT
        dl.line_code,
        dl.line_name,
        dl.mode,
        dl.category,
        dl.directions,
        COALESCE(r.planned_runs, 0)       AS planned_runs,
        COALESCE(r.operated_runs, 0)      AS operated_runs,
        COALESCE(r.cancelled_runs, 0)     AS cancelled_runs,
        COALESCE(p.planned_passages, 0)   AS planned_passages,
        COALESCE(p.operated_passages, 0)  AS operated_passages,
        COALESCE(p.skipped_passages, 0)   AS skipped_passages,
        p.delay_sum_s,
        p.on_time_passages,
        p.late_passages,
        p.early_passages,
        p.peak_passages,
        p.peak_late_passages,
        p.off_peak_passages,
        p.off_peak_late_passages,
        COALESCE(p.counted_passages, 0)   AS counted_passages,
        p.boardings_sum,
        p.alightings_sum,
        p.first_service_date,
        p.last_service_date,
        COALESCE(p.service_days, 0)       AS service_days,
        pc.median_delay_s,
        pc.p95_delay_s,
        100.0 * p.late_passages / NULLIF(p.operated_passages, 0) AS late_pct_exact,
        CASE WHEN dl.category = 'Regular' AND COALESCE(r.operated_runs, 0) >= 20 THEN 1 ELSE 0 END AS is_rated
    FROM lines dl
    LEFT JOIN run_totals r
        ON r.line_code = dl.line_code
    LEFT JOIN passage_totals p
        ON p.line_code = dl.line_code
    LEFT JOIN percentiles pc
        ON pc.line_code = dl.line_code
), rated AS (
    -- 4b) Median volume of the rated lines, for the Priority flag
    SELECT
        *,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY operated_passages) OVER (PARTITION BY is_rated) AS rated_median_passages
    FROM line_metrics
)
-- 4c) Final KPIs and segments
SELECT
    line_code,
    line_name,
    mode,
    category,
    directions,
    planned_runs,
    operated_runs,
    cancelled_runs,
    CAST(100.0 * cancelled_runs / NULLIF(planned_runs, 0) AS DECIMAL(5, 2))                    AS cancellation_rate_pct,
    planned_passages,
    operated_passages,
    skipped_passages,
    CAST(1.0 * delay_sum_s / NULLIF(operated_passages, 0) AS DECIMAL(8, 1))                    AS avg_delay_s,
    CAST(median_delay_s AS DECIMAL(8, 1))                                                      AS median_delay_s,
    CAST(p95_delay_s AS DECIMAL(8, 1))                                                         AS p95_delay_s,
    CAST(100.0 * on_time_passages / NULLIF(operated_passages, 0) AS DECIMAL(5, 1))             AS on_time_pct,
    CAST(late_pct_exact AS DECIMAL(5, 1))                                                      AS late_pct,
    CAST(100.0 * early_passages / NULLIF(operated_passages, 0) AS DECIMAL(5, 1))               AS early_pct,
    CAST(100.0 * peak_late_passages / NULLIF(peak_passages, 0) AS DECIMAL(5, 1))               AS peak_late_pct,
    CAST(100.0 * off_peak_late_passages / NULLIF(off_peak_passages, 0) AS DECIMAL(5, 1))       AS off_peak_late_pct,
    CAST(100.0 * peak_late_passages / NULLIF(peak_passages, 0)
         - 100.0 * off_peak_late_passages / NULLIF(off_peak_passages, 0) AS DECIMAL(5, 1))     AS peak_penalty_pts,
    counted_passages,
    CASE WHEN counted_passages > 0 THEN boardings_sum END                                      AS boardings_equipped,
    CASE WHEN counted_passages > 0 THEN alightings_sum END                                     AS alightings_equipped,
    CAST(1.0 * boardings_sum / NULLIF(counted_passages, 0) AS DECIMAL(6, 1))                   AS boardings_per_counted_passage,
    first_service_date,
    last_service_date,
    service_days,
    is_rated,
    CASE
        WHEN is_rated = 0          THEN 'Not rated'
        WHEN late_pct_exact <= 10  THEN 'Good'
        WHEN late_pct_exact <= 20  THEN 'Watch'
        ELSE 'In difficulty'
    END                                                                                        AS punctuality_segment,
    CASE WHEN is_rated = 1 AND late_pct_exact > 20 THEN 1 ELSE 0 END                           AS is_in_difficulty,
    CASE WHEN is_rated = 1 AND late_pct_exact > 20 AND operated_passages >= rated_median_passages
         THEN 1 ELSE 0 END                                                                     AS is_priority
FROM rated;
GO
