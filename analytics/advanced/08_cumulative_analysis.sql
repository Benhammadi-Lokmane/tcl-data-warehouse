/*
===============================================================================
Cumulative Analysis (over the hours of the service day)
===============================================================================
Purpose:
    - Follow how passages and passengers build up over the service day (running totals).
    - Smooth the hourly delay with a 3-hour moving average.

Business questions:
    - By which hour is half of the day's service done, and half of its passengers carried?
    - When is the delay trend at its highest once hour-to-hour noise is smoothed?

SQL Functions Used:
    - SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING), SUM() OVER ()
    - AVG() / SUM() OVER (ORDER BY ... ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
    - GENERATE_SERIES(), DATEDIFF(), COALESCE(), NULLIF(), CAST()

Notes:
    - Rows are aggregated per service hour first, then the window functions run on those 25 rows.
    - GENERATE_SERIES(0, 24) gives a complete hour axis: ROWS frames count rows, not hours,
      so the missing hours 2 and 3 would otherwise stretch the moving window.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Running totals
-- ============================================================================
-- Running planned passages and counted boardings (equipped vehicles), and share of the day reached
-- Expectation: 25 rows; ends at 471,946 passages and 578,899 boardings (100 %)
WITH hours AS (
    SELECT
        value AS service_hour
    FROM GENERATE_SERIES(0, 24)
), hourly AS (
    SELECT
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour,
        COUNT(*)                                       AS planned_passages,
        SUM(COALESCE(f.boardings, 0))                  AS boardings_equipped
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
), complete AS (
    SELECT
        h.service_hour,
        COALESCE(x.planned_passages, 0)   AS planned_passages,
        COALESCE(x.boardings_equipped, 0) AS boardings_equipped
    FROM hours h
    LEFT JOIN hourly x
        ON x.service_hour = h.service_hour
)
SELECT
    service_hour,
    planned_passages,
    SUM(planned_passages) OVER (ORDER BY service_hour ROWS UNBOUNDED PRECEDING)          AS running_passages,
    CAST(100.0 * SUM(planned_passages) OVER (ORDER BY service_hour ROWS UNBOUNDED PRECEDING)
         / SUM(planned_passages) OVER () AS DECIMAL(5, 1))                              AS running_passages_pct,
    boardings_equipped,
    SUM(boardings_equipped) OVER (ORDER BY service_hour ROWS UNBOUNDED PRECEDING)        AS running_boardings,
    CAST(100.0 * SUM(boardings_equipped) OVER (ORDER BY service_hour ROWS UNBOUNDED PRECEDING)
         / SUM(boardings_equipped) OVER () AS DECIMAL(5, 1))                            AS running_boardings_pct
FROM complete
ORDER BY service_hour;

-- Hour during which half of the day is reached
-- Expectation: 13 for passages, 14 for boardings
WITH hourly AS (
    SELECT
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour,
        COUNT(*)                                       AS planned_passages,
        SUM(COALESCE(f.boardings, 0))                  AS boardings_equipped
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
), cumulative AS (
    SELECT
        service_hour,
        100.0 * SUM(planned_passages) OVER (ORDER BY service_hour ROWS UNBOUNDED PRECEDING)
              / SUM(planned_passages) OVER ()   AS running_passages_pct,
        100.0 * SUM(boardings_equipped) OVER (ORDER BY service_hour ROWS UNBOUNDED PRECEDING)
              / SUM(boardings_equipped) OVER () AS running_boardings_pct
    FROM hourly
)
SELECT
    (SELECT TOP 1 service_hour FROM cumulative WHERE running_passages_pct >= 50 ORDER BY service_hour)  AS half_of_passages_hour,
    (SELECT TOP 1 service_hour FROM cumulative WHERE running_boardings_pct >= 50 ORDER BY service_hour) AS half_of_boardings_hour;

-- ============================================================================
-- 2. 3-hour moving average of delay
-- ============================================================================
-- Simple (average of the hourly averages) vs weighted (sums over the window): the weighted one is right,
-- an 846-passage hour must not count as much as a 37,827-passage hour
-- Expectation: 25 rows; weighted highest at 19 (197.0 s); at 7: 109.2 s simple vs 124.1 s weighted;
-- delay NULL at hours 2 and 3 (no service is not zero delay)
WITH hours AS (
    SELECT
        value AS service_hour
    FROM GENERATE_SERIES(0, 24)
), hourly AS (
    SELECT
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour,
        COUNT(*)                                       AS operated_passages,
        SUM(f.delay_s * 1.0)                           AS delay_sum_s
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
    GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
), complete AS (
    SELECT
        h.service_hour,
        COALESCE(x.operated_passages, 0)                       AS operated_passages,
        COALESCE(x.delay_sum_s, 0)                             AS delay_sum_s,
        x.delay_sum_s / NULLIF(x.operated_passages, 0)         AS avg_delay_s
    FROM hours h
    LEFT JOIN hourly x
        ON x.service_hour = h.service_hour
)
SELECT
    service_hour,
    operated_passages,
    CAST(avg_delay_s AS DECIMAL(6, 1))                                                       AS avg_delay_s,
    CAST(AVG(avg_delay_s) OVER (ORDER BY service_hour ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
         AS DECIMAL(6, 1))                                                                   AS moving_avg_3h_simple,
    CAST(SUM(delay_sum_s) OVER (ORDER BY service_hour ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
         / NULLIF(SUM(operated_passages) OVER (ORDER BY service_hour ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)
         AS DECIMAL(6, 1))                                                                   AS moving_avg_3h_weighted
FROM complete
ORDER BY service_hour;
