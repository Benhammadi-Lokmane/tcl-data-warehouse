/*
===============================================================================
Quality Checks
===============================================================================
Script Purpose:
    This script performs various quality checks for data consistency, accuracy,
    and standardization across the 'silver' layer. It includes checks for:
    - Null or duplicate keys.
    - Unwanted spaces in string fields.
    - Data standardization and consistency.
    - Invalid date ranges and orders.
    - Data consistency between related fields.
    - Relationships between tables (keys of one table found in the other).

Usage Notes:
    - Run these checks after loading the Silver Layer (EXEC silver.load_silver).
    - Investigate and resolve any discrepancies found during the checks.
    - The database collation is case-insensitive: DISTINCT and GROUP BY would show 'Bus' and
      'BUS' as one value. Standardization checks use COLLATE Latin1_General_100_CS_AS to see both.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- ====================================================================
-- Checking 'silver.network_stops'
-- ====================================================================
-- Check for NULLs or Duplicates in Key
-- Expectation: No Results
SELECT
    stp_id,
    COUNT(*)
FROM silver.network_stops
GROUP BY stp_id
HAVING COUNT(*) > 1 OR stp_id IS NULL;

-- Check for Unwanted Spaces or Missing Names
-- Expectation: No Results
SELECT
    stp_id,
    stp_name,
    stp_address,
    stp_city
FROM silver.network_stops
WHERE stp_name != TRIM(stp_name)
   OR stp_address != TRIM(stp_address)
   OR stp_city != TRIM(stp_city)
   OR stp_name IS NULL
   OR stp_name = '';

-- Check for Cities Spelled Several Ways (same city once accents, case, '-' and St/Ste are ignored)
-- Expectation: No Results
SELECT
    city_key,
    COUNT(DISTINCT stp_city) AS spellings,
    STRING_AGG(stp_city, ' | ') AS examples
FROM (
    SELECT DISTINCT
        stp_city COLLATE Latin1_General_100_CS_AS AS stp_city,
        TRIM(REPLACE(REPLACE(
            ' ' + UPPER(TRANSLATE(REPLACE(stp_city, '-', ' '),
                                  N'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', N'aaaeeeeiioouuucAAAEEEEIIOOUUUC')) + ' ',
            ' ST ', ' SAINT '), ' STE ', ' SAINTE ')) AS city_key
    FROM silver.network_stops
) t
GROUP BY city_key
HAVING COUNT(DISTINCT stp_city) > 1;

-- Check for Cities Written Entirely in Capitals (official names are mixed case; a consistent
-- wrong spelling is not caught by the check above)
-- Expectation: No Results
SELECT DISTINCT
    stp_city
FROM silver.network_stops
WHERE stp_city COLLATE Latin1_General_100_CS_AS = UPPER(stp_city) COLLATE Latin1_General_100_CS_AS
  AND stp_city <> 'n/a';

-- Data Standardization & Consistency
SELECT DISTINCT stp_city COLLATE Latin1_General_100_CS_AS AS stp_city FROM silver.network_stops ORDER BY 1;
SELECT DISTINCT stp_zone COLLATE Latin1_General_100_CS_AS AS stp_zone FROM silver.network_stops ORDER BY 1;
SELECT DISTINCT stp_pmr COLLATE Latin1_General_100_CS_AS AS stp_pmr FROM silver.network_stops ORDER BY 1;

-- Check for Missing or Out-of-Area Coordinates (the network reaches from Roanne to the Isère)
-- Expectation: No Results
SELECT
    stp_id,
    stp_lat,
    stp_lon
FROM silver.network_stops
WHERE stp_lat IS NULL OR stp_lon IS NULL
   OR stp_lat NOT BETWEEN 45.0 AND 46.5
   OR stp_lon NOT BETWEEN 3.8 AND 5.6;

-- Check for Future Update Dates
-- Expectation: No Results
SELECT
    stp_id,
    stp_update_dt
FROM silver.network_stops
WHERE stp_update_dt > GETDATE();

-- ====================================================================
-- Checking 'silver.network_lines'
-- ====================================================================
-- Check for NULLs or Duplicates in Key (line + direction + version)
-- Expectation: No Results
SELECT
    ln_key,
    ln_dir,
    ln_start_dt,
    COUNT(*)
FROM silver.network_lines
GROUP BY ln_key, ln_dir, ln_start_dt
HAVING COUNT(*) > 1 OR ln_key IS NULL;

-- Check for Unwanted Spaces
-- Expectation: No Results
SELECT
    ln_key,
    ln_name
FROM silver.network_lines
WHERE ln_name != TRIM(ln_name);

-- Data Standardization & Consistency (expected: Outbound, Return)
SELECT DISTINCT ln_dir COLLATE Latin1_General_100_CS_AS AS ln_dir FROM silver.network_lines;

-- Check for Invalid Colours
-- Expectation: No Results
SELECT
    ln_key,
    ln_color
FROM silver.network_lines
WHERE ln_color NOT LIKE '[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]';

-- Check for Invalid Date Orders (End Date < Start Date)
-- Expectation: No Results
SELECT
    *
FROM silver.network_lines
WHERE ln_end_dt < ln_start_dt;

-- Check for Exactly One Current Version per Line and Direction
-- Expectation: No Results
SELECT
    ln_code,
    ln_dir,
    COUNT(*) AS current_versions
FROM silver.network_lines
WHERE ln_end_dt IS NULL
GROUP BY ln_code, ln_dir
HAVING COUNT(*) <> 1;

-- ====================================================================
-- Checking 'silver.network_line_stop'
-- ====================================================================
-- Check for NULLs or Duplicates in Key (line + direction + position)
-- Expectation: No Results
SELECT
    ls_line,
    ls_dir,
    ls_pos,
    COUNT(*)
FROM silver.network_line_stop
GROUP BY ls_line, ls_dir, ls_pos
HAVING COUNT(*) > 1 OR ls_line IS NULL OR ls_pos IS NULL;

-- Check for Positions that are not 1..n
-- Expectation: No Results
SELECT
    ls_line,
    ls_dir,
    MIN(ls_pos) AS first_pos,
    MAX(ls_pos) AS last_pos,
    COUNT(*) AS stops
FROM silver.network_line_stop
GROUP BY ls_line, ls_dir
HAVING MIN(ls_pos) <> 1 OR MAX(ls_pos) <> COUNT(*);

-- Data Standardization & Consistency (expected: Outbound, Return)
SELECT DISTINCT ls_dir COLLATE Latin1_General_100_CS_AS AS ls_dir FROM silver.network_line_stop;

-- ====================================================================
-- Checking 'silver.ops_mode_category'
-- ====================================================================
-- Check for NULLs or Duplicates in Key
-- Expectation: No Results
SELECT
    id,
    COUNT(*)
FROM silver.ops_mode_category
GROUP BY id
HAVING COUNT(*) > 1 OR id IS NULL;

-- Check for Unwanted Spaces
-- Expectation: No Results
SELECT
    *
FROM silver.ops_mode_category
WHERE id != TRIM(id) OR mode != TRIM(mode) OR category != TRIM(category);

-- Data Standardization & Consistency
SELECT DISTINCT
    mode COLLATE Latin1_General_100_CS_AS AS mode,
    category COLLATE Latin1_General_100_CS_AS AS category
FROM silver.ops_mode_category
ORDER BY 1, 2;

-- ====================================================================
-- Checking 'silver.ops_vehicles'
-- ====================================================================
-- Check for NULLs or Duplicates in Key (vehicle + version)
-- Expectation: No Results
SELECT
    veh_id,
    in_service,
    COUNT(*)
FROM silver.ops_vehicles
GROUP BY veh_id, in_service
HAVING COUNT(*) > 1 OR veh_id IS NULL;

-- Check for Exactly One Current Version per Vehicle
-- Expectation: No Results
SELECT
    veh_id,
    COUNT(*) AS current_versions
FROM silver.ops_vehicles
WHERE out_service IS NULL
GROUP BY veh_id
HAVING COUNT(*) <> 1;

-- Data Standardization & Consistency (expected: the 6 modes, no 'n/a')
SELECT DISTINCT veh_type COLLATE Latin1_General_100_CS_AS AS veh_type FROM silver.ops_vehicles ORDER BY 1;
SELECT DISTINCT depot COLLATE Latin1_General_100_CS_AS AS depot FROM silver.ops_vehicles ORDER BY 1;

-- Check for NULLs or Invalid Capacities
-- Expectation: No Results
SELECT
    veh_id,
    veh_type,
    cap
FROM silver.ops_vehicles
WHERE cap IS NULL OR cap <= 0;

-- Check for Out-of-Range Dates and Invalid Date Orders
-- Expectation: No Results
SELECT
    veh_id,
    in_service,
    out_service
FROM silver.ops_vehicles
WHERE in_service < '1950-01-01'
   OR in_service > GETDATE()
   OR out_service < in_service;

-- Vehicles with an Unknown Service Date (placeholder dates set to NULL in silver)
-- Expectation: review
SELECT
    veh_id,
    veh,
    veh_type
FROM silver.ops_vehicles
WHERE in_service IS NULL;

-- ====================================================================
-- Checking 'silver.ops_trips'
-- ====================================================================
-- Check for NULLs or Duplicates in Key (run + service day + position)
-- Expectation: No Results
SELECT
    trp_run,
    trp_dt,
    trp_pos,
    COUNT(*)
FROM silver.ops_trips
GROUP BY trp_run, trp_dt, trp_pos
HAVING COUNT(*) > 1 OR trp_run IS NULL OR trp_dt IS NULL OR trp_pos IS NULL;

-- Check for Missing Stops (recovered from the same run on another day: needs several days of data)
-- Expectation: No Results
SELECT
    trp_run,
    trp_dt,
    trp_pos
FROM silver.ops_trips
WHERE trp_stop IS NULL;

-- Data Standardization & Consistency (expected: OPERATED, CANCELLED, SKIPPED / Outbound, Return)
SELECT DISTINCT trp_status COLLATE Latin1_General_100_CS_AS AS trp_status FROM silver.ops_trips;
SELECT DISTINCT trp_dir COLLATE Latin1_General_100_CS_AS AS trp_dir FROM silver.ops_trips;

-- Check Status Consistency with the Other Columns
-- CANCELLED: no vehicle, times or counts / SKIPPED: no actual times or counts / OPERATED: actual times
-- Expectation: No Results
SELECT TOP 100
    *
FROM silver.ops_trips
WHERE (trp_status = 'CANCELLED' AND (trp_veh IS NOT NULL OR trp_arr IS NOT NULL OR trp_dep IS NOT NULL OR trp_board IS NOT NULL))
   OR (trp_status = 'SKIPPED' AND (trp_arr IS NOT NULL OR trp_dep IS NOT NULL OR trp_board IS NOT NULL))
   OR (trp_status = 'OPERATED' AND (trp_arr IS NULL OR trp_dep IS NULL));

-- Check for Runs Cancelled on Some Rows Only
-- Expectation: No Results
SELECT
    trp_run,
    trp_dt
FROM silver.ops_trips
GROUP BY trp_run, trp_dt
HAVING SUM(CASE WHEN trp_status = 'CANCELLED' THEN 1 ELSE 0 END) BETWEEN 1 AND COUNT(*) - 1;

-- Check for Invalid Time Orders (Arrival > Departure)
-- Expectation: No Results
SELECT TOP 100
    *
FROM silver.ops_trips
WHERE trp_arr > trp_dep
   OR trp_plan_arr > trp_plan_dep;

-- Check Data Consistency: Dwell = Departure - Arrival
-- Expectation: No Results
SELECT TOP 100
    trp_run,
    trp_dt,
    trp_pos,
    trp_arr,
    trp_dep,
    trp_dwell_s
FROM silver.ops_trips
WHERE trp_dwell_s != DATEDIFF(second, trp_arr, trp_dep)
   OR trp_dwell_s < 0
   OR (trp_dwell_s IS NULL AND trp_arr IS NOT NULL AND trp_dep IS NOT NULL);

-- Check for Negative or Impossible Passenger Counts (more than the vehicle's capacity)
-- Expectation: No Results
SELECT TOP 100
    t.trp_run,
    t.trp_dt,
    t.trp_pos,
    t.trp_veh,
    t.trp_board,
    t.trp_alight,
    v.cap
FROM silver.ops_trips t
LEFT JOIN silver.ops_vehicles v
    ON v.veh_id = t.trp_veh AND v.out_service IS NULL
WHERE t.trp_board < 0
   OR t.trp_alight < 0
   OR t.trp_board > v.cap
   OR t.trp_alight > v.cap;

-- Delay Distribution by Status
-- Expectation: review (delays only on OPERATED rows; several hours would be suspicious)
SELECT
    trp_status,
    COUNT(*) AS rows_,
    MIN(trp_delay_s) AS min_delay_s,
    AVG(CAST(trp_delay_s AS BIGINT)) AS avg_delay_s,
    MAX(trp_delay_s) AS max_delay_s
FROM silver.ops_trips
GROUP BY trp_status;

-- ====================================================================
-- Checking Relationships between Silver Tables
-- ====================================================================
-- Trips whose Line + Direction is not in network_lines
-- Expectation: No Results
SELECT DISTINCT
    t.trp_line_code,
    t.trp_dir
FROM silver.ops_trips t
WHERE NOT EXISTS (
    SELECT 1 FROM silver.network_lines l
    WHERE l.ln_code = t.trp_line_code AND l.ln_dir = t.trp_dir
);

-- Trips whose Stop is not in network_stops
-- Expectation: No Results
SELECT DISTINCT
    t.trp_stop
FROM silver.ops_trips t
WHERE t.trp_stop IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM silver.network_stops s WHERE s.stp_id = t.trp_stop);

-- Trips whose Vehicle is not in ops_vehicles
-- Expectation: review (vehicles missing from the fleet table: trips kept, unknown vehicle in gold)
SELECT
    t.trp_veh,
    COUNT(*) AS trip_rows
FROM silver.ops_trips t
WHERE t.trp_veh IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM silver.ops_vehicles v WHERE v.veh_id = t.trp_veh)
GROUP BY t.trp_veh
ORDER BY trip_rows DESC;

-- Line Stops whose Line + Direction is not in network_lines
-- Expectation: No Results
SELECT DISTINCT
    ls.ls_line,
    ls.ls_dir
FROM silver.network_line_stop ls
WHERE NOT EXISTS (
    SELECT 1 FROM silver.network_lines l
    WHERE l.ln_code = ls.ls_line AND l.ln_dir = ls.ls_dir
);

-- Line Stops whose Stop is not in network_stops
-- Expectation: No Results
SELECT DISTINCT
    ls.ls_stop
FROM silver.network_line_stop ls
WHERE NOT EXISTS (SELECT 1 FROM silver.network_stops s WHERE s.stp_id = ls.ls_stop);

-- Lines whose Mode / Category is not in ops_mode_category
-- Expectation: No Results
SELECT DISTINCT
    l.ln_key,
    l.ln_mode_cat_id
FROM silver.network_lines l
WHERE NOT EXISTS (SELECT 1 FROM silver.ops_mode_category m WHERE m.id = l.ln_mode_cat_id);

-- Vehicles Running Lines of Another Mode than their Type
-- Expectation: No Results
SELECT DISTINCT
    v.veh_id,
    v.veh_type,
    m.mode AS line_mode
FROM silver.ops_trips t
JOIN silver.ops_vehicles v ON v.veh_id = t.trp_veh AND v.out_service IS NULL
JOIN (SELECT DISTINCT ln_code, ln_mode_cat_id FROM silver.network_lines) l ON l.ln_code = t.trp_line_code
JOIN silver.ops_mode_category m ON m.id = l.ln_mode_cat_id
WHERE v.veh_type <> m.mode;
