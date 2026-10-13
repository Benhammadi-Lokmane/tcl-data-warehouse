/*
===============================================================================
Stop Report
===============================================================================
Purpose:
    - Consolidate the key metrics of every stop in one view: location, lines, service, punctuality,
      passengers, busiest hour and demand segment.

Business questions:
    - Where is each stop, is it accessible, and which lines and modes serve it?
    - How many passages were planned and operated there, and how punctual were they?
    - How many passengers boarded and alighted (equipped vehicles), and at which hour is the stop busiest?
    - Which stops have a high, medium or low demand?

Columns (one row per stop = one platform; all 9,774 rows of dim_stops):
    - Stop:          stop_key, stop_id, stop_name, city, fare_zone, wheelchair_accessible, latitude, longitude
    - Lines:         lines_serving, modes_serving
    - Service:       planned_passages, operated_passages, skipped_passages, cancelled_passages
    - Punctuality:   avg_delay_s, median_delay_s, on_time_pct, late_pct
    - Passengers:    counted_passages, boardings_equipped, alightings_equipped, boardings_per_counted_passage
    - Busiest hour:  busiest_service_hour, busiest_hour_passages
    - Segment:       demand_segment

SQL Functions Used:
    - CTE (WITH), CREATE OR ALTER VIEW, LEFT JOIN
    - COUNT(), COUNT(DISTINCT), SUM(), CASE WHEN, COALESCE(), NULLIF(), CAST(), DATEDIFF()
    - PERCENTILE_CONT() OVER (PARTITION BY ...), ROW_NUMBER() OVER (PARTITION BY ...), STRING_AGG()

Notes:
    - stop_key 0 is the unknown stop ('n/a'): it keeps the totals equal to the fact table; filter it out with
      stop_key <> 0 to count real stops.
    - Lines and modes come from the routes (fact_line_stops): the lines planned to stop there.
    - Busiest hour = service hour (0 to 24, 24 = after midnight) with the most planned passages.
    - Demand segment (counted boardings, equipped vehicles): High >= 100, Medium 20-99, Low < 20,
      No count = served but no equipped vehicle counted, Not served = no operated passage.

Usage Example:
    SELECT * FROM analytics.report_stops WHERE demand_segment = 'High' AND wheelchair_accessible = 'false';
===============================================================================
*/
USE TclDataWarehouse;
GO

IF SCHEMA_ID('analytics') IS NULL
    EXEC('CREATE SCHEMA analytics');
GO

