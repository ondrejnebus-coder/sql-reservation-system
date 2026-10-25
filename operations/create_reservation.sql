-- ============================================================
-- Create Reservation — Validated Insert
-- ============================================================
-- Parameters:
--   $1  email         varchar      — email of the user making the reservation
--   $2  name          varchar      — name of the user (used if new user is created)
--   $3  service_id   integer      — service being booked
--   $4  employee_id  integer      — employee performing the service (nullable)
--   $5  start_time   timestamptz  — requested slot start
--   $6  amount       integer      — number of seats/participants (default 1)
--   $7  note         text         — optional note (nullable)
--
-- Returns one row:
--   result          text  — 'ok' or an error reason
--   reservation_id  uuid  — set on success, NULL on failure
--   payment_id      uuid  — set on success, NULL on failure
-- ============================================================

WITH

reservation_user AS (
  INSERT INTO "user" (email, name)
  VALUES ($1::varchar, $2::varchar)
  ON CONFLICT (email) DO UPDATE
    SET updated_at = NOW()
  RETURNING id
),

-- ── 0. load service details ──────────────────────────────────────────────────
svc AS (
    SELECT
        s.id,
        s.branch_id,
        s.duration_minutes,
        s.price,
        s.capacity,
        s.is_public,
        s.is_participants_identified,
        s.is_active
    FROM service s
    WHERE s.id = $3
),

-- ── 1. derive end_time ───────────────────────────────────────────────────────
timing AS (
    SELECT
        $5::timestamptz                                             AS start_time,
        $5::timestamptz + (svc.duration_minutes * '1 minute'::interval) AS end_time,
        EXTRACT(ISODOW FROM $5::timestamptz)::int - 1              AS day_of_week
    FROM svc
),

-- ── 2. validate: service exists and is active ────────────────────────────────
chk_service AS (
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM svc) THEN 'error: service not found'
        WHEN NOT (SELECT is_active FROM svc) THEN 'error: service is not active'
        ELSE NULL
    END AS err
),

-- ── 3. validate: employee belongs to the same branch and offers the service ──
chk_employee AS (
    SELECT CASE
        WHEN $4::integer IS NULL THEN NULL   -- employee optional
        WHEN NOT EXISTS (
            SELECT 1
            FROM branch_employee be
            JOIN employee_service es ON es.employee_id = be.id
            CROSS JOIN svc
            WHERE be.id        = $4
              AND be.branch_id = svc.branch_id
              AND es.service_id = svc.id
              AND be.is_active  = TRUE
        ) THEN 'error: employee not found, inactive, or does not offer this service'
        ELSE NULL
    END AS err
),

-- ── 4. validate: slot falls within branch working hours ──────────────────────
chk_hours AS (
    SELECT CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM branch_schedule bs
            CROSS JOIN svc
            CROSS JOIN timing t
            WHERE bs.branch_id   = svc.branch_id
              AND bs.day_of_week = t.day_of_week
              AND bs.is_active   = TRUE
              AND (t.start_time::date + bs.opening_time::time)::timestamptz <= t.start_time
              AND (t.start_time::date + bs.closing_time::time)::timestamptz >= t.end_time
        ) THEN 'error: slot outside branch working hours'
        ELSE NULL
    END AS err
),

-- ── 5. validate: no active schedule_override closing the branch/employee ─────
chk_override AS (
    SELECT CASE
        WHEN EXISTS (
            SELECT 1
            FROM schedule_override so
            CROSS JOIN svc
            CROSS JOIN timing t
            WHERE so.branch_id  = svc.branch_id
              AND so.is_open    = FALSE
              AND so.start_time <= t.start_time
              AND so.end_time   >= t.end_time
              AND (so.employee_id IS NULL OR so.employee_id = $4)
        ) THEN 'error: slot is blocked by a schedule override'
        ELSE NULL
    END AS err
),

-- ── 6. validate: employee has no conflicting reservation ─────────────────────
chk_conflict AS (
    SELECT CASE
        WHEN $4::integer IS NULL THEN NULL
        WHEN EXISTS (
            SELECT 1
            FROM reservation r
            CROSS JOIN timing t
            WHERE r.employee_id = $4
              AND r.status      != 3   -- ignore canceled
              AND r.start_time  < t.end_time
              AND r.end_time    > t.start_time
        ) THEN 'error: employee has a conflicting reservation in this slot'
        ELSE NULL
    END AS err
),

-- ── 7. validate: capacity not exceeded (for public services) ─────────────────
chk_capacity AS (
    SELECT CASE
        WHEN NOT (SELECT is_public FROM svc) THEN NULL   -- private: no sharing
        WHEN (
            SELECT COALESCE(SUM(r.amount), 0)
            FROM reservation r
            CROSS JOIN timing t
            WHERE r.service_id = $3
              AND r.status     != 3
              AND r.start_time  = t.start_time
        ) + $6::integer > (SELECT capacity FROM svc)
        THEN 'error: service capacity exceeded for this slot'
        ELSE NULL
    END AS err
),

-- ── 8. collect all validation errors (first one wins) ───────────────────────
validation AS (
    SELECT COALESCE(
        (SELECT err FROM chk_service  WHERE err IS NOT NULL),
        (SELECT err FROM chk_employee WHERE err IS NOT NULL),
        (SELECT err FROM chk_hours    WHERE err IS NOT NULL),
        (SELECT err FROM chk_override WHERE err IS NOT NULL),
        (SELECT err FROM chk_conflict WHERE err IS NOT NULL),
        (SELECT err FROM chk_capacity WHERE err IS NOT NULL)
    ) AS err
),

-- ── 9. insert reservation (only when validation passed) ──────────────────────
new_reservation AS (
    INSERT INTO reservation (
        id, service_id, user_id, employee_id,
        status, start_time, end_time,
        amount, note, created_at, updated_at
    )
    SELECT
        gen_random_uuid(),
        $3,
        u.id,
        $4::integer,
        0,              -- status: pending
        t.start_time,
        t.end_time,
        $6::integer,
        $7::text,
        NOW(),
        NOW()
    FROM timing t
    CROSS JOIN reservation_user u
    WHERE (SELECT err FROM validation) IS NULL
    RETURNING id, service_id
),

-- ── 10. insert payment linked to the reservation ─────────────────────────────
new_payment AS (
    INSERT INTO payment (
        id, reservation_id, online,
        status, transaction_id, amount, currency,
        created_at, updated_at
    )
    SELECT
        gen_random_uuid(),
        nr.id,
        FALSE,          -- default: pay on site; frontend can update to online + txn_id
        0,              -- status: pending
        NULL,           -- transaction_id set later by payment gateway
        svc.price * $6::integer,
        'EUR',
        NOW(),
        NOW()
    FROM new_reservation nr
    CROSS JOIN svc
    RETURNING id, reservation_id
)

-- ── 11. return result ────────────────────────────────────────────────────────
SELECT
    CASE
        WHEN v.err IS NOT NULL THEN v.err
        ELSE 'ok'
    END                     AS result,
    nr.id                   AS reservation_id,
    np.id                   AS payment_id
FROM validation v
LEFT JOIN new_reservation nr ON TRUE
LEFT JOIN new_payment     np ON np.reservation_id = nr.id;

