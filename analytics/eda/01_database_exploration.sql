/*
===============================================================================
Database Exploration
===============================================================================
Purpose:
    - List the objects analysts can query (gold tables, analytics views) and their type.
    - Inspect the columns of each object: data type, length and nullability.
    - Count the rows of each table, to know the order of magnitude of every later number.

Business questions:
    - Which objects are available, and is each one a table or a view?
    - Which columns does each object have, with which type, and can they be NULL?
    - How many rows does each table hold?
    - What does one row of each fact table represent (its grain)?

SQL functions used:
    - INFORMATION_SCHEMA.TABLES, INFORMATION_SCHEMA.COLUMNS (ANSI catalog views)
    - COUNT(), UNION ALL
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ============================================================================
-- Objects available to analysts
-- ============================================================================
-- Expectation: 6 BASE TABLE in gold; no analytics objects until the report views exist
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    TABLE_TYPE
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA IN ('gold', 'analytics')
ORDER BY TABLE_SCHEMA, TABLE_NAME;

-- ============================================================================
-- Columns of each object
-- ============================================================================
-- Expectation: 53 columns, in the order of the table definitions (docs/data_catalog.md)
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    ORDINAL_POSITION,
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA IN ('gold', 'analytics')
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION;

-- ============================================================================
-- Row count of each table
-- ============================================================================
-- Expectation: dim_dates 365, dim_lines 1,585, dim_stops 9,774, dim_vehicles 2,037,
-- fact_trips 471,946, fact_line_stops 21,629
SELECT 'gold.dim_dates'       AS table_name, COUNT(*) AS row_count FROM gold.dim_dates
UNION ALL
SELECT 'gold.dim_lines'       AS table_name, COUNT(*) AS row_count FROM gold.dim_lines
UNION ALL
SELECT 'gold.dim_stops'       AS table_name, COUNT(*) AS row_count FROM gold.dim_stops
UNION ALL
SELECT 'gold.dim_vehicles'    AS table_name, COUNT(*) AS row_count FROM gold.dim_vehicles
UNION ALL
SELECT 'gold.fact_trips'      AS table_name, COUNT(*) AS row_count FROM gold.fact_trips
UNION ALL
SELECT 'gold.fact_line_stops' AS table_name, COUNT(*) AS row_count FROM gold.fact_line_stops;

/*
===============================================================================
Grain of the fact tables
===============================================================================
gold.fact_trips
    - One row = one run at one stop position on one service day (run_id, date_key, stop_position).
      It is NOT one row per run: runs are counted on (run_id, date_key), never with COUNT(*).
    - Measures: delay_s, dwell_s, boardings, alightings. All are nullable: NULL when the stop
      was not served, or when the vehicle has no passenger counter.
    - status is a filter, not a measure: OPERATED rows only for delays, every status for
      reliability (cancellations, skipped stops).
    - date_key is nullable (service day not recovered): an inner join to dim_dates drops those rows.

gold.fact_line_stops
    - One row = one stop position on one line in one direction (line_key, stop_position).
    - No measures, no dates: it describes the route, not what happened.

Dimensions
    - dim_stops and dim_vehicles include the 'n/a' member (key 0): one row more than the real
      stops / vehicles.
    - dim_dates is a calendar of whole years, not the list of service days.
===============================================================================
*/
