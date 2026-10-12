# Analytics Insights

What the analytics scripts in `analytics/` found, task by task. Each insight names the script it comes from and its
limits.

> **Read this first.** Lines, stops, cities, stop order and the planned timetable come from TCL open data. **Delays,
> cancellations, skipped stops, vehicles and passenger counts are simulated.** The insights describe the analysis
> method, not the performance of the real TCL network. The warehouse currently holds **one service day
> (2026-09-08, a Tuesday)**, and passenger counts exist only for vehicles with a passenger counter (about 25 %).

## Business definitions

Used the same way in every script:

| Term | Definition |
|---|---|
| Delay | Actual arrival − planned arrival, in seconds, on operated stops only. |
| On time | Delay between −60 s and +180 s. |
| Late / Early | Delay > 180 s / delay < −60 s. |
| Line in difficulty | More than 20 % of its passages late over the period. |
| Cancellation rate | Cancelled runs / planned runs (runs, not stop rows). |
| Passenger measures | Computed on vehicles with a passenger counter only, and labelled as such. |

---

## 1. Database exploration

Source: `analytics/eda/01_database_exploration.sql`

- **What analysts can use:** 6 gold tables: 2 facts (`fact_trips`, `fact_line_stops`) and 4 dimensions (dates, lines,
  stops, vehicles). There are no analytics views yet. Dimension counts need care:
  - `dim_lines` (1,585 rows) holds one row per line and direction.
  - `dim_stops` (9,774) and `dim_vehicles` (2,037) each include one `n/a` member, so there are 9,773 stops and 2,036
    vehicles.
  - `dim_dates` is a calendar of 365 days, of which only one is a service day.
- **471,946 is not the number of runs:** one row of `fact_trips` is one run at one stop on one service day. Every
  count of runs must be made on (`run_id`, `date_key`), never with `COUNT(*)`.
- **The measures are nullable,** so `COUNT(*)`, `COUNT(column)` and `AVG(column)` answer different questions:
  - **Delay** is filled on 464,281 rows, the stops actually served.
  - **Boardings** are filled on 117,687 rows (about 25 %), the vehicles with a counter.
  - **Consequence:** `AVG` ignores NULLs, so an average delay covers served stops only, and a passenger average
    covers equipped vehicles only.

**Limits:**
- One service day, so no trends over days or weeks yet.
- No traffic alerts and no cancellation reason in the warehouse.
- `date_key` and `line_key` are nullable by design. They have no NULLs today, but joins should be checked again after
  each load.
