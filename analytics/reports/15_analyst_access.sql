/*
===============================================================================
Analyst Access
===============================================================================
Purpose:
    - Create the 'analyst' database role and let it read the report views of the 'analytics' schema only.
    - Create a test user without login ('analyst_demo') to check the role (tests/quality_checks_analytics.sql).

How it works:
    - GRANT SELECT ON SCHEMA::analytics covers every current and future view of the schema.
    - The role gets nothing on bronze, silver or gold. The report views still work for it thanks to ownership
      chaining: the views and the gold tables have the same owner (dbo), so SQL Server checks the permission
      on the view only, not on the gold tables it reads.
    - A real analyst account is added to the role with:
          CREATE USER <name> FOR LOGIN <login>;
          ALTER ROLE analyst ADD MEMBER <name>;

SQL Functions Used:
    - DATABASE_PRINCIPAL_ID(), IS_ROLEMEMBER(), CREATE ROLE, CREATE USER ... WITHOUT LOGIN, ALTER ROLE, GRANT

Usage Notes:
    - Run after the report views (12 to 14). The script can be run again: it only creates what is missing.
===============================================================================
*/
USE TclDataWarehouse;
GO

-- Role for the analysts
IF DATABASE_PRINCIPAL_ID('analyst') IS NULL
    CREATE ROLE analyst;
GO

-- Read access to the report views only
GRANT SELECT ON SCHEMA::analytics TO analyst;
GO

-- Test user without login (cannot connect: only used with EXECUTE AS to check the role)
IF DATABASE_PRINCIPAL_ID('analyst_demo') IS NULL
    CREATE USER analyst_demo WITHOUT LOGIN;
GO

IF IS_ROLEMEMBER('analyst', 'analyst_demo') = 0
    ALTER ROLE analyst ADD MEMBER analyst_demo;
GO
