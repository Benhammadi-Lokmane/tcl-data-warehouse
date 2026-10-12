/*
===============================================================================
Change Over Time Analysis (by hour of the service day)
===============================================================================
Purpose:
    - Follow passages, delays, cancellations and passenger load over the service day.
    - Compare peak hours with off-peak hours.

Business questions:
    - How do passages, delay, on-time % and late % change hour by hour?
    - How do peak hours compare with off-peak hours?
    - When are the busiest 15 minutes of the day?
    - How does the passenger load change over the day?

SQL Functions Used:
    - DATEDIFF(), DATETRUNC(), DATE_BUCKET(), FORMAT()
    - COUNT(), SUM(), AVG(), MIN(), CASE WHEN, NULLIF(), CAST()

Notes:
    - One service day only: time is analysed by hour, not by day or week.
    - Service hour = DATEDIFF(hour, service day, planned arrival): 0 to 24, where 24 = after midnight.
    - Peak hours: 07:00-08:59 and 16:00-18:59 of the service day; off-peak = every other hour.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Hour by hour
-- ============================================================================
-- Why the service hour: planned_hour puts the passages of both midnights in hour 0,
-- DATETRUNC separates them by calendar date, the service hour numbers them 0 and 24
-- Expectation: 2 rows, both planned_hour 0: 2026-09-08 00:00 = service hour 0 (3,005), 2026-09-09 00:00 = 24 (1,218)
SELECT
    DATETRUNC(hour, f.planned_arrival)                  AS calendar_hour,
    MIN(DATEDIFF(hour, d.full_date, f.planned_arrival)) AS service_hour,
    MIN(f.planned_hour)                                 AS planned_hour,
    COUNT(*)                                            AS planned_passages
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
WHERE f.planned_hour = 0
GROUP BY DATETRUNC(hour, f.planned_arrival)
ORDER BY calendar_hour;

-- Passages, delay and punctuality per service hour (labels formatted after aggregation: FORMAT is slow)
-- Expectation: 23 rows (no hours 2 and 3); operated passages add up to 464,281;
-- worst 18:00 (227.5 s, 40.1 % late) and 08:00 (207.4 s, 37.4 % late)
WITH planned AS (
    SELECT
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour,
        COUNT(*)                                       AS planned_passages
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
), operated AS (
    SELECT
        DATEDIFF(hour, d.full_date, f.planned_arrival)                   AS service_hour,
        COUNT(*)                                                         AS operated_passages,
        AVG(f.delay_s * 1.0)                                             AS avg_delay_s,
        100.0 * SUM(CASE WHEN f.delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END) / COUNT(*) AS on_time_pct,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END)              / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
    GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
)
SELECT
    p.service_hour,
    CONCAT(FORMAT(p.service_hour, '00'), ':00')    AS hour_label,
    p.planned_passages,
    o.operated_passages,
    CAST(o.avg_delay_s AS DECIMAL(6, 1))           AS avg_delay_s,
    CAST(o.on_time_pct AS DECIMAL(5, 1))           AS on_time_pct,
    CAST(o.late_pct AS DECIMAL(5, 1))              AS late_pct
FROM planned p
LEFT JOIN operated o
    ON o.service_hour = p.service_hour
ORDER BY p.service_hour;

-- ============================================================================
-- 2. Peak vs off-peak
-- ============================================================================
-- Delay and punctuality per time band, from the passages (not an average of the hourly averages)
-- Expectation: Morning peak 71,687 passages / 178.2 s / 64.6 % on time; Evening peak 105,288 / 189.7 s / 63.1 %;
-- Off-peak 287,306 / 127.9 s / 73.0 %; passages add up to 464,281
WITH operated AS (
    SELECT
        f.delay_s,
        CASE
            WHEN DATEDIFF(hour, d.full_date, f.planned_arrival) BETWEEN 7 AND 8   THEN 'Morning peak'
            WHEN DATEDIFF(hour, d.full_date, f.planned_arrival) BETWEEN 16 AND 18 THEN 'Evening peak'
            ELSE 'Off-peak'
        END AS time_band
    FROM gold.fact_trips f
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
)
SELECT
    time_band,
    COUNT(*)                                                                                          AS operated_passages,
    CAST(AVG(delay_s * 1.0) AS DECIMAL(6, 1))                                                         AS avg_delay_s,
    CAST(100.0 * SUM(CASE WHEN delay_s BETWEEN -60 AND 180 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5, 1)) AS on_time_pct,
    CAST(100.0 * SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END)              / COUNT(*) AS DECIMAL(5, 1)) AS late_pct
FROM operated
GROUP BY time_band
ORDER BY CASE time_band WHEN 'Morning peak' THEN 1 WHEN 'Evening peak' THEN 2 ELSE 3 END;

-- Cancellation rate per time band: each run counts once, in the band of its first planned passage
-- Expectation: Morning peak 1.19 % (44 / 3,709); Evening peak 1.09 % (58 / 5,310); Off-peak 0.61 % (82 / 13,408);
-- runs add up to 22,427 and cancelled runs to 184
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
            WHEN DATEDIFF(hour, d.full_date, r.run_start) BETWEEN 7 AND 8   THEN 'Morning peak'
            WHEN DATEDIFF(hour, d.full_date, r.run_start) BETWEEN 16 AND 18 THEN 'Evening peak'
            ELSE 'Off-peak'
        END AS time_band
    FROM runs r
    JOIN gold.dim_dates d
        ON d.date_key = r.date_key
)
SELECT
    time_band,
    COUNT(*)                                                              AS runs,
    SUM(is_cancelled)                                                     AS cancelled_runs,
    CAST(100.0 * SUM(is_cancelled) / NULLIF(COUNT(*), 0) AS DECIMAL(5, 2)) AS cancellation_rate_pct
FROM banded
GROUP BY time_band
ORDER BY CASE time_band WHEN 'Morning peak' THEN 1 WHEN 'Evening peak' THEN 2 ELSE 3 END;

-- ============================================================================
-- 3. Busiest 15 minutes
-- ============================================================================
-- Planned passages per 15-minute slot
-- Expectation: 07:30 (9,868), 17:15 (9,862), 07:15 (9,772)
SELECT TOP 5
    FORMAT(DATE_BUCKET(minute, 15, f.planned_arrival), 'HH:mm') AS slot_start,
    COUNT(*)                                                    AS planned_passages
FROM gold.fact_trips f
GROUP BY DATE_BUCKET(minute, 15, f.planned_arrival)
ORDER BY planned_passages DESC;

-- ============================================================================
-- 4. Passenger load over the day (equipped vehicles)
-- ============================================================================
-- Boardings per counted passage per service hour
-- Expectation: highest 08:00 (7.8) and 17:00 (7.3), lowest 01:00 (0.2)
SELECT
    DATEDIFF(hour, d.full_date, f.planned_arrival)                              AS service_hour,
    COUNT(*)                                                                    AS counted_passages,
    SUM(f.boardings)                                                            AS boardings_equipped,
    CAST(SUM(f.boardings) * 1.0 / NULLIF(COUNT(*), 0) AS DECIMAL(5, 1))         AS boardings_per_counted_passage
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
WHERE f.status = 'OPERATED'
  AND f.boardings IS NOT NULL
GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
ORDER BY service_hour;
