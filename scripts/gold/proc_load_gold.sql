/*
===============================================================================
Stored Procedure: Load Gold Layer (Silver -> Gold)
===============================================================================
Script Purpose:
    This stored procedure populates the 'gold' schema tables (star schema / fact
    constellation) from the 'silver' schema.
	Actions Performed:
		- Truncates Gold tables.
		- Loads the dimensions first (surrogate keys + 'n/a' members), then the
		  facts, which look up their keys in the dimensions.

    Surrogate keys are ROW_NUMBER() over a unique order, recomputed at each load.
    Key 0 is the 'n/a' member: a fact row whose stop or vehicle is unknown points to it.

Parameters:
    None.
	  This stored procedure does not accept any parameters or return any values.

Usage Example:
    EXEC gold.load_gold;
===============================================================================
*/
USE TclDataWarehouse;
GO

-- Stored with the procedure: inserting into a table with a filtered index (gold.dim_stops) requires
-- QUOTED_IDENTIFIER ON, and sqlcmd uses OFF by default
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE gold.load_gold AS
BEGIN
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;
    BEGIN TRY
        SET @batch_start_time = GETDATE();
        PRINT '================================================';
        PRINT 'Loading Gold Layer';
        PRINT '================================================';

        PRINT '------------------------------------------------';
        PRINT 'Loading Dimensions';
        PRINT '------------------------------------------------';

        -- Loading gold.dim_dates
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.dim_dates';
        TRUNCATE TABLE gold.dim_dates;
        PRINT '>> Inserting Data Into: gold.dim_dates';
        WITH bounds AS (
            -- Whole calendar years covering the service days loaded in silver
            SELECT
                DATEFROMPARTS(YEAR(MIN(trp_dt)), 1, 1)   AS first_day,
                DATEFROMPARTS(YEAR(MAX(trp_dt)), 12, 31) AS last_day
            FROM silver.ops_trips
        ), calendar AS (
            SELECT
                DATEADD(day, s.value, b.first_day) AS full_date
            FROM bounds b
            CROSS APPLY GENERATE_SERIES(0, DATEDIFF(day, b.first_day, b.last_day)) AS s
        )
        INSERT INTO gold.dim_dates (
            date_key,
            full_date,
            day,
            day_name,
            day_of_week,
            is_weekend,
            week_of_year,
            month,
            month_name,
            quarter,
            year
        )
        SELECT
            CAST(CONVERT(CHAR(8), full_date, 112) AS INT)  AS date_key,      -- yyyymmdd
            full_date,
            DAY(full_date)                                 AS day,
            -- Monday = 1 ... Sunday = 7, whatever the session's language or DATEFIRST (1900-01-01 was a Monday)
            CHOOSE(DATEDIFF(day, '19000101', full_date) % 7 + 1,
                   'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday') AS day_name,
            DATEDIFF(day, '19000101', full_date) % 7 + 1   AS day_of_week,
            CASE
                WHEN DATEDIFF(day, '19000101', full_date) % 7 + 1 IN (6, 7) THEN 'true'
                ELSE 'false'
            END                                            AS is_weekend,
            DATEPART(iso_week, full_date)                  AS week_of_year,
            MONTH(full_date)                               AS month,
            CHOOSE(MONTH(full_date),
                   'January', 'February', 'March', 'April', 'May', 'June',
                   'July', 'August', 'September', 'October', 'November', 'December') AS month_name,
            DATEPART(quarter, full_date)                   AS quarter,
            YEAR(full_date)                                AS year
        FROM calendar;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading gold.dim_lines
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.dim_lines';
        TRUNCATE TABLE gold.dim_lines;
        PRINT '>> Inserting Data Into: gold.dim_lines';
        INSERT INTO gold.dim_lines (
            line_key,
            line_code,
            direction,
            line_name,
            color,
            mode,
            category,
            start_date
        )
        SELECT
            ROW_NUMBER() OVER (ORDER BY ln.ln_code, ln.ln_dir) AS line_key,  -- Surrogate key
            ln.ln_code,
            ln.ln_dir,
            ln.ln_name,
            ln.ln_color,
            COALESCE(mc.mode, 'n/a'),
            COALESCE(mc.category, 'n/a'),
            ln.ln_start_dt                                                   -- start of the current version
        FROM silver.network_lines ln
        LEFT JOIN silver.ops_mode_category mc
            ON ln.ln_mode_cat_id = mc.id
        WHERE ln.ln_end_dt IS NULL; -- Current version only: no history in gold
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading gold.dim_stops
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.dim_stops';
        TRUNCATE TABLE gold.dim_stops;
        PRINT '>> Inserting Data Into: gold.dim_stops';
        INSERT INTO gold.dim_stops (
            stop_key,
            stop_id,
            stop_name,
            address,
            city,
            fare_zone,
            wheelchair_accessible,
            latitude,
            longitude
        )
        SELECT 0, NULL, 'n/a', 'n/a', 'n/a', 'n/a', 'n/a', NULL, NULL   -- 'n/a' member: trips whose stop was not recorded
        UNION ALL
        SELECT
            ROW_NUMBER() OVER (ORDER BY stp_id) AS stop_key,                 -- Surrogate key
            stp_id,
            stp_name,
            stp_address,
            stp_city,
            stp_zone,
            stp_pmr,
            stp_lat,
            stp_lon
        FROM silver.network_stops;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading gold.dim_vehicles
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.dim_vehicles';
        TRUNCATE TABLE gold.dim_vehicles;
        PRINT '>> Inserting Data Into: gold.dim_vehicles';
        INSERT INTO gold.dim_vehicles (
            vehicle_key,
            vehicle_id,
            vehicle_type,
            capacity,
            depot,
            in_service_date
        )
        SELECT 0, 'n/a', 'n/a', NULL, 'n/a', NULL   -- 'n/a' member: no vehicle (cancelled run) or vehicle missing from the fleet
        UNION ALL
        SELECT
            ROW_NUMBER() OVER (ORDER BY LEN(veh_id), veh_id) AS vehicle_key,  -- Surrogate key (numbers in numeric order)
            veh_id,
            veh_type,
            cap,
            depot,
            first_in_service                    -- first entry into service, over all versions of the vehicle
        FROM (
            SELECT
                *,
                MIN(in_service) OVER (PARTITION BY veh_id) AS first_in_service
            FROM silver.ops_vehicles
        ) v
        WHERE out_service IS NULL; -- Current version only: no history in gold
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        PRINT '------------------------------------------------';
        PRINT 'Loading Facts';
        PRINT '------------------------------------------------';

        -- Loading gold.fact_trips
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.fact_trips';
        TRUNCATE TABLE gold.fact_trips;
        PRINT '>> Inserting Data Into: gold.fact_trips';
        INSERT INTO gold.fact_trips WITH (TABLOCK) (    -- TABLOCK: parallel bulk insert (compressed directly only from 102,400 rows per thread)
            run_id,
            stop_position,
            date_key,
            line_key,
            stop_key,
            vehicle_key,
            status,
            planned_arrival,
            planned_departure,
            actual_arrival,
            actual_departure,
            planned_hour,
            delay_s,
            dwell_s,
            boardings,
            alightings
        )
        SELECT
            t.trp_run,
            t.trp_pos,
            CAST(CONVERT(CHAR(8), t.trp_dt, 112) AS INT),     -- service day (a run after midnight belongs to the day before)
            ln.line_key,
            COALESCE(st.stop_key, 0),
            COALESCE(ve.vehicle_key, 0),
            t.trp_status,
            t.trp_plan_arr,
            t.trp_plan_dep,
            t.trp_arr,
            t.trp_dep,
            DATEPART(hour, t.trp_plan_arr),                   -- clock hour 0-23, for peak / off-peak analysis
            t.trp_delay_s,
            t.trp_dwell_s,
            t.trp_board,
            t.trp_alight
        FROM silver.ops_trips t
        LEFT JOIN gold.dim_lines ln
            ON t.trp_line_code = ln.line_code
           AND t.trp_dir = ln.direction
        LEFT JOIN gold.dim_stops st
            ON t.trp_stop = st.stop_id
        LEFT JOIN gold.dim_vehicles ve
            ON t.trp_veh = ve.vehicle_id;
        -- Rows a thread inserted below 102,400 stay uncompressed in the delta store: compress them now
        PRINT '>> Compressing Columnstore: gold.fact_trips';
        ALTER INDEX cci_fact_trips ON gold.fact_trips REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        -- Loading gold.fact_line_stops
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.fact_line_stops';
        TRUNCATE TABLE gold.fact_line_stops;
        PRINT '>> Inserting Data Into: gold.fact_line_stops';
        INSERT INTO gold.fact_line_stops (
            line_key,
            stop_key,
            stop_position
        )
        SELECT
            ln.line_key,
            COALESCE(st.stop_key, 0),
            ls.ls_pos
        FROM silver.network_line_stop ls
        JOIN gold.dim_lines ln                  -- every line of line_stop exists in dim_lines (checked in silver)
            ON ls.ls_line = ln.line_code
           AND ls.ls_dir = ln.direction
        LEFT JOIN gold.dim_stops st
            ON ls.ls_stop = st.stop_id;
        SET @end_time = GETDATE();
        PRINT '>> Load Duration: ' + CAST(DATEDIFF(second, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '==========================================';
        PRINT 'Loading Gold Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(second, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';
    END TRY
    BEGIN CATCH
        PRINT '==========================================';
        PRINT 'ERROR OCCURED DURING LOADING GOLD LAYER';
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT 'Error Number: ' + CAST(ERROR_NUMBER() AS NVARCHAR);
        PRINT 'Error State: ' + CAST(ERROR_STATE() AS NVARCHAR);
        PRINT '==========================================';
    END CATCH
END
GO
