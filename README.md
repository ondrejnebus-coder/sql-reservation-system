# Reservation System - PostgreSQL

A relational database for a multi-branch reservation business (hotel, wellness,
personal training), built for the Database Systems course at FIIT STU.

## What it does

- Full schema for **users, roles, permissions, branches, employees, services,
  schedules, reservations and payments**.
- Role/permission model with junction tables.
- Indexes for the most common lookup paths.
- Two non-trivial SQL operations:
  - `create_reservation.sql` - validated insert that creates/reuses a user,
    checks availability, creates a reservation and a payment row.
  - `employee_schedule_week.sql` - weekly employee schedule with overrides.
- `seed.py` generates realistic test data with Faker (20 branches, services,
  employees, reservations, payments).

## Tech stack

- PostgreSQL (UUIDs, `TIMESTAMPTZ`, generated identity columns, CTEs)
- Python 3 + `psycopg2-binary` + `Faker` for seeding
- PlantUML for the data model

## Files

```
schema.sql                     tables, constraints, relationships
indexes.sql                    performance indexes
operations/                    CTE-based query operations
seed.py                        deterministic fake-data generator
dm_Rezervacny_system.puml      PlantUML data model
docs/er.png                    rendered ER diagram
```

## How to run

```bash
createdb reservations

psql -d reservations -f schema.sql
psql -d reservations -f indexes.sql

pip install -r requirements.txt
python seed.py --dsn "postgresql://postgres:postgres@localhost/reservations"

# example operation
psql -d reservations -f operations/create_reservation.sql
```

The operation files use positional parameters (`$1`, `$2`, ...); call them from
your application or wrap them in a prepared statement.

## What I learned

- Designing a normalized schema with real constraints and cascade rules.
- Writing complex CTE-based SQL that stays readable.
- Thinking about indexes and query plans.
- Generating reproducible test data for a non-trivial domain.

## Author

Ondrej Nebus — FIIT STU, 2025/26.
