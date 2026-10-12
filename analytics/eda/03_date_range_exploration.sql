/*
===============================================================================
Date Range Exploration
===============================================================================
Purpose:
    - Find the period covered by the data and the time span of a service day.
    - Find the age of the fleet and of the current line versions.

Business questions:
    - Which service days are covered?
    - When does a service day start and end, and is there a night pause?
    - How old are the vehicles and the current line versions?

SQL Functions Used:
    - MIN(), MAX(), COUNT(), AVG(), SUM(), CASE WHEN
    - DATEDIFF(), DATEADD(), CAST()

Note:
    - A run after midnight belongs to the service day it started on: dates come from dim_dates.full_date.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Service days
-- ============================================================================
-- First and last service day, days in the period vs days with data
-- Expectation: 2026-09-08 to 2026-09-08, 1 day, 1 day with data
WITH service_days AS (
    SELECT DISTINCT
        date_key
    FROM gold.fact_trips
)
SELECT
    MIN(d.full_date)                                      AS first_service_day,
    MAX(d.full_date)                                      AS last_service_day,
    DATEDIFF(day, MIN(d.full_date), MAX(d.full_date)) + 1 AS days_in_period,
    COUNT(*)                                              AS days_with_data
FROM service_days s
JOIN gold.dim_dates d
    ON d.date_key = s.date_key;

-- Day of the week of each service day
-- Expectation: Tuesday, week 37
SELECT
    d.full_date    AS service_day,
    d.day_name,
    d.week_of_year,
    d.is_weekend,
    COUNT(*)       AS stop_rows
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
GROUP BY d.full_date, d.day_name, d.week_of_year, d.is_weekend
ORDER BY d.full_date;

-- ============================================================================
-- 2. Start and end of the service day
-- ============================================================================
-- First and last planned passage of each service day
-- Expectation: 2026-09-08 00:00:00 to 2026-09-09 00:41:47
SELECT
    d.full_date                                                      AS service_day,
    MIN(f.planned_arrival)                                           AS first_planned_passage,
    MAX(f.planned_arrival)                                           AS last_planned_passage,
    DATEDIFF(minute, MIN(f.planned_arrival), MAX(f.planned_arrival)) AS service_span_minutes
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
GROUP BY d.full_date
ORDER BY d.full_date;

-- Passages planned after midnight (on the next calendar date)
-- Expectation: 1,218 passages on 114 runs
SELECT
    d.full_date              AS service_day,
    COUNT(*)                 AS after_midnight_passages,
    COUNT(DISTINCT f.run_id) AS after_midnight_runs,
    MIN(f.planned_arrival)   AS first_after_midnight,
    MAX(f.planned_arrival)   AS last_after_midnight
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
WHERE CAST(f.planned_arrival AS DATE) > d.full_date
GROUP BY d.full_date
ORDER BY d.full_date;

-- Passages planned before their service day
-- Expectation: No results
SELECT
    d.full_date AS service_day,
    COUNT(*)    AS passages_before_service_day
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
WHERE CAST(f.planned_arrival AS DATE) < d.full_date
GROUP BY d.full_date;

-- ============================================================================
-- 3. Night pause
-- ============================================================================
-- Passages per hour of the service day (24 = after midnight; planned_hour would merge it with hour 0)
-- Expectation: no passages in hours 2 and 3
SELECT
    DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour,
    COUNT(*)                                       AS planned_passages,
    MIN(f.planned_arrival)                         AS first_passage,
    MAX(f.planned_arrival)                         AS last_passage
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
GROUP BY DATEDIFF(hour, d.full_date, f.planned_arrival)
ORDER BY service_hour;

-- ============================================================================
-- 4. Actual vs planned end of service
-- ============================================================================
-- Last actual vs last planned arrival (operated passages)
-- Expectation: 129 seconds after the planned end
SELECT
    d.full_date                                                     AS service_day,
    MIN(f.actual_arrival)                                           AS first_actual_arrival,
    MAX(f.planned_arrival)                                          AS last_planned_arrival,
    MAX(f.actual_arrival)                                           AS last_actual_arrival,
    DATEDIFF(second, MAX(f.planned_arrival), MAX(f.actual_arrival)) AS seconds_after_planned_end
FROM gold.fact_trips f
JOIN gold.dim_dates d
    ON d.date_key = f.date_key
WHERE f.status = 'OPERATED'
GROUP BY d.full_date
ORDER BY d.full_date;

-- ============================================================================
-- 5. Calendar
-- ============================================================================
-- Calendar range vs service days
-- Expectation: 2026-01-01 to 2026-12-31, 1 service day
SELECT
    MIN(full_date)                                         AS calendar_first_day,
    MAX(full_date)                                         AS calendar_last_day,
    COUNT(*)                                               AS calendar_days,
    (SELECT COUNT(DISTINCT date_key) FROM gold.fact_trips) AS service_days
FROM gold.dim_dates;

-- ============================================================================
-- 6. Fleet age (simulated vehicles)
-- ============================================================================
-- Oldest and newest vehicle, age in years at the last service day
-- Expectation: 1978-03-27 (48 years) to 2026-06-26 (0 years)
WITH reference AS (
    SELECT
        full_date AS last_service_day
    FROM gold.dim_dates
    WHERE date_key = (SELECT MAX(date_key) FROM gold.fact_trips)
), vehicle_ages AS (
    SELECT
        v.in_service_date,
        -- DATEDIFF(year) counts year boundaries: subtract 1 before the anniversary
        DATEDIFF(year, v.in_service_date, r.last_service_day)
            - CASE
                  WHEN DATEADD(year, DATEDIFF(year, v.in_service_date, r.last_service_day), v.in_service_date) > r.last_service_day
                  THEN 1
                  ELSE 0
              END AS age_years
    FROM gold.dim_vehicles v
    CROSS JOIN reference r
    WHERE v.vehicle_key <> 0
      AND v.in_service_date IS NOT NULL
)
SELECT
    MIN(in_service_date)                        AS oldest_in_service_date,
    MAX(in_service_date)                        AS newest_in_service_date,
    MAX(age_years)                              AS oldest_age_years,
    MIN(age_years)                              AS newest_age_years,
    CAST(AVG(age_years * 1.0) AS DECIMAL(4, 1)) AS avg_age_years,
    COUNT(*)                                    AS vehicles_with_known_date
FROM vehicle_ages;

-- Vehicles with an unknown or future date of entry into service
-- Expectation: 6 unknown, 0 future
WITH reference AS (
    SELECT
        full_date AS last_service_day
    FROM gold.dim_dates
    WHERE date_key = (SELECT MAX(date_key) FROM gold.fact_trips)
)
SELECT
    SUM(CASE WHEN v.in_service_date IS NULL THEN 1 ELSE 0 END)              AS unknown_in_service_date,
    SUM(CASE WHEN v.in_service_date > r.last_service_day THEN 1 ELSE 0 END) AS entered_after_last_service_day
FROM gold.dim_vehicles v
CROSS JOIN reference r
WHERE v.vehicle_key <> 0;

-- ============================================================================
-- 7. Line versions
-- ============================================================================
-- Oldest and newest current line version
-- Expectation: 2008-01-09 to 2026-09-01
SELECT
    MIN(start_date) AS oldest_line_version,
    MAX(start_date) AS newest_line_version
FROM gold.dim_lines;

-- Line versions from the last 30 days (gold has no earlier version to compare with)
-- Expectation: 2026-09-01, Bus, School: 46 lines (start of the school year)
WITH reference AS (
    SELECT
        full_date AS last_service_day
    FROM gold.dim_dates
    WHERE date_key = (SELECT MAX(date_key) FROM gold.fact_trips)
)
SELECT
    l.start_date,
    l.mode,
    l.category,
    COUNT(DISTINCT l.line_code) AS lines,
    COUNT(*)                    AS line_directions
FROM gold.dim_lines l
CROSS JOIN reference r
WHERE l.start_date > DATEADD(day, -30, r.last_service_day)
GROUP BY l.start_date, l.mode, l.category
ORDER BY l.start_date DESC, lines DESC;
