/*
===============================================================================
Data Segmentation
===============================================================================
Purpose:
    - Group lines, stops and passages into segments that can each get an action.
    - Compare fixed business thresholds (CASE) with relative groups (NTILE).

Business questions:
    - How many lines are Good, Watch or In difficulty, and which of them are a priority?
    - How do fixed thresholds compare with quartiles of lines?
    - How many stops have a low, medium or high demand, and what share of boardings do they take?
    - How are passages spread over delay bands?

SQL Functions Used:
    - CASE WHEN, CHOOSE(), NTILE(), PERCENTILE_CONT() OVER ()
    - COUNT(), COUNT(DISTINCT), SUM(), SUM(SUM()) OVER (), MIN(), MAX(), NULLIF(), CAST()

Notes:
    - Line segments (Regular lines with at least 20 runs): Good <= 10 % late, Watch <= 20 %, In difficulty > 20 %.
      Priority = In difficulty and at least the median volume of operated passages.
    - Stop demand (counted boardings, equipped vehicles): High >= 100, Medium 20-99, Low < 20,
      No count = no equipped vehicle counted at the stop (NULL is not 0).
    - Each member is segmented at its own grain first (CTE), then the segments are counted.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Lines by punctuality
-- ============================================================================
-- Expectation: Good 9, Watch 12, In difficulty 142 (87 %); 163 lines
WITH line_punctuality AS (
    SELECT
        l.line_code,
        l.mode,
        COUNT(*)                                                             AS operated_passages,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code, l.mode
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
), segmented AS (
    SELECT
        *,
        CASE
            WHEN late_pct <= 10 THEN 1
            WHEN late_pct <= 20 THEN 2
            ELSE 3
        END AS segment_order
    FROM line_punctuality
)
SELECT
    segment_order,
    CHOOSE(segment_order, 'Good', 'Watch', 'In difficulty')       AS punctuality_segment,
    COUNT(*)                                                      AS lines,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1)) AS lines_pct,
    SUM(operated_passages)                                        AS operated_passages
FROM segmented
GROUP BY segment_order
ORDER BY segment_order;

-- Lines per segment and mode
-- Expectation: Bus 0 / 8 / 135; Tram 2 / 3 / 3; Trolleybus 0 / 1 / 4; Metro, Funicular, River shuttle all Good
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
SELECT
    mode,
    SUM(CASE WHEN late_pct <= 10 THEN 1 ELSE 0 END)                    AS good,
    SUM(CASE WHEN late_pct > 10 AND late_pct <= 20 THEN 1 ELSE 0 END)  AS watch,
    SUM(CASE WHEN late_pct > 20 THEN 1 ELSE 0 END)                     AS in_difficulty,
    COUNT(*)                                                           AS lines
FROM line_punctuality
GROUP BY mode
ORDER BY lines DESC;

-- ============================================================================
-- 2. Priority lines: punctuality x volume
-- ============================================================================
-- Expectation: Priority 76 lines / 311,366 passages (71 %); In difficulty, small 66; Watch 12; Good 9;
-- median volume 2,189 operated passages
WITH line_punctuality AS (
    SELECT
        l.line_code,
        COUNT(*)                                                             AS operated_passages,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
), with_median AS (
    SELECT
        *,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY operated_passages) OVER () AS median_passages
    FROM line_punctuality
), segmented AS (
    SELECT
        *,
        CASE
            WHEN late_pct > 20 AND operated_passages >= median_passages THEN 1
            WHEN late_pct > 20                                          THEN 2
            WHEN late_pct > 10                                          THEN 3
            ELSE 4
        END AS segment_order
    FROM with_median
)
SELECT
    segment_order,
    CHOOSE(segment_order, 'Priority', 'In difficulty, small', 'Watch', 'Good')            AS line_segment,
    COUNT(*)                                                                              AS lines,
    SUM(operated_passages)                                                                AS operated_passages,
    CAST(100.0 * SUM(operated_passages) / SUM(SUM(operated_passages)) OVER () AS DECIMAL(5, 1)) AS passages_pct,
    MAX(median_passages)                                                                  AS median_passages
FROM segmented
GROUP BY segment_order
ORDER BY segment_order;

-- ============================================================================
-- 3. Relative segments: quartiles of lines by late %
-- ============================================================================
-- NTILE(4) always gives 4 groups of the same size, whatever the values
-- Expectation: 41 / 41 / 41 / 40 lines; most late quartile 37.0-55.1 %, least late 0-24.2 %;
-- quartiles 1 to 3 are entirely "In difficulty", and 19 of the 40 lines of quartile 4
WITH line_punctuality AS (
    SELECT
        l.line_code,
        100.0 * SUM(CASE WHEN f.delay_s > 180 THEN 1 ELSE 0 END) / COUNT(*) AS late_pct
    FROM gold.fact_trips f
    JOIN gold.dim_lines l
        ON l.line_key = f.line_key
    WHERE f.status = 'OPERATED'
      AND l.category = 'Regular'
    GROUP BY l.line_code
    HAVING COUNT(DISTINCT CONCAT(f.run_id, '|', f.date_key)) >= 20
), quartiles AS (
    SELECT
        *,
        NTILE(4) OVER (ORDER BY late_pct DESC) AS late_quartile   -- 1 = most late
    FROM line_punctuality
)
SELECT
    late_quartile,
    COUNT(*)                                         AS lines,
    CAST(MIN(late_pct) AS DECIMAL(5, 1))             AS min_late_pct,
    CAST(MAX(late_pct) AS DECIMAL(5, 1))             AS max_late_pct,
    SUM(CASE WHEN late_pct > 20 THEN 1 ELSE 0 END)   AS in_difficulty_lines
FROM quartiles
GROUP BY late_quartile
ORDER BY late_quartile;

-- ============================================================================
-- 4. Stops by demand (counted boardings, equipped vehicles)
-- ============================================================================
-- Expectation: High 874 stops (78.6 % of counted boardings), Medium 2,221 (17.5 %), Low 3,471 (3.9 %),
-- No count 2,906; stops add up to 9,472, boardings to 578,665 (the unknown stop is excluded)
WITH stop_demand AS (
    SELECT
        f.stop_key,
        SUM(f.boardings) AS boardings_equipped   -- NULL when no equipped vehicle counted at the stop
    FROM gold.fact_trips f
    WHERE f.status = 'OPERATED'
      AND f.stop_key <> 0
    GROUP BY f.stop_key
), segmented AS (
    SELECT
        *,
        CASE
            WHEN boardings_equipped IS NULL THEN 4   -- tested first: NULL is not 0
            WHEN boardings_equipped >= 100  THEN 1
            WHEN boardings_equipped >= 20   THEN 2
            ELSE 3
        END AS segment_order
    FROM stop_demand
)
SELECT
    segment_order,
    CHOOSE(segment_order, 'High', 'Medium', 'Low', 'No count')                              AS demand_segment,
    COUNT(*)                                                                                AS stops,
    SUM(boardings_equipped)                                                                 AS boardings_equipped,
    CAST(100.0 * SUM(boardings_equipped) / SUM(SUM(boardings_equipped)) OVER () AS DECIMAL(5, 1)) AS boardings_pct
FROM segmented
GROUP BY segment_order
ORDER BY segment_order;

-- NTILE(3) on the stops with a count: equal-sized groups, but equal values can land in two groups
-- Expectation: 2,189 / 2,189 / 2,188 stops; ranges 0-8, 8-35, 35-13,165 (8 and 35 appear in two tiles)
WITH stop_demand AS (
    SELECT
        f.stop_key,
        SUM(f.boardings) AS boardings_equipped
    FROM gold.fact_trips f
    WHERE f.status = 'OPERATED'
      AND f.stop_key <> 0
      AND f.boardings IS NOT NULL
    GROUP BY f.stop_key
), tiles AS (
    SELECT
        *,
        NTILE(3) OVER (ORDER BY boardings_equipped) AS demand_tile
    FROM stop_demand
)
SELECT
    demand_tile,
    COUNT(*)                AS stops,
    MIN(boardings_equipped) AS min_boardings,
    MAX(boardings_equipped) AS max_boardings
FROM tiles
GROUP BY demand_tile
ORDER BY demand_tile;

-- ============================================================================
-- 5. Passages by delay band
-- ============================================================================
-- Expectation: Early 5,012 (1.1 %), On time 322,373 (69.4 %), Late 3-5 min 63,152 (13.6 %),
-- Late 5-10 min 51,597 (11.1 %), Late > 10 min 22,147 (4.8 %); total 464,281
WITH banded AS (
    SELECT
        delay_s,
        CASE
            WHEN delay_s < -60  THEN 1
            WHEN delay_s <= 180 THEN 2
            WHEN delay_s <= 300 THEN 3
            WHEN delay_s <= 600 THEN 4
            ELSE 5
        END AS band_order
    FROM gold.fact_trips
    WHERE status = 'OPERATED'
)
SELECT
    band_order,
    CHOOSE(band_order, 'Early', 'On time', 'Late 3-5 min', 'Late 5-10 min', 'Late > 10 min') AS delay_band,
    COUNT(*)                                                         AS operated_passages,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5, 1))  AS passages_pct,
    MIN(delay_s)                                                     AS min_delay_s,
    MAX(delay_s)                                                     AS max_delay_s
FROM banded
GROUP BY band_order
ORDER BY band_order;
