/*
===============================================================================
Create Database and Schemas (SQL Server)
===============================================================================
Script Purpose:
    This script drops the 'TclDataWarehouse' database if it exists, recreates it,
    and creates the three layer schemas: 'bronze', 'silver' and 'gold'.

How to run (from the repo root, once the container is healthy):
    docker compose cp scripts/init_database.sql sqlserver:/tmp/init_database.sql
    docker compose exec sqlserver sh -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -i /tmp/init_database.sql'

WARNING:
    Running this script drops the entire 'TclDataWarehouse' database if it exists.
    All data in the database will be permanently deleted.
===============================================================================
*/

USE master;
GO

-- Drop the 'TclDataWarehouse' database if it exists (closing open connections first)
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TclDataWarehouse')
BEGIN
    ALTER DATABASE TclDataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TclDataWarehouse;
END;
GO

-- Create the 'TclDataWarehouse' database
-- UTF-8 collation: VARCHAR columns store the UTF-8 source files as-is (accents, ’, £). On Linux, BULK INSERT
-- cannot convert code pages (only CODEPAGE = 'RAW' is allowed), so the raw UTF-8 bytes must land in UTF-8 columns.
CREATE DATABASE TclDataWarehouse COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO

USE TclDataWarehouse;
GO

-- Create Schemas (CREATE SCHEMA must be the only statement in its batch)
CREATE SCHEMA bronze;
GO

CREATE SCHEMA silver;
GO

CREATE SCHEMA gold;
GO
