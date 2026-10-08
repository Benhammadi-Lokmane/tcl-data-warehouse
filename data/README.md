# Data

Lyon public transport network (TCL) from 2026-09-06 to 2026-10-05, as extracted from two source systems:
a **network reference system** (stops, lines, stop order) and an **operations & fleet system** (vehicles and what
actually happened on each run). Each system has its own conventions, and the same stop, line or vehicle is not
identified the same way in every file.

All files are comma-separated, UTF-8, with a header row. An empty field means "unknown" or "not applicable".
Dates are `YYYY-MM-DD`; times are local Lyon time.

## source_network/ — network reference system

Column names are lowercase, with one prefix per file.

| File | One row = |
|---|---|
| `stop.csv` | one stop record: a platform (boarding point) |
| `line.csv` | one version of a line in one direction |
| `line_stop.csv` | one stop of a line in one direction, with its position |

### stop.csv

| Column | Meaning |
|---|---|
| `stp_key` | stop |
| `stp_name`, `stp_address`, `stp_city` | name, street address and commune of the stop |
| `stp_zone` | fare zone |
| `stp_pmr` | wheelchair accessible |
| `stp_lat`, `stp_lon` | GPS coordinates (WGS 84) |
| `stp_update_dt` | date the record was last updated |

### line.csv

| Column | Meaning |
|---|---|
| `ln_key` | line |
| `ln_name` | line name (its termini) |
| `ln_dir` | direction |
| `ln_color` | line colour (hexadecimal RGB) |
| `ln_start_dt`, `ln_end_dt` | dates this version of the line was valid |

### line_stop.csv

| Column | Meaning |
|---|---|
| `ls_line`, `ls_dir` | line and direction |
| `ls_stop` | stop |
| `ls_pos` | position of the stop on the line: 1 = first stop … n = terminus |

## source_ops/ — operations & fleet system

Column names are uppercase and short.

| File | One row = |
|---|---|
| `mode_category.csv` | one combination of transport mode and line category |
| `vehicle.csv` | one version of a vehicle record |
| `trip.csv` | one run stopping at one stop on one service day |

### mode_category.csv

| Column | Meaning |
|---|---|
| `ID` | mode and category |
| `MODE` | metro, tram, trolleybus, bus, funicular, river shuttle |
| `CATEGORY` | regular, school, event, on-demand, replacement of a metro, tram or funicular line |

### vehicle.csv

| Column | Meaning |
|---|---|
| `VEH` | vehicle (fleet number) |
| `TYPE` | vehicle type |
| `CAP` | capacity (passengers) |
| `DEPOT` | depot the vehicle is attached to |
| `IN_SERVICE`, `OUT_SERVICE` | dates this version of the record was valid |

### trip.csv

| Column | Meaning |
|---|---|
| `TRP_RUN` | the run: one scheduled trip of a line, repeated on every day it operates |
| `TRP_LINE` | line and direction |
| `TRP_STOP` | stop |
| `TRP_VEH` | vehicle |
| `TRP_DT` | service day |
| `TRP_POS` | position of the stop in the run (1 … n) |
| `TRP_PLAN_ARR`, `TRP_PLAN_DEP` | timetable arrival and departure times (`HH:MM:SS`) |
| `TRP_ARR`, `TRP_DEP` | actual arrival and departure times recorded on board |
| `TRP_STATUS` | `OPERATED`: the run stopped here normally · `CANCELLED`: the whole run did not run · `SKIPPED`: the run ran but did not serve this stop |
| `TRP_DWELL_S` | seconds spent at the stop (departure − arrival) |
| `TRP_BOARD`, `TRP_ALIGHT` | passengers getting on / off, only for vehicles with an automatic passenger counter |

Times count from midnight of the service day: runs after midnight belong to the previous service day and go past
`24:00:00`. `CANCELLED` rows have no vehicle, actual times or passenger counts; `SKIPPED` rows keep the vehicle but
have no actual times or passenger counts.

## Relations

- `trip` → `stop`, `trip` → `line` (line and direction), `trip` → `vehicle`
- `line_stop` → `line` (line and direction), `line_stop` → `stop`
- `line` → `mode_category`

## Real and simulated data

**Real**, from the open data published by SYTRAL Mobilités on
[data.grandlyon.com](https://data.grandlyon.com/portail/fr/accueil) (downloaded on 2026-10-06):
stops (name, address, commune, fare zone, accessibility, coordinates), lines (codes, names, colours, modes,
categories), the order of stops, the timetable (runs, planned times, days of operation) and the traffic alerts
(stops not served, suspended lines). Days before 2026-10-06 use the published timetable of the same weekday.
- [Horaires théoriques du réseau TCL](https://data.grandlyon.com/portail/fr/jeux-de-donnees/horaires-theoriques-reseau-transports-commun-lyonnais/info) (GTFS)
- [Points d'arrêt du réseau TCL](https://data.grandlyon.com/portail/fr/jeux-de-donnees/points-arret-reseau-transports-commun-lyonnais/info)
- [Alertes trafic du réseau TCL](https://data.grandlyon.com/portail/fr/jeux-de-donnees/alertes-trafic-reseau-transports-commun-lyonnais-v2/info)
- [Positions en temps réel des véhicules TCL](https://data.grandlyon.com/portail/fr/jeux-de-donnees/positions-en-temps-reel-des-vehicules-du-reseau-des-transports-en-commun-lyonnais/info): vehicle numbers, and the delays the simulation is calibrated on

**Simulated**, because none of it is published as open data: actual arrival and departure times, cancelled runs and
skipped stops (driven by the real traffic alerts), the vehicle doing each run, the fleet (size, depots, capacities,
service dates), passenger counts, and the history of records (update dates, line and vehicle versions).

The CSV files are not versioned: `trip.csv` alone is too large for GitHub.
