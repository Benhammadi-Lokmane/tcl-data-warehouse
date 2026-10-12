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

## 2. Dimensions exploration

Source: `analytics/eda/02_dimensions_exploration.sql`

- **The network is mostly school buses:** of the 801 lines, 780 are bus lines and 589 (74 %) are School lines. Only
  205 are Regular (185 bus, 8 tram, 5 trolleybus, 4 metro, 2 funicular, 1 river shuttle). Unless rankings and
  averages by line are split by category, or limited to Regular lines, School services will dominate them. Each
  ranking must also name its unit: a line (`line_code`) or a line-direction (`line_key`).
- **City is unknown for 46 % of stops** (4,490 of 9,773), while every stop has a fare zone:
  - a breakdown by city covers only about half of the network;
  - fare zone is the complete geographic dimension.

  Wheelchair access is unknown for 25 % of stops, so accessibility shares must show that bucket, not drop it.
- **Statuses are counted in stop rows, not runs:** 464,281 operated, 4,373 cancelled and 3,292 skipped. So 1.6 % of
  planned stops were not served. Cancelled runs are counted in Task 4. The fleet has 2,036 vehicles (87 % buses) in
  15 depots.

## 3. Date range exploration

Source: `analytics/eda/03_date_range_exploration.sql`

- **A service day is longer than a calendar day:** the service day of Tuesday 2026-09-08 runs from 00:00 until 00:41
  the next day. Its last 1,218 passages (114 runs) are therefore dated 2026-09-09. Group by service day (`date_key`),
  never by the calendar date of `planned_arrival`. For hours, use a service hour from 0 to 24: `planned_hour` puts
  both midnights in hour 0.
- **There is a night pause and two peaks:**
  - no service between 01:42 and 04:12;
  - the busiest hours are 7–8 am (37,827 passages) and 5–6 pm (38,423);
  - the last actual arrival comes 129 s after the last planned one.
- **Fleet and line versions:** vehicles are 0 to 48 years old (9.0 on average, 6 with an unknown date; simulated).
  46 School lines got a new version on 2026-09-01, the start of the school year. Gold keeps only current versions, so
  there is no earlier version to compare them with.
