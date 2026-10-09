/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Purpose:
    This stored procedure performs the ETL (Extract, Transform, Load) process to
    populate the 'silver' schema tables from the 'bronze' schema.
	Actions Performed:
		- Truncates Silver tables.
		- Inserts transformed and cleansed data from Bronze into Silver tables.

Parameters:
    None.
	  This stored procedure does not accept any parameters or return any values.

Usage Example:
    EXEC silver.load_silver;
===============================================================================
*/
USE TclDataWarehouse;
GO

CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;
    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '================================================';
        PRINT 'Loading Silver Layer';
        PRINT '================================================';

        PRINT '------------------------------------------------';
        PRINT 'Loading Network Tables';
        PRINT '------------------------------------------------';

        -- Loading silver.network_stops
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.network_stops';
        TRUNCATE TABLE silver.network_stops;
        PRINT '>> Inserting Data Into: silver.network_stops';
        WITH latest_stops AS (
            -- A stop can be sent several times: keep its most recent record.
            -- Records without a key are copies of existing stops: dropped.
            SELECT
                *,
                ROW_NUMBER() OVER (PARTITION BY stp_key ORDER BY stp_update_dt DESC) AS flag_last
            FROM bronze.network_stops
            WHERE stp_key IS NOT NULL
        ), stops AS (
            SELECT
                *,
                -- Case-sensitive: the database collation is case-insensitive, so GROUP BY would merge 'MEYZIEU' and 'Meyzieu'
                NULLIF(TRIM(stp_city), '') COLLATE Latin1_General_100_CS_AS AS city,
                -- Comparison key for city spellings: no accents, upper case, '-' read as a space, St / Ste spelled out
                TRIM(REPLACE(REPLACE(
                    ' ' + UPPER(TRANSLATE(REPLACE(TRIM(stp_city), '-', ' '),
                                          N'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', N'aaaeeeeiioouuucAAAEEEEIIOOUUUC')) + ' ',
                    ' ST ', ' SAINT '), ' STE ', ' SAINTE ')) AS city_key
            FROM latest_stops
            WHERE flag_last = 1
        ), city_spellings AS (
            -- Official spelling of a city = its most frequent spelling
            -- (ties: mixed case, then accents, then hyphens, then the longest: Saint- rather than St-)
            SELECT
                city_key,
                city,
                ROW_NUMBER() OVER (
                    PARTITION BY city_key
                    ORDER BY COUNT(*) DESC,
                             CASE WHEN city COLLATE Latin1_General_100_CS_AS <> UPPER(city) COLLATE Latin1_General_100_CS_AS THEN 1 ELSE 0 END DESC,
                             CASE WHEN city LIKE N'%[àâäéèêëîïôöùûüç]%' THEN 1 ELSE 0 END DESC,
                             CASE WHEN city LIKE '%-%' THEN 1 ELSE 0 END DESC,
                             LEN(city) DESC,
                             city
                ) AS rn
            FROM stops
            WHERE city IS NOT NULL
            GROUP BY city_key, city
        )
        INSERT INTO silver.network_stops (
            stp_id,
            stp_key,
            stp_name,
            stp_address,
            stp_city,
            stp_zone,
            stp_pmr,
            stp_lat,
            stp_lon,
            stp_update_dt
        )
        SELECT
            CAST(SUBSTRING(s.stp_key, 5, LEN(s.stp_key)) AS INT) AS stp_id,
            s.stp_key,
            TRIM(s.stp_name) AS stp_name,
            COALESCE(NULLIF(TRIM(s.stp_address), ''), 'n/a') AS stp_address,
            CASE
                WHEN s.city IS NULL THEN 'n/a'
                -- Lyon arrondissements written 'LYON 03', 'Lyon 3e', 'Lyon3'... -> 'Lyon 3e Arrondissement'
                WHEN l.lyon_nb IS NOT NULL
                    THEN 'Lyon ' + CAST(l.lyon_nb AS VARCHAR(2)) + CASE WHEN l.lyon_nb = 1 THEN 'er' ELSE 'e' END + ' Arrondissement'
                ELSE c.city
            END AS stp_city,
            CASE
                WHEN TRIM(s.stp_zone) = 'Zone Externe' THEN TRIM(s.stp_zone)
                ELSE CONCAT('Zone ', TRIM(s.stp_zone))
            END AS stp_zone,
            CASE
                WHEN s.stp_pmr IS NULL THEN 'n/a'                 -- unknown, not "not accessible"
                WHEN s.stp_pmr IN ('Y', '1') THEN 'true'
                WHEN s.stp_pmr IN ('N', '0') THEN 'false'
                ELSE LOWER(s.stp_pmr)
            END AS stp_pmr,
            TRY_CAST(REPLACE(s.stp_lat, ',', '.') AS DECIMAL(9,6)) AS stp_lat,   -- a few use a decimal comma
            TRY_CAST(REPLACE(s.stp_lon, ',', '.') AS DECIMAL(9,6)) AS stp_lon,
            CASE WHEN s.stp_update_dt > GETDATE() THEN NULL ELSE s.stp_update_dt END AS stp_update_dt
        FROM stops s
        LEFT JOIN city_spellings c
            ON c.city_key = s.city_key AND c.rn = 1
        CROSS APPLY (
            SELECT CASE
                WHEN UPPER(s.city) LIKE 'LYON%[0-9]%' THEN TRY_CAST(SUBSTRING(s.city, PATINDEX('%[0-9]%', s.city),
                    CASE WHEN SUBSTRING(s.city, PATINDEX('%[0-9]%', s.city) + 1, 1) LIKE '[0-9]' THEN 2 ELSE 1 END) AS INT)
            END AS lyon_nb
        ) l;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading silver.network_lines
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.network_lines';
        TRUNCATE TABLE silver.network_lines;
        PRINT '>> Inserting Data Into: silver.network_lines';
        WITH coded_lines AS (
            SELECT
                ln_key,
                TRIM(ln_name) AS ln_name,
                CASE
                    WHEN UPPER(TRIM(ln_color)) LIKE '[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]' THEN UPPER(TRIM(ln_color))
                    ELSE 'n/a'
                END AS ln_color,
                ln_start_dt,
                CASE
                    WHEN TRIM(ln_dir) = 'O' THEN 'Outbound'
                    WHEN TRIM(ln_dir) = 'R' THEN 'Return'
                    ELSE 'n/a'
                END AS ln_dir
            FROM bronze.network_lines
        ), cleaned_lines AS (
            -- An empty direction is the one its sibling row (same line, same version) does not have
            SELECT
                ln_key,
                ln_name,
                ln_color,
                ln_start_dt,
                CASE
                    WHEN ln_dir <> 'n/a' THEN ln_dir
                    WHEN MAX(CASE WHEN ln_dir <> 'n/a' THEN ln_dir ELSE '' END) OVER (PARTITION BY ln_key, ln_start_dt) = 'Outbound' THEN 'Return'
                    WHEN MAX(CASE WHEN ln_dir <> 'n/a' THEN ln_dir ELSE '' END) OVER (PARTITION BY ln_key, ln_start_dt) = 'Return' THEN 'Outbound'
                    ELSE 'n/a'
                END AS ln_dir
            FROM coded_lines
        )
        INSERT INTO silver.network_lines (
            ln_key,
            ln_code,
            ln_mode_cat_id,
            ln_name,
            ln_dir,
            ln_color,
            ln_start_dt,
            ln_end_dt
        )
        SELECT
            ln_key,
            SUBSTRING(ln_key, 9, LEN(ln_key)) AS ln_code,
            -- BAT (bateau = boat) is the river shuttle, coded NAV in the ops reference (mode_category)
            REPLACE(
                CASE
                    WHEN LEFT(ln_key, 3) = 'BAT' THEN 'NAV' + SUBSTRING(ln_key, 4, 4)
                    ELSE LEFT(ln_key, 7)
                END, '-', '_') AS ln_mode_cat_id,
            ln_name,
            ln_dir,
            ln_color,
            ln_start_dt,
            -- A version ends the day before the next version of the same line and direction starts; NULL = current
            DATEADD(day, -1, LEAD(ln_start_dt) OVER (PARTITION BY ln_key, ln_dir ORDER BY ln_start_dt)) AS ln_end_dt
        FROM cleaned_lines;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading silver.network_line_stop
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.network_line_stop';
        TRUNCATE TABLE silver.network_line_stop;
        PRINT '>> Inserting Data Into: silver.network_line_stop';
        WITH distinct_line_stops AS (
            -- A stop entered twice on a line: exact duplicate rows
            SELECT DISTINCT
                TRIM(ls_line) AS ls_line,
                ls_dir,
                ls_stop,
                ls_pos
            FROM bronze.network_line_stop
        )
        INSERT INTO silver.network_line_stop (
            ls_line,
            ls_dir,
            ls_stop,
            ls_pos
        )
        SELECT
            ls_line,
            CASE
                WHEN ls_dir = 0 THEN 'Outbound'
                WHEN ls_dir = 1 THEN 'Return'
                ELSE 'n/a'
            END AS ls_dir,
            ls_stop,
            -- Renumber 1..n in the original order: closes the holes left in the numbering
            ROW_NUMBER() OVER (PARTITION BY ls_line, ls_dir ORDER BY ls_pos) AS ls_pos
        FROM distinct_line_stops;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        PRINT '------------------------------------------------';
        PRINT 'Loading Ops Tables';
        PRINT '------------------------------------------------';

        -- Loading silver.ops_mode_category
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.ops_mode_category';
        TRUNCATE TABLE silver.ops_mode_category;
        PRINT '>> Inserting Data Into: silver.ops_mode_category';
        INSERT INTO silver.ops_mode_category (
            id,
            mode,
            category
        )
        SELECT
            TRIM(id),
            TRIM(mode),
            TRIM(category)
        FROM bronze.ops_mode_category;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading silver.ops_vehicles (after network_lines and ops_mode_category: used to type vehicles)
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.ops_vehicles';
        TRUNCATE TABLE silver.ops_vehicles;
        PRINT '>> Inserting Data Into: silver.ops_vehicles';
        WITH stripped_vehicles AS (
            -- Drop the export prefix: 'TCLV002534' -> '002534', 'V2534' -> '2534'
            SELECT
                *,
                CASE
                    WHEN veh LIKE 'TCLV%' THEN SUBSTRING(veh, 5, LEN(veh))
                    WHEN veh LIKE 'V%'    THEN SUBSTRING(veh, 2, LEN(veh))
                    ELSE veh
                END AS veh_nb
            FROM bronze.ops_vehicles
        ), cleaned_vehicles AS (
            SELECT
                -- Drop the zero padding of numeric ids only; ids starting with a letter (E157005) stay as they are.
                -- Kept as text, like trp_veh, so the join with trips never converts types.
                CASE
                    WHEN veh_nb NOT LIKE '%[^0-9]%' THEN CAST(CAST(veh_nb AS INT) AS VARCHAR(50))
                    ELSE veh_nb
                END AS veh_id,
                veh,
                CASE
                    WHEN UPPER(TRIM(veh_type)) IN ('BUS', 'B') THEN 'Bus'
                    WHEN UPPER(TRIM(veh_type)) IN ('TRAM', 'TRAMWAY') THEN 'Tram'
                    WHEN UPPER(TRIM(veh_type)) IN ('METRO', 'MET') THEN 'Metro'
                    WHEN UPPER(TRIM(veh_type)) IN ('TROLLEYBUS', 'TROLLEY') THEN 'Trolleybus'
                    WHEN UPPER(TRIM(veh_type)) IN ('FUNICULAR', 'FUNI') THEN 'Funicular'
                    WHEN UPPER(TRIM(veh_type)) IN ('RIVER SHUTTLE', 'BOAT') THEN 'River shuttle'
                END AS veh_type,                                    -- NULL when blank: typed below
                cap,
                TRIM(depot) AS depot,
                CASE
                    WHEN in_service < '1950-01-01' OR in_service > GETDATE() THEN NULL   -- placeholder dates (1900-01-01, 9999-12-31)
                    ELSE in_service
                END AS in_service
            FROM stripped_vehicles
        ), mode_of_runs AS (
            -- Vehicles registered without a type: the mode of the lines they run (most frequent)
            SELECT
                t.trp_veh,
                lm.mode,
                ROW_NUMBER() OVER (PARTITION BY t.trp_veh ORDER BY COUNT(*) DESC, lm.mode) AS rn
            FROM bronze.ops_trips t
            JOIN (
                SELECT DISTINCT l.ln_code, m.mode
                FROM silver.network_lines l
                JOIN silver.ops_mode_category m ON m.id = l.ln_mode_cat_id
            ) lm ON lm.ln_code = LEFT(t.trp_line, LEN(t.trp_line) - 1)
            WHERE t.trp_veh IN (SELECT veh_id FROM cleaned_vehicles WHERE veh_type IS NULL)
            GROUP BY t.trp_veh, lm.mode
        ), typed_vehicles AS (
            SELECT
                v.veh_id,
                v.veh,
                COALESCE(v.veh_type, r.mode, 'n/a') AS veh_type,
                v.cap,
                v.depot,
                v.in_service
            FROM cleaned_vehicles v
            LEFT JOIN mode_of_runs r ON r.trp_veh = v.veh_id AND r.rn = 1
        ), usual_capacity AS (
            -- Vehicles registered without a capacity: the most frequent capacity of their type
            SELECT
                veh_type,
                cap,
                ROW_NUMBER() OVER (PARTITION BY veh_type ORDER BY COUNT(*) DESC, cap) AS rn
            FROM typed_vehicles
            WHERE cap IS NOT NULL
            GROUP BY veh_type, cap
        )
        INSERT INTO silver.ops_vehicles (
            veh_id,
            veh,
            veh_type,
            cap,
            depot,
            in_service,
            out_service
        )
        SELECT
            v.veh_id,
            v.veh,
            v.veh_type,
            COALESCE(v.cap, u.cap) AS cap,
            v.depot,
            v.in_service,
            -- A version ends the day before the vehicle's next version starts; NULL = current
            DATEADD(day, -1, LEAD(v.in_service) OVER (PARTITION BY v.veh_id ORDER BY v.in_service)) AS out_service
        FROM typed_vehicles v
        LEFT JOIN usual_capacity u ON u.veh_type = v.veh_type AND u.rn = 1;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading silver.ops_trips
        -- The largest table: staged in a temp table and cleaned in steps, then inserted in one go.
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: silver.ops_trips';
        TRUNCATE TABLE silver.ops_trips;
        PRINT '>> Inserting Data Into: silver.ops_trips';
        DROP TABLE IF EXISTS #trips;

        -- 1. Exact duplicate rows (part of a file sent twice) are dropped; service day and status standardised
        SELECT DISTINCT
            trp_run,
            TRIM(trp_line) AS trp_line,
            trp_stop,
            TRIM(trp_veh) AS trp_veh,
            CASE
                WHEN LEN(CAST(trp_dt AS VARCHAR(8))) = 8 THEN TRY_CONVERT(DATE, CAST(trp_dt AS VARCHAR(8)), 112)   -- yyyymmdd
                WHEN LEN(CAST(trp_dt AS VARCHAR(8))) = 6 THEN TRY_CONVERT(DATE, CAST(trp_dt AS VARCHAR(8)), 12)    -- yymmdd
            END AS trp_dt,                                                                                       -- 0: recovered in step 2
            trp_pos,
            trp_plan_arr,
            trp_plan_dep,
            trp_arr,
            trp_dep,
            CASE
                WHEN UPPER(TRIM(trp_status)) IN ('OPERATED', 'OK') THEN 'OPERATED'
                WHEN UPPER(TRIM(trp_status)) IN ('CANCELLED', 'CANCELED', 'CANCEL') THEN 'CANCELLED'
                WHEN UPPER(TRIM(trp_status)) = 'SKIPPED' THEN 'SKIPPED'
                ELSE 'n/a'
            END AS trp_status,
            trp_board,
            trp_alight
        INTO #trips
        FROM bronze.ops_trips;
        CREATE CLUSTERED INDEX ix_trips ON #trips (trp_run, trp_dt, trp_pos);

        -- 2. Service day lost (0): a run's rows on one day form a complete sequence of positions,
        --    so the row belongs to the only day of that run that has no row at its position
        WITH lost AS (
            SELECT trp_run, trp_pos
            FROM #trips
            WHERE trp_dt IS NULL
            GROUP BY trp_run, trp_pos
            HAVING COUNT(*) = 1
        ), candidates AS (
            SELECT l.trp_run, l.trp_pos, d.trp_dt
            FROM lost l
            JOIN (SELECT DISTINCT trp_run, trp_dt FROM #trips WHERE trp_dt IS NOT NULL) d ON d.trp_run = l.trp_run
            WHERE NOT EXISTS (
                SELECT 1 FROM #trips t
                WHERE t.trp_run = l.trp_run AND t.trp_dt = d.trp_dt AND t.trp_pos = l.trp_pos
            )
        ), recovered AS (
            SELECT trp_run, trp_pos, MIN(trp_dt) AS trp_dt
            FROM candidates
            GROUP BY trp_run, trp_pos
            HAVING COUNT(*) = 1
        )
        UPDATE t
        SET t.trp_dt = r.trp_dt
        FROM #trips t
        JOIN recovered r ON r.trp_run = t.trp_run AND r.trp_pos = t.trp_pos
        WHERE t.trp_dt IS NULL;

        -- 3. Stop not recorded: a run (trp_run) serves the same stop at the same position every day it runs
        UPDATE t
        SET t.trp_stop = s.trp_stop
        FROM #trips t
        JOIN (
            SELECT trp_run, trp_pos, MAX(trp_stop) AS trp_stop
            FROM #trips
            WHERE trp_stop IS NOT NULL
              AND trp_run IN (SELECT trp_run FROM #trips WHERE trp_stop IS NULL)
            GROUP BY trp_run, trp_pos
        ) s ON s.trp_run = t.trp_run AND s.trp_pos = t.trp_pos
        WHERE t.trp_stop IS NULL;

        -- 4. A cancelled run is cancelled on all its rows: rows still marked OPERATED, with no actual time,
        --    in a run whose other rows are CANCELLED, are cancelled too
        UPDATE t
        SET t.trp_status = 'CANCELLED'
        FROM #trips t
        WHERE t.trp_status = 'OPERATED'
          AND t.trp_arr IS NULL
          AND t.trp_dep IS NULL
          AND EXISTS (
              SELECT 1 FROM #trips c
              WHERE c.trp_run = t.trp_run AND c.trp_dt = t.trp_dt AND c.trp_status = 'CANCELLED'
          );

        -- 5. Insert: times -> datetimes, dwell recomputed, delay derived, passenger counts cleaned
        INSERT INTO silver.ops_trips WITH (TABLOCK) (
            trp_run,
            trp_line,
            trp_line_code,
            trp_dir,
            trp_stop,
            trp_veh,
            trp_dt,
            trp_pos,
            trp_plan_arr,
            trp_plan_dep,
            trp_arr,
            trp_dep,
            trp_status,
            trp_dwell_s,
            trp_delay_s,
            trp_board,
            trp_alight
        )
        SELECT
            t.trp_run,
            t.trp_line,
            LEFT(t.trp_line, LEN(t.trp_line) - 1) AS trp_line_code,
            CASE RIGHT(t.trp_line, 1)
                WHEN 'A' THEN 'Outbound'
                WHEN 'R' THEN 'Return'
                ELSE 'n/a'
            END AS trp_dir,
            t.trp_stop,
            t.trp_veh,
            t.trp_dt,
            t.trp_pos,
            d.plan_arr,
            d.plan_dep,
            d.arr,
            d.dep,
            t.trp_status,
            DATEDIFF(second, d.arr, d.dep) AS trp_dwell_s,          -- derived measure: recomputed from the times
            DATEDIFF(second, d.plan_arr, d.arr) AS trp_delay_s,
            -- Counts only on operated stops; 9999 = counter overflow; a negative count is a sensor sign error
            CASE WHEN t.trp_status <> 'OPERATED' OR t.trp_board = 9999 THEN NULL ELSE ABS(t.trp_board) END AS trp_board,
            CASE WHEN t.trp_status <> 'OPERATED' OR t.trp_alight = 9999 THEN NULL ELSE ABS(t.trp_alight) END AS trp_alight
        FROM #trips t
        CROSS APPLY (
            -- 'HH:MM:SS' counted from the service day's midnight (HH goes past 24 after midnight) -> datetime
            SELECT
                DATEADD(second, CAST(LEFT(t.trp_plan_arr, 2) AS INT) * 3600 + CAST(SUBSTRING(t.trp_plan_arr, 4, 2) AS INT) * 60
                                + CAST(RIGHT(t.trp_plan_arr, 2) AS INT), CAST(t.trp_dt AS DATETIME2(0))) AS plan_arr,
                DATEADD(second, CAST(LEFT(t.trp_plan_dep, 2) AS INT) * 3600 + CAST(SUBSTRING(t.trp_plan_dep, 4, 2) AS INT) * 60
                                + CAST(RIGHT(t.trp_plan_dep, 2) AS INT), CAST(t.trp_dt AS DATETIME2(0))) AS plan_dep,
                DATEADD(second, CAST(LEFT(t.trp_arr, 2) AS INT) * 3600 + CAST(SUBSTRING(t.trp_arr, 4, 2) AS INT) * 60
                                + CAST(RIGHT(t.trp_arr, 2) AS INT), CAST(t.trp_dt AS DATETIME2(0))) AS arr,
                DATEADD(second, CAST(LEFT(t.trp_dep, 2) AS INT) * 3600 + CAST(SUBSTRING(t.trp_dep, 4, 2) AS INT) * 60
                                + CAST(RIGHT(t.trp_dep, 2) AS INT), CAST(t.trp_dt AS DATETIME2(0))) AS dep
        ) d;
        DROP TABLE #trips;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '==========================================';
        PRINT 'Loading Silver Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(second, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';
    END TRY
    BEGIN CATCH
        PRINT '==========================================';
        PRINT 'ERROR OCCURED DURING LOADING SILVER LAYER';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number: ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error State: ' + CAST(ERROR_STATE() AS NVARCHAR);
        PRINT '==========================================';
    END CATCH
END
GO
