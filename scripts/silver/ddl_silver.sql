/*
===============================================================================
DDL Script: Create Silver Tables
===============================================================================
Script Purpose:
    This script creates tables in the 'silver' schema, dropping existing tables
    if they already exist.
	  Run this script to re-define the DDL structure of 'silver' Tables
    Compared with bronze: real types (DATE, DECIMAL, DATETIME2), derived columns
    used to join the two source systems, and dwh_create_date (load time).
    Original key columns are kept next to the derived ones for traceability.
===============================================================================
*/

USE TclDataWarehouse;
GO

-- from bronze.network_stops
IF OBJECT_ID('silver.network_stops','U') IS NOT NULL
    DROP TABLE silver.network_stops;
GO

CREATE TABLE silver.network_stops(
    stp_id          INT,            -- derived: stop id used by line_stop and trips
    stp_key         VARCHAR(50),
    stp_name        VARCHAR(100),
    stp_address     VARCHAR(100),
    stp_city        VARCHAR(50),
    stp_zone        VARCHAR(50),
    stp_pmr         VARCHAR(50),
    stp_lat         DECIMAL(9,6),
    stp_lon         DECIMAL(9,6),
    stp_update_dt   DATE,
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

-- from bronze.network_lines
IF OBJECT_ID('silver.network_lines','U') IS NOT NULL
    DROP TABLE silver.network_lines;
GO

CREATE TABLE silver.network_lines(
    ln_key          VARCHAR(50),
    ln_code         VARCHAR(50),    -- derived: line code used by line_stop and trips
    ln_mode_cat_id  VARCHAR(50),    -- derived: id used by mode_category
    ln_name         VARCHAR(100),
    ln_dir          VARCHAR(50),    -- standardised direction
    ln_color        VARCHAR(50),
    ln_start_dt     DATE,
    ln_end_dt       DATE,           -- rebuilt from the next version
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

-- from bronze.network_line_stop
IF OBJECT_ID('silver.network_line_stop','U') IS NOT NULL
    DROP TABLE silver.network_line_stop;
GO

CREATE TABLE silver.network_line_stop(
    ls_line         VARCHAR(50),
    ls_dir          VARCHAR(50),    -- same direction coding as silver.network_lines
    ls_stop         INT,
    ls_pos          INT,
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

-- from bronze.ops_mode_category
IF OBJECT_ID('silver.ops_mode_category','U') IS NOT NULL
    DROP TABLE silver.ops_mode_category;
GO

CREATE TABLE silver.ops_mode_category(
    id              VARCHAR(50),
    mode            VARCHAR(50),
    category        VARCHAR(50),
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

-- from bronze.ops_vehicles
IF OBJECT_ID('silver.ops_vehicles','U') IS NOT NULL
    DROP TABLE silver.ops_vehicles;
GO

CREATE TABLE silver.ops_vehicles(
    veh_id          VARCHAR(50),    -- derived: vehicle number used by trips
    veh             VARCHAR(50),
    veh_type        VARCHAR(50),
    cap             INT,
    depot           VARCHAR(50),
    in_service      DATE,
    out_service     DATE,           -- rebuilt from the next version
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

-- from bronze.ops_trips
IF OBJECT_ID('silver.ops_trips','U') IS NOT NULL
    DROP TABLE silver.ops_trips;
GO

CREATE TABLE silver.ops_trips(
    trp_run         VARCHAR(100),
    trp_line        VARCHAR(50),
    trp_line_code   VARCHAR(50),    -- derived: line code
    trp_dir         VARCHAR(50),    -- derived: same direction coding as silver.network_lines
    trp_stop        INT,
    trp_veh         VARCHAR(50),
    trp_dt          DATE,           -- service day
    trp_pos         INT,
    trp_plan_arr    DATETIME2(0),   -- service day + time (runs after midnight fall on the next calendar day)
    trp_plan_dep    DATETIME2(0),
    trp_arr         DATETIME2(0),
    trp_dep         DATETIME2(0),
    trp_status      VARCHAR(50),
    trp_dwell_s     INT,
    trp_delay_s     INT,            -- derived: actual - planned arrival, in seconds
    trp_board       INT,
    trp_alight      INT,
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO
