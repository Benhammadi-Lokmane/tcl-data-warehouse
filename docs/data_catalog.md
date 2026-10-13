# Data Catalog

This catalog describes the objects analysts can query:
- **Gold layer** (sections 1–6): the tables of the data model.
- **Analytics layer** (sections 7–9): the report views built on top of gold, the only objects most analysts need.

## Overview

The Gold Layer is the business-level data representation, structured to support analytical and reporting use cases.
It is a **fact constellation**: two fact tables share the same dimensions, so their keys can be combined.

![Gold layer data model](data_model.webp)

`fact_trips` links to the four dimensions; `fact_line_stops` shares `dim_lines` and `dim_stops` with it. The keys
shown in each table are its grain (what one row means). The gold objects are tables, created by
`scripts/gold/ddl_gold.sql` and reloaded from silver by `EXEC gold.load_gold;`. They have no foreign key constraints
(these would forbid the `TRUNCATE` of each load): the quality checks (`tests/quality_checks_gold.sql`) verify the
keys and relationships after every load.

Conventions:
- **Surrogate keys** (`*_key`) are generated at each load and link the facts to the dimensions.
- **Key 0** in `dim_stops` and `dim_vehicles` is the `n/a` member: a trip whose stop was not recorded, or that has no
  known vehicle, points to it instead of having no key.
- **Current version only**: lines and vehicles that changed over time (renamed, rerouted, moved to another depot,
  refitted) appear with their current attributes.
- `n/a` means unknown.

Indexing strategy:
- **Dimensions** (rowstore): a clustered primary key on the surrogate key, used to join from the facts, and a unique
  index on the business key, used to find the surrogate key when the facts are loaded.
- **`fact_trips`** (columnstore): a clustered columnstore index stores and compresses each column separately, so an
  aggregation (e.g. average delay by line) reads only the columns it uses. After each load, `gold.load_gold`
  compresses the rows still waiting in the delta store (`ALTER INDEX ... REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON)`).
- **`fact_line_stops`** (rowstore): small table, clustered primary key on its grain.

---

## 1. gold.dim_dates

- **Purpose:** Calendar of the years covered by the trips, one row per day, to analyse by day, week, month or year.
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| date_key | INT | Surrogate key of the day in the form yyyymmdd (e.g., 20260908). |
| full_date | DATE | The calendar date (e.g., 2026-09-08). |
| day | INT | Day of the month, 1 to 31. |
| day_name | VARCHAR(9) | Name of the day (e.g., 'Tuesday'). |
| day_of_week | INT | Day of the week, from 1 = Monday to 7 = Sunday. |
| is_weekend | VARCHAR(5) | 'true' on Saturdays and Sundays, 'false' otherwise. |
| week_of_year | INT | ISO week number, 1 to 53 (e.g., 37). |
| month | INT | Month number, 1 to 12. |
| month_name | VARCHAR(9) | Name of the month (e.g., 'September'). |
| quarter | INT | Quarter of the year, 1 to 4. |
| year | INT | Calendar year (e.g., 2026). |

- **Indexes:**

| Index Name | Type | Columns | Purpose |
|---|---|---|---|
| pk_dim_dates | Clustered, primary key | date_key | One row per day; joins from `fact_trips.date_key`. |
| ux_dim_dates_full_date | Nonclustered, unique | full_date | One row per calendar date; lookups and filters by date. |

## 2. gold.dim_lines

- **Purpose:** The lines of the network in each direction, with their transport mode and category.
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| line_key | INT | Surrogate key uniquely identifying a line in one direction. |
| line_code | VARCHAR(50) | Public code of the line, as shown to passengers (e.g., 'A', 'C1', 'JD346'). |
| direction | VARCHAR(50) | Direction of travel: 'Outbound' or 'Return'. |
| line_name | VARCHAR(100) | Name of the line, made of its termini (e.g., 'Perrache - Vaulx-en-Velin La Soie'). |
| color | VARCHAR(50) | Colour of the line on maps, as a hexadecimal RGB code (e.g., 'E8308A'). |
| mode | VARCHAR(50) | Transport mode: 'Metro', 'Tram', 'Trolleybus', 'Bus', 'Funicular' or 'River shuttle'. |
| category | VARCHAR(50) | Kind of service (e.g., 'Regular', 'School', 'Event', 'On-demand', 'Metro replacement'). |
| start_date | DATE | Date the current version of the line came into force. |

- **Indexes:**

| Index Name | Type | Columns | Purpose |
|---|---|---|---|
| pk_dim_lines | Clustered, primary key | line_key | One row per line and direction; joins from both facts. |
| ux_dim_lines_code_direction | Nonclustered, unique | line_code, direction | One row per business key; finds `line_key` when the facts are loaded. |

## 3. gold.dim_stops

- **Purpose:** The stops of the network (one row per platform, or boarding point), with their location and accessibility.
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| stop_key | INT | Surrogate key uniquely identifying a stop; 0 = unknown stop. |
| stop_id | INT | Identifier of the stop in the network's timetable (e.g., 12265); NULL only for the unknown stop. |
| stop_name | VARCHAR(100) | Name of the stop as shown to passengers (e.g., 'Gare de Vaise-G.Collomb'). |
| address | VARCHAR(100) | Street address of the stop; 'n/a' when not published. |
| city | VARCHAR(50) | Commune of the stop (e.g., 'Lyon 9e Arrondissement', 'Villeurbanne'); 'n/a' when not published. |
| fare_zone | VARCHAR(50) | Fare zone: 'Zone 1' to 'Zone 5', or 'Zone Externe' outside the zoned network. |
| wheelchair_accessible | VARCHAR(50) | Whether the stop is wheelchair accessible: 'true', 'false' or 'n/a' (unknown). |
| latitude | DECIMAL(9,6) | Latitude of the stop, WGS 84 (e.g., 45.780795). |
| longitude | DECIMAL(9,6) | Longitude of the stop, WGS 84 (e.g., 4.804658). |

- **Indexes:**

| Index Name | Type | Columns | Purpose |
|---|---|---|---|
| pk_dim_stops | Clustered, primary key | stop_key | One row per stop; joins from both facts. |
| ux_dim_stops_stop_id | Nonclustered, unique, filtered (`WHERE stop_id IS NOT NULL`) | stop_id | One row per business key, the unknown stop excluded; finds `stop_key` when the facts are loaded. |

## 4. gold.dim_vehicles

- **Purpose:** The fleet: every vehicle that can run on the network, with its type, capacity and depot.
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| vehicle_key | INT | Surrogate key uniquely identifying a vehicle; 0 = no vehicle or vehicle not in the fleet. |
| vehicle_id | VARCHAR(50) | Fleet number of the vehicle (e.g., '102', 'E157005'). |
| vehicle_type | VARCHAR(50) | Type of vehicle: 'Metro', 'Tram', 'Trolleybus', 'Bus', 'Funicular' or 'River shuttle'. |
| capacity | INT | Number of passengers the vehicle can carry (e.g., 200). |
| depot | VARCHAR(50) | Depot the vehicle is attached to (e.g., 'MEYZIEU'). |
| in_service_date | DATE | Date the vehicle first entered service; NULL when unknown. |

- **Indexes:**

| Index Name | Type | Columns | Purpose |
|---|---|---|---|
| pk_dim_vehicles | Clustered, primary key | vehicle_key | One row per vehicle; joins from `fact_trips.vehicle_key`. |
| ux_dim_vehicles_vehicle_id | Nonclustered, unique | vehicle_id | One row per business key; finds `vehicle_key` when the facts are loaded. |

## 5. gold.fact_trips

- **Purpose:** What actually happened on the network: one row per run stopping (or planned to stop) at one stop on one
  service day, with the planned and actual times, the delay and the passenger counts.
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| run_id | VARCHAR(100) | Identifier of the scheduled run, repeated on every day it operates. |
| stop_position | INT | Position of the stop in the run, from 1 = first stop to n = terminus. |
| date_key | INT | Surrogate key linking to the service day in `dim_dates`. A run after midnight belongs to the previous service day. |
| line_key | INT | Surrogate key linking to the line and direction in `dim_lines`. |
| stop_key | INT | Surrogate key linking to the stop in `dim_stops`. |
| vehicle_key | INT | Surrogate key linking to the vehicle in `dim_vehicles`; 0 when there is no known vehicle (cancelled run, or vehicle not in the fleet). |
| status | VARCHAR(50) | 'OPERATED': the run stopped here · 'CANCELLED': the whole run did not run · 'SKIPPED': the run did not serve this stop. |
| planned_arrival | DATETIME2(0) | Arrival time in the timetable (e.g., 2026-09-08 07:38:00). |
| planned_departure | DATETIME2(0) | Departure time in the timetable. |
| actual_arrival | DATETIME2(0) | Arrival time recorded on board; NULL when the stop was not served. |
| actual_departure | DATETIME2(0) | Departure time recorded on board; NULL when the stop was not served. |
| planned_hour | INT | Hour of the planned arrival, 0 to 23, to compare peak and off-peak hours. |
| delay_s | INT | Actual minus planned arrival, in seconds; negative when early (e.g., -40). NULL when the stop was not served. |
| dwell_s | INT | Time spent at the stop (actual departure minus actual arrival), in seconds. |
| boardings | INT | Passengers getting on at this stop; NULL when the vehicle has no passenger counter. |
| alightings | INT | Passengers getting off at this stop; NULL when the vehicle has no passenger counter. |

- **Indexes:**

| Index Name | Type | Columns | Purpose |
|---|---|---|---|
| cci_fact_trips | Clustered columnstore | all columns | Stores and compresses each column separately: aggregations over millions of rows read only the columns they use (about 4 times smaller than the uncompressed rows). Compressed after each load by `gold.load_gold`. |

  The grain (run_id, date_key, stop_position) has no primary key: a run whose service day could not be recovered has
  a NULL `date_key`. Its uniqueness is checked by `tests/quality_checks_gold.sql`.

## 6. gold.fact_line_stops

- **Purpose:** The route of each line: which stops it serves, in which order, in each direction. It has no measures
  and no dates.
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| line_key | INT | Surrogate key linking to the line and direction in `dim_lines`. |
| stop_key | INT | Surrogate key linking to the stop in `dim_stops`. |
| stop_position | INT | Position of the stop on the line, from 1 = first stop to n = terminus. |

- **Indexes:**

| Index Name | Type | Columns | Purpose |
|---|---|---|---|
| pk_fact_line_stops | Clustered, primary key | line_key, stop_position | One row per line, direction and position; reads a line's stops in order. |

---

# Analytics Layer: Report Views

## Overview

The `analytics` schema holds **views** built on the gold tables, with the business definitions already applied. They
are recalculated from gold on every query, so they are always as fresh as the last `EXEC gold.load_gold;`. The scripts
that create them are in `analytics/reports/`.

Business definitions used in every view:
- **Delay** = actual arrival − planned arrival, in seconds, on operated passages only.
- **On time** = delay between −60 s and +180 s · **late** = delay > 180 s · **early** = delay < −60 s.
- **Cancelled run** = a run whose passages are all cancelled. Rates are counted in runs, not passages.
- **Peak hours** = 07:00–08:59 and 16:00–18:59 of the service day; every other hour is off-peak.
- **Passenger measures** (`*_equipped`, `counted_passages`) only cover vehicles with a passenger counter (about a
  quarter of the fleet). NULL means nothing was counted, not zero passengers.
- **Simulated data:** delays, cancellations, skipped stops, vehicles and passenger counts are simulated; lines,
  stops and the planned timetable are real.

Each view keeps the `n/a` member of its dimension (stop 0, vehicle 0), so its totals equal the fact table. To count
only real stops or vehicles, filter it out with `stop_key <> 0` or `vehicle_key <> 0`.

**Access:**
- **The `analyst` role** has `SELECT` on the `analytics` schema only, which covers every current and future report
  view. It has no rights on bronze, silver or gold (`analytics/reports/15_analyst_access.sql`).
- **How the views still work:** the views and the gold tables have the same owner, so SQL Server checks the
  permission on the view only (ownership chaining).
- **Checks:** `tests/quality_checks_analytics.sql` checks the access, the completeness and the totals of every view
  against `gold.fact_trips`.

---

## 7. analytics.report_lines

