/*
===============================================================================
Performance Analysis (each line vs itself, peak vs off-peak)
===============================================================================
Purpose:
    - Compare each line's punctuality in each time band with its own average for the day.
    - Follow each line from one time band to the next (improving / degrading).
    - Measure how much worse each line gets at peak, and compare each line with its mode.

Business questions:
    - In which time bands is a line above or below its own average?
    - Is each line improving or degrading through the day?
    - Which lines suffer most at peak hours?
    - Which lines are above or below their mode's average?

SQL Functions Used:
    - LAG(), SUM() OVER (PARTITION BY ...), CHOOSE()
    - CASE WHEN, COUNT(), COUNT(DISTINCT), SUM(), NULLIF(), CAST()

Notes:
    - One service day: time bands replace weeks. Bands, in order: 1 Early (00:00-06:59), 2 Morning peak
      (07:00-08:59), 3 Midday (09:00-15:59), 4 Evening peak (16:00-18:59), 5 Evening (19:00-00:59).
    - Regular lines with at least 20 operated runs (163 lines); late = delay > 180 s, operated passages only.
    - Averages are weighted by passages (sums / sums), never averages of percentages.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Each line and time band vs the line's own average, and vs the previous band
-- ============================================================================
-- Expectation: 797 rows for 163 lines; line 33: 17.2 -> 52.8 -> 37.6 -> 60.9 -> 33.0 % late
-- (First band, Degrading, Improving, Degrading, Improving); 'Low volume' = fewer than 50 passages
WITH passages AS (
    SELECT
        l.line_code,
        l.mode,
        f.run_id,
        f.date_key,
        f.delay_s,
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
), eligible_lines AS (
    SELECT
        line_code
    FROM passages
    GROUP BY line_code
    HAVING COUNT(DISTINCT CONCAT(run_id, '|', date_key)) >= 20
), banded AS (
    SELECT
        p.line_code,
        p.mode,
        p.delay_s,
        CASE
            WHEN p.service_hour BETWEEN 0 AND 6   THEN 1
            WHEN p.service_hour BETWEEN 7 AND 8   THEN 2
            WHEN p.service_hour BETWEEN 9 AND 15  THEN 3
            WHEN p.service_hour BETWEEN 16 AND 18 THEN 4
            ELSE 5
        END AS band_order
    FROM passages p
    JOIN eligible_lines e
        ON e.line_code = p.line_code
), line_bands AS (
    SELECT
        line_code,
        mode,
        band_order,
        COUNT(*)                                       AS operated_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM banded
    GROUP BY line_code, mode, band_order
), compared AS (
    SELECT
        *,
        100.0 * late_passages / operated_passages                                     AS late_pct,
        -- Line average weighted by passages: not AVG() of the band percentages
        100.0 * SUM(late_passages) OVER (PARTITION BY line_code)
              / SUM(operated_passages) OVER (PARTITION BY line_code)                 AS line_avg_late_pct,
        LAG(100.0 * late_passages / operated_passages)
            OVER (PARTITION BY line_code ORDER BY band_order)                        AS previous_band_late_pct
    FROM line_bands
)
SELECT
    line_code,
    mode,
    band_order,
    CHOOSE(band_order, 'Early', 'Morning peak', 'Midday', 'Evening peak', 'Evening') AS time_band,
    operated_passages,
    CAST(late_pct AS DECIMAL(5, 1))                          AS late_pct,
    CAST(line_avg_late_pct AS DECIMAL(5, 1))                 AS line_avg_late_pct,
    CAST(late_pct - line_avg_late_pct AS DECIMAL(5, 1))      AS diff_from_line_avg,
    CASE
        WHEN late_pct > line_avg_late_pct THEN 'Above average'
        WHEN late_pct < line_avg_late_pct THEN 'Below average'
        ELSE 'Equal'
    END                                                      AS vs_line_avg,
    CASE
        WHEN previous_band_late_pct IS NULL      THEN 'First band'
        WHEN late_pct > previous_band_late_pct   THEN 'Degrading'
        WHEN late_pct < previous_band_late_pct   THEN 'Improving'
        ELSE 'No change'
    END                                                      AS trend,
    CASE WHEN operated_passages < 50 THEN 'Low volume' ELSE 'OK' END AS volume_flag
FROM compared
ORDER BY line_code, band_order;

-- Summary per time band
-- Expectation: Morning peak 111 above own average / 119 degrading; Midday 110 improving;
-- Evening peak 123 above / 121 degrading; Evening 115 improving
WITH passages AS (
    SELECT
        l.line_code,
        l.mode,
        f.run_id,
        f.date_key,
        f.delay_s,
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
), eligible_lines AS (
    SELECT
        line_code
    FROM passages
    GROUP BY line_code
    HAVING COUNT(DISTINCT CONCAT(run_id, '|', date_key)) >= 20
), banded AS (
    SELECT
        p.line_code,
        p.delay_s,
        CASE
            WHEN p.service_hour BETWEEN 0 AND 6   THEN 1
            WHEN p.service_hour BETWEEN 7 AND 8   THEN 2
            WHEN p.service_hour BETWEEN 9 AND 15  THEN 3
            WHEN p.service_hour BETWEEN 16 AND 18 THEN 4
            ELSE 5
        END AS band_order
    FROM passages p
    JOIN eligible_lines e
        ON e.line_code = p.line_code
), line_bands AS (
    SELECT
        line_code,
        band_order,
        COUNT(*)                                       AS operated_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM banded
    GROUP BY line_code, band_order
), compared AS (
    SELECT
        band_order,
        100.0 * late_passages / operated_passages                                     AS late_pct,
        100.0 * SUM(late_passages) OVER (PARTITION BY line_code)
              / SUM(operated_passages) OVER (PARTITION BY line_code)                 AS line_avg_late_pct,
        LAG(100.0 * late_passages / operated_passages)
            OVER (PARTITION BY line_code ORDER BY band_order)                        AS previous_band_late_pct
    FROM line_bands
)
SELECT
    band_order,
    CHOOSE(band_order, 'Early', 'Morning peak', 'Midday', 'Evening peak', 'Evening') AS time_band,
    COUNT(*)                                                                AS lines,
    SUM(CASE WHEN late_pct > line_avg_late_pct THEN 1 ELSE 0 END)           AS above_own_avg,
    SUM(CASE WHEN late_pct < line_avg_late_pct THEN 1 ELSE 0 END)           AS below_own_avg,
    SUM(CASE WHEN late_pct > previous_band_late_pct THEN 1 ELSE 0 END)      AS degrading,
    SUM(CASE WHEN late_pct < previous_band_late_pct THEN 1 ELSE 0 END)      AS improving,
    SUM(CASE WHEN previous_band_late_pct IS NULL THEN 1 ELSE 0 END)         AS first_band
FROM compared
GROUP BY band_order
ORDER BY band_order;

-- ============================================================================
-- 2. Peak penalty: peak vs off-peak for each line
-- ============================================================================
-- Top 10 lines that get worse at peak (lines with at least 100 passages at peak and off-peak: 157 lines)
-- Expectation: 245 (57.5 % vs 20.9 %, +36.7 points), 144 (+31.3), 146 (+29.8)
WITH passages AS (
    SELECT
        l.line_code,
        l.mode,
        f.run_id,
        f.date_key,
        f.delay_s,
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
), eligible_lines AS (
    SELECT
        line_code
    FROM passages
    GROUP BY line_code
    HAVING COUNT(DISTINCT CONCAT(run_id, '|', date_key)) >= 20
), line_peak AS (
    -- Peak and off-peak side by side in one row per line (conditional aggregation)
    SELECT
        p.line_code,
        p.mode,
        SUM(CASE WHEN p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18 THEN 1 ELSE 0 END) AS peak_passages,
        SUM(CASE WHEN (p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18)
                  AND p.delay_s > 180 THEN 1 ELSE 0 END)                                                AS peak_late,
        SUM(CASE WHEN NOT (p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18) THEN 1 ELSE 0 END) AS off_peak_passages,
        SUM(CASE WHEN NOT (p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18)
                  AND p.delay_s > 180 THEN 1 ELSE 0 END)                                                AS off_peak_late
    FROM passages p
    JOIN eligible_lines e
        ON e.line_code = p.line_code
    GROUP BY p.line_code, p.mode
)
SELECT TOP 10
    line_code,
    mode,
    peak_passages,
    off_peak_passages,
    CAST(100.0 * peak_late / peak_passages AS DECIMAL(5, 1))                                       AS peak_late_pct,
    CAST(100.0 * off_peak_late / off_peak_passages AS DECIMAL(5, 1))                               AS off_peak_late_pct,
    CAST(100.0 * peak_late / peak_passages - 100.0 * off_peak_late / off_peak_passages AS DECIMAL(5, 1)) AS peak_penalty_pts
FROM line_peak
WHERE peak_passages >= 100
  AND off_peak_passages >= 100
ORDER BY 100.0 * peak_late / peak_passages - 100.0 * off_peak_late / off_peak_passages DESC;

-- Lines worse or better at peak
-- Expectation: 163 lines: 129 worse at peak, 26 better, 7 equal (0 % all day), 1 without both bands
WITH passages AS (
    SELECT
        l.line_code,
        f.run_id,
        f.date_key,
        f.delay_s,
        DATEDIFF(hour, d.full_date, f.planned_arrival) AS service_hour
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    JOIN gold.dim_dates d
        ON d.date_key = f.date_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
), eligible_lines AS (
    SELECT
        line_code
    FROM passages
    GROUP BY line_code
    HAVING COUNT(DISTINCT CONCAT(run_id, '|', date_key)) >= 20
), line_peak AS (
    SELECT
        p.line_code,
        100.0 * SUM(CASE WHEN (p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18) AND p.delay_s > 180 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18 THEN 1 ELSE 0 END), 0)            AS peak_late_pct,
        100.0 * SUM(CASE WHEN NOT (p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18) AND p.delay_s > 180 THEN 1 ELSE 0 END)
              / NULLIF(SUM(CASE WHEN NOT (p.service_hour BETWEEN 7 AND 8 OR p.service_hour BETWEEN 16 AND 18) THEN 1 ELSE 0 END), 0)      AS off_peak_late_pct
    FROM passages p
    JOIN eligible_lines e
        ON e.line_code = p.line_code
    GROUP BY p.line_code
)
SELECT
    COUNT(*)                                                                                    AS lines,
    SUM(CASE WHEN peak_late_pct > off_peak_late_pct THEN 1 ELSE 0 END)                          AS worse_at_peak,
    SUM(CASE WHEN peak_late_pct < off_peak_late_pct THEN 1 ELSE 0 END)                          AS better_at_peak,
    SUM(CASE WHEN peak_late_pct = off_peak_late_pct THEN 1 ELSE 0 END)                          AS equal,
    SUM(CASE WHEN peak_late_pct IS NULL OR off_peak_late_pct IS NULL THEN 1 ELSE 0 END)         AS missing_band
FROM line_peak;

-- ============================================================================
-- 3. Each line vs its mode's average
-- ============================================================================
-- Expectation: Bus 33.9 % late: 47 lines above, 96 below; Tram 20.5 %: 3 above, 5 below;
-- Trolleybus 25.5 %: 2 above, 3 below; Metro, Funicular, River shuttle 0 %: all equal
WITH passages AS (
    SELECT
        l.line_code,
        l.mode,
        f.run_id,
        f.date_key,
        f.delay_s
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
), line_totals AS (
    SELECT
        line_code,
        mode,
        COUNT(*)                                       AS operated_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM passages
    GROUP BY line_code, mode
    HAVING COUNT(DISTINCT CONCAT(run_id, '|', date_key)) >= 20
), compared AS (
    SELECT
        *,
        100.0 * late_passages / operated_passages                                     AS late_pct,
        100.0 * SUM(late_passages) OVER (PARTITION BY mode)
              / SUM(operated_passages) OVER (PARTITION BY mode)                      AS mode_avg_late_pct
    FROM line_totals
)
SELECT
    mode,
    CAST(MAX(mode_avg_late_pct) AS DECIMAL(5, 1))                       AS mode_avg_late_pct,
    COUNT(*)                                                            AS lines,
    SUM(CASE WHEN late_pct > mode_avg_late_pct THEN 1 ELSE 0 END)       AS above_mode_avg,
    SUM(CASE WHEN late_pct < mode_avg_late_pct THEN 1 ELSE 0 END)       AS below_mode_avg,
    SUM(CASE WHEN late_pct = mode_avg_late_pct THEN 1 ELSE 0 END)       AS equal
FROM compared
GROUP BY mode
ORDER BY lines DESC;

-- Detail per line, sorted by distance to the mode's average
-- Expectation: 163 rows
WITH passages AS (
    SELECT
        l.line_code,
        l.mode,
        f.run_id,
        f.date_key,
        f.delay_s
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
), line_totals AS (
    SELECT
        line_code,
        mode,
        COUNT(*)                                       AS operated_passages,
        SUM(CASE WHEN delay_s > 180 THEN 1 ELSE 0 END) AS late_passages
    FROM passages
    GROUP BY line_code, mode
    HAVING COUNT(DISTINCT CONCAT(run_id, '|', date_key)) >= 20
), compared AS (
    SELECT
        *,
        100.0 * late_passages / operated_passages                                     AS late_pct,
        100.0 * SUM(late_passages) OVER (PARTITION BY mode)
              / SUM(operated_passages) OVER (PARTITION BY mode)                      AS mode_avg_late_pct
    FROM line_totals
)
SELECT
    mode,
    line_code,
    operated_passages,
    CAST(late_pct AS DECIMAL(5, 1))                         AS late_pct,
    CAST(mode_avg_late_pct AS DECIMAL(5, 1))                AS mode_avg_late_pct,
    CAST(late_pct - mode_avg_late_pct AS DECIMAL(5, 1))     AS diff_from_mode_avg,
    CASE
        WHEN late_pct > mode_avg_late_pct THEN 'Above mode average'
        WHEN late_pct < mode_avg_late_pct THEN 'Below mode average'
        ELSE 'Equal'
    END                                                     AS vs_mode_avg
FROM compared
ORDER BY mode, late_pct - mode_avg_late_pct DESC;
