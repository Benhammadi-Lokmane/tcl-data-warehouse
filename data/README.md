# Data

Lyon public transport network (TCL): stops, lines, vehicles and runs from 2026-09-06 to 2026-10-05.

All files are comma-separated, UTF-8, with a header row and a decimal point. An empty field means "unknown".
Datetimes are local Lyon time, without a time zone.

| File | One row = | Rows |
|---|---|---:|
| `stop.csv` | one platform (boarding point) | 9,788 |
| `line.csv` | one line in one direction | 1,586 |
| `line_stop.csv` | one stop of a line, with its position | 21,629 |
| `vehicle.csv` | one vehicle | 2,038 |
| `trip.csv` | one run stopping at one stop on one day | 12,138,673 |

## stop.csv
The network's platforms: `stop_id`, name, address, city and INSEE code, fare zone, wheelchair access,
the station grouping the platforms of one place (`station_id`) and GPS coordinates.

## line.csv
Each line in each direction. `line_id` = route code + `-O` (outbound) or `-R` (return).
Also: public code (`A`, `T1`, `C3`, `86`…), name, direction, destination, mode (metro, tram, trolleybus, bus,
funicular, river shuttle), category (regular, school, event…) and colour.

## line_stop.csv
The stops of each line and direction, in order: `position` 1 = first stop … n = terminus.

## vehicle.csv
The fleet: `vehicle_id` (fleet number), name, type, capacity, and whether the vehicle has an automatic
passenger counter (`has_passenger_counter`).

## trip.csv
What actually happened: each run (`trip_id`) of a vehicle at each stop, on each service day.

| Column | Meaning |
|---|---|
| `trip_id`, `service_date`, `position` | the run, its service day and the stop's position in the run (1 … n) |
| `stop_id`, `line_id`, `vehicle_id` | where, on which line, with which vehicle |
| `planned_arrival_datetime`, `planned_departure_datetime` | timetable times |
| `arrival_datetime`, `departure_datetime` | actual times recorded on board |
| `status` | `OPERATED`: the run stopped here normally · `CANCELLED`: the whole run did not run · `SKIPPED`: the run ran but did not serve this stop |
| `status_reason` | empty when `OPERATED`; otherwise `vehicle_breakdown`, `staff_shortage`, `works`, `traffic`, `event` or `weather` |
| `boardings`, `alightings` | passengers getting on / off, only for vehicles with a passenger counter |

`CANCELLED` rows keep the planned times but have no vehicle, actual times or passenger counts.
`SKIPPED` rows keep the planned times and the vehicle but have no actual times or passenger counts.
Runs after midnight belong to the previous service day.
This file is too large for GitHub and is not versioned.

## Relations
- `trip.stop_id` → `stop.stop_id`, `trip.line_id` → `line.line_id`, `trip.vehicle_id` → `vehicle.vehicle_id`
- `line_stop.line_id` → `line.line_id`, `line_stop.stop_id` → `stop.stop_id`

## Source
Stops, lines and timetables come from the open data published by SYTRAL Mobilités on
[data.grandlyon.com](https://data.grandlyon.com/portail/fr/accueil) (downloaded on 2026-10-06):
- [Horaires théoriques du réseau TCL](https://data.grandlyon.com/portail/fr/jeux-de-donnees/horaires-theoriques-reseau-transports-commun-lyonnais/info) (GTFS): lines, stop order, runs and planned times
- [Points d'arrêt du réseau TCL](https://data.grandlyon.com/portail/fr/jeux-de-donnees/points-arret-reseau-transports-commun-lyonnais/info): stops

Actual arrival / departure times, run statuses, vehicle assignments and passenger counts are not published as
open data: they are simulated on top of this timetable.