- **Purpose:** One row per line (both directions together) with its volume, punctuality, peak penalty, passengers
  and segment. All 801 lines appear; the lines that did not run have 0 runs and NULL measures.
- **Source:** `analytics/reports/12_report_lines.sql`
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| line_code | VARCHAR(50) | Public code of the line (e.g., 'C5', 'T2'). |
| line_name | VARCHAR(100) | Name of the line, made of its termini. |
| mode | VARCHAR(50) | Transport mode (e.g., 'Bus', 'Tram', 'Metro'). |
| category | VARCHAR(50) | Kind of service (e.g., 'Regular', 'School', 'Event'). |
| directions | INT | Number of directions of the line in `dim_lines` (1 or 2). |
| planned_runs | INT | Runs in the timetable over the period. |
| operated_runs | INT | Runs with at least one operated passage. |
| cancelled_runs | INT | Runs whose passages were all cancelled. |
| cancellation_rate_pct | DECIMAL(5,2) | Cancelled runs / planned runs × 100. NULL when the line did not run. |
| planned_passages | INT | Passages (a run at a stop) in the timetable. |
| operated_passages | INT | Passages actually served. |
| skipped_passages | INT | Passages of operated runs that did not serve the stop. |
| avg_delay_s | DECIMAL(8,1) | Average delay of the operated passages, in seconds. |
| median_delay_s | DECIMAL(8,1) | Median delay (the typical passage), in seconds. |
| p95_delay_s | DECIMAL(8,1) | 95th percentile of the delay (the bad cases), in seconds. |
| on_time_pct | DECIMAL(5,1) | Share of operated passages on time (−60 to +180 s). |
| late_pct | DECIMAL(5,1) | Share of operated passages late (> 180 s). |
| early_pct | DECIMAL(5,1) | Share of operated passages early (< −60 s). |
| peak_late_pct | DECIMAL(5,1) | Late share during peak hours. |
| off_peak_late_pct | DECIMAL(5,1) | Late share outside peak hours. |
| peak_penalty_pts | DECIMAL(5,1) | `peak_late_pct` − `off_peak_late_pct`, in percentage points: how much worse the line gets at peak. |
| counted_passages | INT | Operated passages where boardings were counted (equipped vehicles). |
| boardings_equipped | INT | Passengers counted getting on (equipped vehicles only); NULL when nothing was counted. |
| alightings_equipped | INT | Passengers counted getting off (equipped vehicles only); NULL when nothing was counted. |
| boardings_per_counted_passage | DECIMAL(6,1) | Boardings / counted passages: demand that can be compared between lines. |
| first_service_date | DATE | First service day with a passage of the line. |
| last_service_date | DATE | Last service day with a passage of the line. |
| service_days | INT | Number of service days with a passage of the line. |
| is_rated | INT | 1 when the line is Regular with at least 20 operated runs (enough data to rate it), else 0. |
| punctuality_segment | VARCHAR(13) | 'Good' (late ≤ 10 %), 'Watch' (≤ 20 %), 'In difficulty' (> 20 %), or 'Not rated'. |
| is_in_difficulty | INT | 1 when the line is rated and more than 20 % of its passages are late. |
| is_priority | INT | 1 when the line is in difficulty and has at least the median volume of the rated lines. |

## 8. analytics.report_stops

- **Purpose:** One row per stop (a platform) with its location, the lines serving it, its service, punctuality,
  passengers, busiest hour and demand segment. All 9,774 rows of `dim_stops` appear (9,773 stops + the unknown stop).
