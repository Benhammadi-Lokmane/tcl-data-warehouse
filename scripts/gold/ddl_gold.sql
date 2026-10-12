/*
===============================================================================
DDL Script: Create Gold Tables
===============================================================================
Script Purpose:
    This script creates the tables of the Gold layer, dropping existing tables
    (or the views of an earlier version) if they already exist.
	  Run this script to re-define the DDL structure of 'gold' Tables

    The Gold layer is a fact constellation: two facts share the same (conformed)
    dimensions.
        fact_trips      -> dim_dates, dim_lines, dim_stops, dim_vehicles
        fact_line_stops -> dim_lines, dim_stops

    Indexes:
    - Dimensions: clustered primary key on the surrogate key, unique index on the
      business key (used to look up keys when the facts are loaded).
    - fact_trips: clustered columnstore index, compressed by column, for fast
      aggregations over millions of rows (delays, counts by line, day, hour...).
    - fact_line_stops: small table, clustered primary key on its grain.
    No foreign key constraints: they would forbid TRUNCATE during each load.
    Relationships are verified by tests/quality_checks_gold.sql.

    Tables are filled by the procedure gold.load_gold (scripts/gold/proc_load_gold.sql).
===============================================================================
*/
USE TclDataWarehouse;
GO

-- Creating a filtered index (gold.dim_stops) requires QUOTED_IDENTIFIER ON; sqlcmd uses OFF by default
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =============================================================================
-- Create Dimension: gold.dim_dates
-- =============================================================================
IF OBJECT_ID('gold.dim_dates', 'U') IS NOT NULL
    DROP TABLE gold.dim_dates;
GO

CREATE TABLE gold.dim_dates (
    date_key        INT          NOT NULL,   -- yyyymmdd, e.g. 20260908
    full_date       DATE         NOT NULL,
    day             INT          NOT NULL,
    day_name        VARCHAR(9)   NOT NULL,
    day_of_week     INT          NOT NULL,   -- 1 = Monday ... 7 = Sunday
    is_weekend      VARCHAR(5)   NOT NULL,
    week_of_year    INT          NOT NULL,
    month           INT          NOT NULL,
    month_name      VARCHAR(9)   NOT NULL,
    quarter         INT          NOT NULL,
    year            INT          NOT NULL,
    CONSTRAINT pk_dim_dates PRIMARY KEY CLUSTERED (date_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_dates_full_date ON gold.dim_dates (full_date);
GO

-- =============================================================================
-- Create Dimension: gold.dim_lines
-- =============================================================================
IF OBJECT_ID('gold.dim_lines', 'U') IS NOT NULL
    DROP TABLE gold.dim_lines;
GO

CREATE TABLE gold.dim_lines (
    line_key        INT           NOT NULL,
    line_code       VARCHAR(50)   NOT NULL,
    direction       VARCHAR(50)   NOT NULL,
    line_name       VARCHAR(100)  NULL,
    color           VARCHAR(50)   NULL,
    mode            VARCHAR(50)   NOT NULL,
    category        VARCHAR(50)   NOT NULL,
    start_date      DATE          NULL,
    CONSTRAINT pk_dim_lines PRIMARY KEY CLUSTERED (line_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_lines_code_direction ON gold.dim_lines (line_code, direction);
GO

-- =============================================================================
-- Create Dimension: gold.dim_stops
-- =============================================================================
IF OBJECT_ID('gold.dim_stops', 'U') IS NOT NULL
    DROP TABLE gold.dim_stops;
GO

CREATE TABLE gold.dim_stops (
    stop_key              INT            NOT NULL,   -- 0 = 'n/a' member
    stop_id               INT            NULL,       -- NULL only for the 'n/a' member
    stop_name             VARCHAR(100)   NULL,
    address               VARCHAR(100)   NULL,
    city                  VARCHAR(50)    NULL,
    fare_zone             VARCHAR(50)    NULL,
    wheelchair_accessible VARCHAR(50)    NULL,
    latitude              DECIMAL(9,6)   NULL,
    longitude             DECIMAL(9,6)   NULL,
    CONSTRAINT pk_dim_stops PRIMARY KEY CLUSTERED (stop_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_stops_stop_id ON gold.dim_stops (stop_id) WHERE stop_id IS NOT NULL;
GO

-- =============================================================================
-- Create Dimension: gold.dim_vehicles
-- =============================================================================
IF OBJECT_ID('gold.dim_vehicles', 'U') IS NOT NULL
    DROP TABLE gold.dim_vehicles;
GO

CREATE TABLE gold.dim_vehicles (
    vehicle_key     INT           NOT NULL,   -- 0 = 'n/a' member
    vehicle_id      VARCHAR(50)   NOT NULL,
    vehicle_type    VARCHAR(50)   NOT NULL,
    capacity        INT           NULL,
    depot           VARCHAR(50)   NULL,
    in_service_date DATE          NULL,
    CONSTRAINT pk_dim_vehicles PRIMARY KEY CLUSTERED (vehicle_key)
);
CREATE UNIQUE NONCLUSTERED INDEX ux_dim_vehicles_vehicle_id ON gold.dim_vehicles (vehicle_id);
GO

-- =============================================================================
-- Create Fact Table: gold.fact_trips
-- =============================================================================
IF OBJECT_ID('gold.fact_trips', 'U') IS NOT NULL
    DROP TABLE gold.fact_trips;
GO

CREATE TABLE gold.fact_trips (
    run_id            VARCHAR(100)  NOT NULL,
    stop_position     INT           NOT NULL,
    date_key          INT           NULL,
    line_key          INT           NULL,
    stop_key          INT           NOT NULL,
    vehicle_key       INT           NOT NULL,
    status            VARCHAR(50)   NOT NULL,
    planned_arrival   DATETIME2(0)  NULL,
    planned_departure DATETIME2(0)  NULL,
    actual_arrival    DATETIME2(0)  NULL,
    actual_departure  DATETIME2(0)  NULL,
    planned_hour      INT           NULL,
    delay_s           INT           NULL,
    dwell_s           INT           NULL,
    boardings         INT           NULL,
    alightings        INT           NULL
);
-- Columnstore: each column stored and compressed separately, so aggregations read only the columns they use
CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_trips ON gold.fact_trips;
GO

-- =============================================================================
-- Create Fact Table: gold.fact_line_stops (route structure: no measures, no dates)
-- =============================================================================
IF OBJECT_ID('gold.fact_line_stops', 'U') IS NOT NULL
    DROP TABLE gold.fact_line_stops;
GO

CREATE TABLE gold.fact_line_stops (
    line_key        INT   NOT NULL,
    stop_key        INT   NOT NULL,
    stop_position   INT   NOT NULL,
    CONSTRAINT pk_fact_line_stops PRIMARY KEY CLUSTERED (line_key, stop_position)
);
GO
