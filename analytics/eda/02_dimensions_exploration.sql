/*
===============================================================================
Dimensions Exploration
===============================================================================
Purpose:
    - To explore the values of the dimension tables and how many rows carry each one,
      before using them to break down the measures in the next scripts.

Business questions:
    1. Which transport modes and line categories does the network have, and how many lines in each?
    2. Which mode x category combinations exist?
    3. Which cities and fare zones do the stops cover, and how many stops in each?
    4. How many stops are wheelchair accessible, not accessible, or unknown?
    5. Which vehicle types and depots make up the fleet?
    6. Which statuses can a passage have?

SQL Functions Used:
    - COUNT(), COUNT(DISTINCT)
    - GROUP BY, ORDER BY

Notes:
    - dim_lines has one row per line AND direction: lines are counted with COUNT(DISTINCT line_code).
    - The 'n/a' member (key 0) of dim_stops and dim_vehicles is not a stop or a vehicle: it is excluded.
    - Data quality (duplicates, spelling, spaces) is checked in tests/quality_checks_gold.sql, not here.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- 1. Modes and categories
-- ============================================================================
-- Lines per transport mode
-- Expectation: 6 modes; lines add up to 801, line_directions to 1,585
SELECT
    mode,
    COUNT(DISTINCT line_code) AS lines,
    COUNT(*)                  AS line_directions
FROM gold.dim_lines
GROUP BY mode
ORDER BY lines DESC;

-- Lines per category
-- Expectation: 7 categories; lines add up to 801 (a line code in two categories would add more)
SELECT
    category,
    COUNT(DISTINCT line_code) AS lines,
    COUNT(*)                  AS line_directions
FROM gold.dim_lines
GROUP BY category
ORDER BY lines DESC;

-- ============================================================================
-- 2. Mode x category combinations
-- ============================================================================
-- Retrieve the hierarchy mode -> category, with the number of lines in each
-- Expectation: 13 combinations
SELECT
    mode,
    category,
    COUNT(DISTINCT line_code) AS lines
FROM gold.dim_lines
GROUP BY mode, category
ORDER BY mode, lines DESC;

-- ============================================================================
-- 3. Cities and fare zones
-- ============================================================================
-- Stops per city
-- Expectation: 94 values including 'n/a'; stops add up to 9,773
SELECT
    city,
    COUNT(*) AS stops
FROM gold.dim_stops
WHERE stop_key <> 0
GROUP BY city
ORDER BY stops DESC;

-- Stops per fare zone
-- Expectation: Zone 1 to Zone 5 and Zone Externe; stops add up to 9,773
SELECT
    fare_zone,
    COUNT(*) AS stops
FROM gold.dim_stops
WHERE stop_key <> 0
GROUP BY fare_zone
ORDER BY fare_zone;

-- ============================================================================
-- 4. Accessibility
-- ============================================================================
-- Stops per wheelchair accessibility
-- Expectation: 'true', 'false' and 'n/a' (unknown); stops add up to 9,773
SELECT
    wheelchair_accessible,
    COUNT(*) AS stops
FROM gold.dim_stops
WHERE stop_key <> 0
GROUP BY wheelchair_accessible
ORDER BY stops DESC;

-- ============================================================================
-- 5. Fleet
-- ============================================================================
-- Vehicles per type
-- Expectation: 6 types; vehicles add up to 2,036
SELECT
    vehicle_type,
    COUNT(*) AS vehicles
FROM gold.dim_vehicles
WHERE vehicle_key <> 0
GROUP BY vehicle_type
ORDER BY vehicles DESC;

-- Vehicles per depot
-- Expectation: 15 depots; vehicles add up to 2,036
SELECT
    depot,
    COUNT(*) AS vehicles
FROM gold.dim_vehicles
WHERE vehicle_key <> 0
GROUP BY depot
ORDER BY vehicles DESC;

-- ============================================================================
-- 6. Statuses
-- ============================================================================
-- Stop rows per status (stop rows, not runs: runs are counted in 04_measures_exploration.sql)
-- Expectation: OPERATED, CANCELLED and SKIPPED; stop rows add up to 471,946
SELECT
    status,
    COUNT(*) AS stop_rows
FROM gold.fact_trips
GROUP BY status
ORDER BY stop_rows DESC;