- **Source:** `analytics/reports/13_report_stops.sql`
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| stop_key | INT | Surrogate key of the stop in `dim_stops`; 0 = unknown stop. |
| stop_id | INT | Identifier of the stop in the network's timetable; NULL for the unknown stop. |
| stop_name | VARCHAR(100) | Name of the stop. Several platforms of a station share the same name. |
| city | VARCHAR(50) | Commune of the stop; 'n/a' when not published (46 % of stops). |
| fare_zone | VARCHAR(50) | Fare zone ('Zone 1' to 'Zone 5', 'Zone Externe'). |
| wheelchair_accessible | VARCHAR(50) | 'true', 'false' or 'n/a' (unknown). |
| latitude | DECIMAL(9,6) | Latitude, WGS 84. |
| longitude | DECIMAL(9,6) | Longitude, WGS 84. |
| lines_serving | INT | Lines planned to stop here (from the routes in `fact_line_stops`). |
| modes_serving | VARCHAR(8000) | Modes of those lines, comma-separated (e.g., 'Bus, Metro'). |
| planned_passages | INT | Passages in the timetable at this stop. |
| operated_passages | INT | Passages actually served. |
| skipped_passages | INT | Passages of operated runs that did not serve the stop. |
| cancelled_passages | INT | Passages of cancelled runs. |
| avg_delay_s | DECIMAL(8,1) | Average delay of the operated passages, in seconds. |
| median_delay_s | DECIMAL(8,1) | Median delay of the operated passages, in seconds. |
| on_time_pct | DECIMAL(5,1) | Share of operated passages on time. |
| late_pct | DECIMAL(5,1) | Share of operated passages late. |
| counted_passages | INT | Operated passages where boardings were counted (equipped vehicles). |
| boardings_equipped | INT | Passengers counted getting on (equipped vehicles only); NULL when nothing was counted. |
| alightings_equipped | INT | Passengers counted getting off (equipped vehicles only); NULL when nothing was counted. |
| boardings_per_counted_passage | DECIMAL(6,1) | Boardings / counted passages. |
| busiest_service_hour | INT | Service hour (0 to 24, 24 = after midnight) with the most planned passages; the earliest on a tie. |
| busiest_hour_passages | INT | Planned passages during that hour. |
| demand_segment | VARCHAR(10) | Counted boardings over the period: 'High' (≥ 100), 'Medium' (20–99), 'Low' (< 20), 'No count' (served, but no equipped vehicle counted), 'Not served' (no operated passage), 'n/a' (unknown stop). |

## 9. analytics.report_vehicles

- **Purpose:** One row per vehicle with its fleet attributes, age, use, punctuality and passengers carried. All 2,037
  rows of `dim_vehicles` appear (2,036 vehicles + the `n/a` vehicle). Vehicles are simulated.
- **Source:** `analytics/reports/14_report_vehicles.sql`
- **Columns:**

| Column Name | Data Type | Description |
|---|---|---|
| vehicle_key | INT | Surrogate key of the vehicle in `dim_vehicles`; 0 = 'n/a' (cancelled runs and vehicles missing from the fleet). |
| vehicle_id | VARCHAR(50) | Fleet number of the vehicle. |
| vehicle_type | VARCHAR(50) | Type of vehicle (e.g., 'Bus', 'Tram'). |
| capacity | INT | Number of passengers the vehicle can carry. |
| depot | VARCHAR(50) | Depot the vehicle is attached to. |
| in_service_date | DATE | Date the vehicle first entered service; NULL when unknown. |
| age_years | INT | Age in whole years at the last service day; NULL when the date is unknown. |
| has_passenger_counter | INT | 1 when at least one passage of the vehicle was counted (boardings or alightings). |
| planned_runs | INT | Runs assigned to the vehicle (a run has a single vehicle). |
| operated_runs | INT | Runs with at least one operated passage. |
| cancelled_runs | INT | Cancelled runs. Cancelled runs have no vehicle, so they are all on the 'n/a' vehicle. |
| lines_served | INT | Number of distinct lines the vehicle ran on. |
| service_days | INT | Number of service days with a passage. |
| avg_daily_span_h | DECIMAL(4,1) | Hours from the first actual departure to the last actual arrival of a service day, averaged over its service days. |
| planned_passages | INT | Passages assigned to the vehicle. |
| operated_passages | INT | Passages actually served. |
| avg_delay_s | DECIMAL(8,1) | Average delay of the operated passages, in seconds. |
| on_time_pct | DECIMAL(5,1) | Share of operated passages on time. |
| late_pct | DECIMAL(5,1) | Share of operated passages late. |
| counted_passages | INT | Passages where boardings or alightings were counted. |
| boardings_equipped | INT | Passengers counted getting on; NULL for a vehicle without a counter. |
| alightings_equipped | INT | Passengers counted getting off; NULL for a vehicle without a counter. |
