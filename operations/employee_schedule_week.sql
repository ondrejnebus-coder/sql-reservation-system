-- ============================================================
-- Employee Weekly Schedule — Time Window Generator
-- ============================================================
-- Parameters:
--   $1  employee_id   integer      — employee whose schedule we want to see
--   $2  week_start    date         — any date within the week to query (week defined as Monday-Sunday)
--
-- Output columns:
--   slot_date       date        — calendar date of the slot
--   day_of_week     int         — 0=Mon … 6=Sun
--   slot_start      timestamptz — slot window start
--   slot_end        timestamptz — slot window end
--   slot_minutes    int         — slot duration in minutes
--   status          text        — 'free' | 'busy' | 'override_closed' | 'override_open'
--   reservation_id  uuid        — populated when status = 'busy'
--   service_name    text        — populated when status = 'busy'
--   override_note   text        — populated when an override applies
-- ============================================================

WITH

-- ── 0. resolve the employee's branch ────────────────────────────────────────
emp AS (
    SELECT
        be.id        AS employee_id,
        be.branch_id,
        be.is_active
    FROM branch_employee be
    WHERE be.id = $1
),

-- ── 1. week days: Monday … Sunday ───────────────────────────────────────────
week_days AS (
    SELECT
        d::date                              AS slot_date,
        (EXTRACT(ISODOW FROM d)::int - 1)   AS day_of_week   -- 0=Mon … 6=Sun
    FROM generate_series(
        $2::date,
        $2::date + '6 days'::interval,
        '1 day'::interval
    ) d
),

-- ── 2. branch schedule rows active this week ─────────────────────────────────
applicable_schedule AS (
    SELECT
        wd.slot_date,
        wd.day_of_week,
        bs.opening_time,
        bs.closing_time,
        bs.interval_minutes
    FROM week_days wd
    CROSS JOIN emp e
    JOIN branch_schedule bs
        ON  bs.branch_id   = e.branch_id
        AND bs.day_of_week = wd.day_of_week
        AND bs.is_active   = TRUE
),

-- ── 3. explode each working day into interval-sized slots ────────────────────
raw_slots AS (
    SELECT
        s.slot_date,
        s.day_of_week,
        s.interval_minutes,
        (s.slot_date + s.opening_time::time)::timestamptz
            + (n * s.interval_minutes * '1 minute'::interval)   AS slot_start,
        (s.slot_date + s.opening_time::time)::timestamptz
            + ((n + 1) * s.interval_minutes * '1 minute'::interval) AS slot_end
    FROM applicable_schedule s
    CROSS JOIN LATERAL generate_series(
        0,
        FLOOR(
            EXTRACT(EPOCH FROM (
                (s.slot_date + s.closing_time::time)::timestamptz
              - (s.slot_date + s.opening_time::time)::timestamptz
            )) / (s.interval_minutes * 60)
        )::int - 1
    ) AS n
    -- guard: drop slots whose end exceeds closing time
    WHERE (s.slot_date + s.opening_time::time)::timestamptz
              + ((n + 1) * s.interval_minutes * '1 minute'::interval)
          <= (s.slot_date + s.closing_time::time)::timestamptz
),

-- ── 4. overrides covering this week (branch-wide or employee-specific) ───────
week_overrides AS (
    SELECT
        so.id          AS override_id,
        so.start_time,
        so.end_time,
        so.is_open
    FROM schedule_override so
    CROSS JOIN emp e
    WHERE so.branch_id = e.branch_id
      AND (so.employee_id IS NULL OR so.employee_id = e.employee_id)
      AND so.start_time < ($2::date + '7 days'::interval)::timestamptz
      AND so.end_time   > $2::date::timestamptz
),

-- ── 5. non-canceled reservations for this employee this week ─────────────────
busy_reservations AS (
    SELECT
        r.id           AS reservation_id,
        r.start_time,
        r.end_time,
        svc.name       AS service_name
    FROM reservation r
    CROSS JOIN emp e
    LEFT JOIN service svc ON svc.id = r.service_id
    WHERE r.employee_id = e.employee_id
      AND r.status      != 3   -- exclude canceled
      AND r.start_time  < ($2::date + '7 days'::interval)::timestamptz
      AND r.end_time    > $2::date::timestamptz
),

-- ── 6. classify every slot ───────────────────────────────────────────────────
classified AS (
    SELECT
        rs.slot_date,
        rs.day_of_week,
        rs.slot_start,
        rs.slot_end,
        rs.interval_minutes AS slot_minutes,
        ov.is_open          AS override_is_open,
        ov.override_id,
        br.reservation_id,
        br.service_name
    FROM raw_slots rs

    -- first override that fully covers this slot (branch-wide wins)
    LEFT JOIN LATERAL (
        SELECT o.override_id, o.is_open
        FROM week_overrides o
        WHERE o.start_time <= rs.slot_start
          AND o.end_time   >= rs.slot_end
        ORDER BY o.override_id
        LIMIT 1
    ) ov ON TRUE

    -- first reservation overlapping this slot
    LEFT JOIN LATERAL (
        SELECT b.reservation_id, b.service_name
        FROM busy_reservations b
        WHERE b.start_time < rs.slot_end
          AND b.end_time   > rs.slot_start
        LIMIT 1
    ) br ON TRUE
)

-- ── 7. final result ──────────────────────────────────────────────────────────
SELECT
    slot_date,
    day_of_week,
    slot_start,
    slot_end,
    slot_minutes,

    CASE
        WHEN override_id IS NOT NULL AND NOT override_is_open THEN 'override_closed'
        WHEN override_id IS NOT NULL AND     override_is_open THEN 'override_open'
        WHEN reservation_id IS NOT NULL                       THEN 'busy'
        ELSE                                                       'free'
    END                 AS status,

    reservation_id,
    service_name,

    CASE
        WHEN override_id IS NOT NULL AND NOT override_is_open THEN 'Branch/employee closed (override)'
        WHEN override_id IS NOT NULL AND     override_is_open THEN 'Special opening (override)'
        ELSE NULL
    END                 AS override_note

FROM classified
ORDER BY slot_start;
