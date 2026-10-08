/*
===============================================================================
DDL Script: Create Bronze Tables
===============================================================================
Script Purpose:
    This script creates tables in the 'bronze' schema, dropping existing tables
    if they already exist.
	  Run this script to re-define the DDL structure of 'bronze' Tables
    Bronze keeps the data as-is: a column is typed (INT, DATE) only when every
    value in the source file converts; otherwise it stays text (VARCHAR) and is
    cast in silver.
    Text is VARCHAR in the database's UTF-8 collation (see init_database.sql):
    load the files with BULK INSERT ... WITH (FORMAT = 'CSV', FIRSTROW = 2,
    CODEPAGE = 'RAW') so accents arrive intact.
===============================================================================
*/

USE TclDataWarehouse;
GO

-- source_network/line.csv
IF OBJECT_ID('bronze.network_lines','U') IS NOT NULL
    DROP TABLE bronze.network_lines;
GO

CREATE TABLE bronze.network_lines(
    ln_key      VARCHAR(50),
    ln_name     VARCHAR(100),
    ln_dir      VARCHAR(50),
    ln_color    VARCHAR(50),
    ln_start_dt DATE,
    ln_end_dt   DATE
);
GO

-- source_network/stop.csv
IF OBJECT_ID('bronze.network_stops','U') IS NOT NULL
    DROP TABLE bronze.network_stops;
GO

CREATE TABLE bronze.network_stops(
    stp_key       VARCHAR(50),
    stp_name      VARCHAR(100),
    stp_address   VARCHAR(100),
    stp_city      VARCHAR(50),
    stp_zone      VARCHAR(50),
    stp_pmr       VARCHAR(50),
    stp_lat       VARCHAR(50),
    stp_lon       VARCHAR(50),
    stp_update_dt DATE
);
GO

-- source_network/line_stop.csv
IF OBJECT_ID('bronze.network_line_stop','U') IS NOT NULL
    DROP TABLE bronze.network_line_stop;
GO

CREATE TABLE bronze.network_line_stop(
    ls_line VARCHAR(50),
    ls_dir  INT,
    ls_stop INT,
    ls_pos  INT
);
GO

-- source_ops/mode_category.csv
IF OBJECT_ID('bronze.ops_mode_category','U') IS NOT NULL
    DROP TABLE bronze.ops_mode_category;
GO

CREATE TABLE bronze.ops_mode_category(
    id       VARCHAR(50),
    mode     VARCHAR(50),
    category VARCHAR(50)
);
GO

-- source_ops/vehicle.csv
IF OBJECT_ID('bronze.ops_vehicles','U') IS NOT NULL
    DROP TABLE bronze.ops_vehicles;
GO

CREATE TABLE bronze.ops_vehicles(
    veh         VARCHAR(50),
    veh_type    VARCHAR(50),
    cap         INT,
    depot       VARCHAR(50),
    in_service  DATE,
    out_service DATE
);
GO

-- source_ops/trip.csv
IF OBJECT_ID('bronze.ops_trips','U') IS NOT NULL
    DROP TABLE bronze.ops_trips;
GO

CREATE TABLE bronze.ops_trips(
    trp_run      VARCHAR(100),
    trp_line     VARCHAR(50),
    trp_stop     INT,
    trp_veh      VARCHAR(50),
    trp_dt       INT,
    trp_pos      INT,
    trp_plan_arr VARCHAR(50),
    trp_plan_dep VARCHAR(50),
    trp_arr      VARCHAR(50),
    trp_dep      VARCHAR(50),
    trp_status   VARCHAR(50),
    trp_dwell_s  INT,
    trp_board    INT,
    trp_alight   INT
);
GO