CREATE OR ALTER VIEW analytics.report_stops AS
WITH base AS (
    -- 1) Base: one row per passage, with its stop and service hour
    SELECT
        f.stop_key,
        f.status,
        f.delay_s,
        f.boardings,
        f.alightings,
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
), passage_totals AS (
    -- 2a) Aggregation of the passages per stop (delay conditions are only true on operated passages)
    SELECT
        stop_key,
        COUNT(*)                                                             AS planned_passages,
        SUM(CASE WHEN status = 'OPERATED'  THEN 1 ELSE 0 END)                AS operated_passages,
        SUM(CASE WHEN status = 'SKIPPED'   THEN 1 ELSE 0 END)                AS skipped_passages,
        SUM(CASE WHEN status = 'CANCELLED' THEN 1 ELSE 0 END)                AS cancelled_passages,
        SUM(CASE WHEN status = 'OPERATED' THEN CAST(delay_s AS BIGINT) ELSE 0 END) AS delay_sum_s,
        SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END)         AS on_time_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)                       AS late_passages,
        SUM(CASE WHEN boardings IS NOT NULL THEN 1 ELSE 0 END)               AS counted_passages,
        SUM(COALESCE(boardings, 0))                                          AS boardings_sum,
        SUM(COALESCE(alightings, 0))                                         AS alightings_sum
    FROM base
    GROUP BY stop_key
), percentiles AS (
    -- 2b) Median delay per stop (operated passages)
    SELECT DISTINCT
        stop_key,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY delay_s) OVER (PARTITION BY stop_key) AS median_delay_s
    FROM base
    WHERE status = 'OPERATED'
), hourly AS (
    -- 2c) Planned passages per stop and service hour, ranked (ties: the earliest hour)
    SELECT
        stop_key,
        service_hour,
        COUNT(*)                                                                         AS passages,
        ROW_NUMBER() OVER (PARTITION BY stop_key ORDER BY COUNT(*) DESC, service_hour)   AS hour_rank
    FROM base
    GROUP BY stop_key, service_hour
), routes AS (
    -- 2d) Lines planned to stop here (route structure)
    SELECT
        ls.stop_key,
        COUNT(DISTINCT l.line_code) AS lines_serving
    FROM gold.fact_line_stops ls
    JOIN gold.dim_lines l
        ON l.line_key = ls.line_key
    GROUP BY ls.stop_key
), stop_modes AS (
    -- STRING_AGG has no DISTINCT: deduplicate the modes first
    SELECT DISTINCT
        ls.stop_key,
        l.mode
    FROM gold.fact_line_stops ls
    JOIN gold.dim_lines l
        ON l.line_key = ls.line_key
), modes AS (
    SELECT
        stop_key,
        STRING_AGG(mode, ', ') WITHIN GROUP (ORDER BY mode) AS modes_serving
    FROM stop_modes
    GROUP BY stop_key
)
-- 3) Final: every stop of dim_stops; counts are 0 for the stops without passages, averages stay NULL
SELECT
    s.stop_key,
    s.stop_id,
    s.stop_name,
    s.city,
    s.fare_zone,
    s.wheelchair_accessible,
    s.latitude,
    s.longitude,
    COALESCE(r.lines_serving, 0)                                                         AS lines_serving,
    m.modes_serving,
    COALESCE(p.planned_passages, 0)                                                      AS planned_passages,
    COALESCE(p.operated_passages, 0)                                                     AS operated_passages,
    COALESCE(p.skipped_passages, 0)                                                      AS skipped_passages,
    COALESCE(p.cancelled_passages, 0)                                                    AS cancelled_passages,
    CAST(1.0 * p.delay_sum_s / NULLIF(p.operated_passages, 0) AS DECIMAL(8, 1))          AS avg_delay_s,
    CAST(pc.median_delay_s AS DECIMAL(8, 1))                                             AS median_delay_s,
    CAST(100.0 * p.on_time_passages / NULLIF(p.operated_passages, 0) AS DECIMAL(5, 1))   AS on_time_pct,
    CAST(100.0 * p.late_passages / NULLIF(p.operated_passages, 0) AS DECIMAL(5, 1))      AS late_pct,
    COALESCE(p.counted_passages, 0)                                                      AS counted_passages,
    CASE WHEN p.counted_passages > 0 THEN p.boardings_sum END                            AS boardings_equipped,
    CASE WHEN p.counted_passages > 0 THEN p.alightings_sum END                           AS alightings_equipped,
    CAST(1.0 * p.boardings_sum / NULLIF(p.counted_passages, 0) AS DECIMAL(6, 1))         AS boardings_per_counted_passage,
    h.service_hour                                                                       AS busiest_service_hour,
    h.passages                                                                           AS busiest_hour_passages,
    CASE
        WHEN s.stop_key = 0                                THEN 'n/a'
        WHEN COALESCE(p.operated_passages, 0) = 0          THEN 'Not served'
        WHEN p.counted_passages = 0                        THEN 'No count'
        WHEN p.boardings_sum >= 100                        THEN 'High'
        WHEN p.boardings_sum >= 20                         THEN 'Medium'
        ELSE 'Low'
    END                                                                                  AS demand_segment
FROM gold.dim_stops s
LEFT JOIN passage_totals p
    ON p.stop_key = s.stop_key
LEFT JOIN percentiles pc
    ON pc.stop_key = s.stop_key
LEFT JOIN hourly h
    ON h.stop_key = s.stop_key
   AND h.hour_rank = 1
LEFT JOIN routes r
    ON r.stop_key = s.stop_key
LEFT JOIN modes m
    ON m.stop_key = s.stop_key;
GO
