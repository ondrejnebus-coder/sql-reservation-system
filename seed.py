"""
seed.py — Reservation System Database Seeder
Requires: pip install faker psycopg2-binary
Usage:    python seed.py [--dsn "postgresql://user:pass@host/db"]
Default DSN: postgresql://postgres:postgres@localhost/reservations
"""

import argparse
import random
import uuid
from datetime import datetime, timedelta, timezone

from faker import Faker
import psycopg2
from psycopg2.extras import execute_values

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

FAKE = Faker()
random.seed(42)
Faker.seed(42)

NOW        = datetime.now(timezone.utc)
SEED_START = NOW - timedelta(days=30)
SEED_END   = NOW + timedelta(days=30)

NUM_BRANCHES = 20
ROLES        = ["Admin", "Branch Admin", "Employee", "Guest"]

BRANCH_TYPES = {
    "hotel":    ["Room – Single", "Room – Double", "Room – Suite", "Breakfast", "Spa Treatment", "Pool Access", "Airport Transfer"],
    "wellness": ["Sauna 60min", "Sauna 90min", "Massage – Back", "Massage – Full Body", "Ice Bath", "Hammam", "Floatation Tank"],
    "trainer":  ["Personal Training 60", "Personal Training 90", "Group Class", "Nutrition Consult", "Assessment Session"],
    "salon":    ["Haircut", "Colour", "Blowdry", "Manicure", "Pedicure", "Brow Shaping", "Beard Trim"],
    "clinic":   ["Consultation", "Follow-up", "Blood Test", "X-Ray", "Physiotherapy", "ECG", "Ultrasound"],
}
BRANCH_TYPE_KEYS = list(BRANCH_TYPES.keys())
PARTICIPANT_BRANCH_TYPES = {"hotel", "clinic"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rand_uuid():
    return str(uuid.uuid4())

def rand_dt(start, end):
    return start + timedelta(seconds=random.uniform(0, (end - start).total_seconds()))

def round_slot(dt, mins=30):
    discard = timedelta(minutes=dt.minute % mins, seconds=dt.second, microseconds=dt.microsecond)
    return dt - discard

def normal_int(mu, sigma, lo, hi):
    return max(lo, min(hi, int(random.gauss(mu, sigma))))

def weighted_status():
    return random.choices([0, 1, 2, 3], weights=[10, 20, 55, 15])[0]

def payment_status_for(res_status):
    if res_status == 2: return 2
    if res_status == 3: return random.choices([2, 3], weights=[50, 50])[0]
    if res_status == 1: return random.choices([0, 1], weights=[30, 70])[0]
    return 0


# ---------------------------------------------------------------------------
# Build data
# ---------------------------------------------------------------------------

def build_roles():
    return [(name,) for name in ROLES]

def build_permissions():
    resources = ["reservation", "service", "branch", "employee",
                 "payment", "schedule", "report", "user"]
    return [(r, True, True, True, True) for r in resources]

def build_role_permissions(role_ids, perm_ids):
    rows = []
    for pid in perm_ids:
        rows.append((role_ids["Admin"], pid))
        rows.append((role_ids["Branch Admin"], pid))
    for pid, res in zip(perm_ids, ["reservation", "service", "branch", "employee",
                                    "payment", "schedule", "report", "user"]):
        if res in {"reservation", "service", "schedule"}:
            rows.append((role_ids["Employee"], pid))
    rows.append((role_ids["Guest"], perm_ids[0]))
    return rows

def build_users(n):
    rows = []
    for _ in range(n):
        has_pw = random.random() > 0.4
        rows.append((
            rand_uuid(),
            FAKE.unique.email(),
            FAKE.name(),
            FAKE.sha256() if has_pw else None,
            FAKE.lexify("????????????????????") if has_pw else None,
            FAKE.numerify("##########") if random.random() > 0.3 else None,
            NOW - timedelta(days=random.randint(0, 730)),
            NOW - timedelta(days=random.randint(0, 30)),
        ))
    return rows

def build_branches(owner_ids):
    rows, btypes = [], []
    for _ in range(NUM_BRANCHES):
        btype = random.choice(BRANCH_TYPE_KEYS)
        btypes.append(btype)
        rows.append((
            rand_uuid(),
            random.choice(owner_ids),
            FAKE.company()[:256],
            FAKE.address().replace("\n", ", ")[:256],
            FAKE.phone_number()[:256],
            True,
            NOW - timedelta(days=random.randint(30, 1000)),
            NOW,
        ))
    return rows, btypes

def build_branch_schedules(branch_ids):
    rows = []
    for bid in branch_ids:
        for dow in range(7):
            if dow == 6 and random.random() < 0.3:
                continue
            oh = random.randint(7, 10)
            ch = random.randint(17, 22)
            rows.append((
                bid, dow,
                "%02d:00:00+00" % oh,
                "%02d:00:00+00" % ch,
                random.choice([15, 30, 60]),
                True,
                NOW - timedelta(days=random.randint(30, 365)),
                NOW,
            ))
    return rows

def build_employees(branch_ids, user_ids):
    rows = []
    for bid in branch_ids:
        n = normal_int(10, 8, 1, 50)
        for _ in range(n):
            hired = NOW - timedelta(days=random.randint(30, 1500))
            terminated = None
            if random.random() < 0.1:
                terminated = hired + timedelta(days=random.randint(30, 500))
            rows.append((
                bid,
                random.choice(user_ids),
                random.randint(80000, 400000),
                hired.date(),
                terminated.date() if terminated else None,
                None,
                terminated is None,
                NOW - timedelta(days=random.randint(0, 30)),
                NOW,
            ))
    return rows

def build_services(branch_ids, branch_types):
    rows = []
    for bid, btype in zip(branch_ids, branch_types):
        pool = BRANCH_TYPES[btype]
        n = random.randint(5, min(20, len(pool) * 2))
        names_used = set()
        for _ in range(n):
            name = random.choice(pool)
            base, variant = name, 0
            while name in names_used:
                variant += 1
                name = "%s #%d" % (base, variant)
            names_used.add(name)
            is_public = random.random() > 0.2
            needs_p = btype in PARTICIPANT_BRANCH_TYPES
            rows.append((
                bid,
                name[:256],
                random.randint(500, 50000),
                random.choice([30, 45, 60, 90, 120, 240, 480]),
                FAKE.sentence(nb_words=10),
                1 if not is_public else random.randint(1, 20),
                True,
                is_public,
                needs_p and random.random() < 0.7,
                NOW - timedelta(days=random.randint(10, 365)),
                NOW,
            ))
    return rows

def build_schedule_overrides(branch_ids, employee_map):
    rows = []
    for bid in branch_ids:
        for _ in range(random.randint(2, 8)):
            start = rand_dt(SEED_START, SEED_END)
            end   = start + timedelta(hours=random.randint(2, 24))
            emp_id = None
            if employee_map.get(bid) and random.random() < 0.4:
                emp_id = random.choice(employee_map[bid])
            rows.append((
                bid, emp_id, start, end,
                random.random() < 0.1,
                NOW - timedelta(days=random.randint(0, 60)),
                NOW,
            ))
    return rows

def build_employee_services(employee_map, service_map, branch_ids):
    """
    Links employees to services strictly within the same branch.
    Both maps keyed by branch_uuid with real DB ids as values.
    Returns (insert_rows, es_lookup_set).
    """
    rows, seen = [], set()
    for bid in branch_ids:
        emps = employee_map.get(bid, [])
        svcs = service_map.get(bid, [])
        if not emps or not svcs:
            continue
        for eid in emps:
            for sid in random.sample(svcs, random.randint(1, min(5, len(svcs)))):
                key = (sid, eid)
                if key not in seen:
                    rows.append(key)
                    seen.add(key)
    return rows, seen

def build_reservations_and_payments(branch_ids, branch_types, user_ids,
                                    employee_map, service_map, service_info, es_lookup):
    reservations, participants, payments = [], [], []
    for bid, btype in zip(branch_ids, branch_types):
        emps = employee_map.get(bid, [])
        svcs = service_map.get(bid, [])
        if not emps or not svcs:
            continue

        eligible_map = {
            sid: [eid for eid in emps if (sid, eid) in es_lookup]
            for sid in svcs
        }

        n_res = normal_int(len(emps) * 60, len(emps) * 18, 20, 5000)
        for _ in range(n_res):
            sid = random.choice(svcs)
            dur, price, needs_p = service_info[sid]
            uid = random.choice(user_ids)

            eligible = eligible_map.get(sid, [])
            eid = random.choice(eligible) if eligible and random.random() < 0.85 else None

            start  = round_slot(rand_dt(SEED_START, SEED_END))
            end    = start + timedelta(minutes=dur)
            amount = random.randint(1, 4) if random.random() < 0.3 else 1
            status = weighted_status()
            if start < NOW and status == 0 and random.random() < 0.7:
                status = 2

            res_id = rand_uuid()
            reservations.append((
                res_id, sid, uid, eid, status, start, end, amount, None,
                NOW - timedelta(days=random.randint(0, 60)), NOW,
            ))

            if needs_p and btype in PARTICIPANT_BRANCH_TYPES:
                for _ in range(amount):
                    if random.random() < 0.75:
                        participants.append((
                            res_id,
                            FAKE.first_name(), FAKE.last_name(),
                            FAKE.date_of_birth(minimum_age=18, maximum_age=80),
                            FAKE.street_address()[:50], None,
                            FAKE.city()[:50], FAKE.state()[:50],
                            FAKE.postcode()[:50], FAKE.country()[:50],
                            None,
                        ))

            pstatus = payment_status_for(status)
            online  = random.random() < 0.65
            txn_id  = str(uuid.uuid4()) if online and pstatus >= 1 else None
            payments.append((
                rand_uuid(), res_id, online, pstatus, txn_id,
                price * amount, "EUR",
                NOW - timedelta(days=random.randint(0, 60)), NOW,
            ))

    return reservations, participants, payments


# ---------------------------------------------------------------------------
# Insert helpers
# ---------------------------------------------------------------------------

def insert(cur, table, cols, rows, page=2000):
    if not rows:
        return
    sql = "INSERT INTO %s (%s) VALUES %%s" % (table, ", ".join(cols))
    for i in range(0, len(rows), page):
        execute_values(cur, sql, rows[i:i + page])

def insert_returning(cur, table, cols, rows, page=2000):
    if not rows:
        return []
    ids = []
    sql = "INSERT INTO %s (%s) VALUES %%s RETURNING id" % (table, ", ".join(cols))
    for i in range(0, len(rows), page):
        execute_values(cur, sql, rows[i:i + page])
        ids.extend(r[0] for r in cur.fetchall())
    return ids

def insert_returning_with_branch(cur, table, cols, rows, page=2000):
    """
    Insert rows and return (id_to_branch dict, all_ids list).
    branch_id MUST be the first column in cols.
    Uses RETURNING id, branch_id — completely order-independent.
    This is the key fix: no positional slicing that breaks when
    PostgreSQL returns rows in a different order than insertion.
    """
    if not rows:
        return {}, []
    id_to_branch = {}
    all_ids = []
    sql = "INSERT INTO %s (%s) VALUES %%s RETURNING id, branch_id" % (table, ", ".join(cols))
    for i in range(0, len(rows), page):
        execute_values(cur, sql, rows[i:i + page])
        for db_id, branch_id in cur.fetchall():
            id_to_branch[db_id] = branch_id
            all_ids.append(db_id)
    return id_to_branch, all_ids


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(dsn):
    print("Connecting to: %s" % dsn)
    conn = psycopg2.connect(dsn)
    conn.autocommit = False
    cur = conn.cursor()

    try:
        # ── Wipe everything cleanly ────────────────────────────────────────
        print("Truncating all tables...")
        cur.execute("""
            TRUNCATE TABLE
                payment, participant, reservation,
                employee_service, schedule_override, branch_schedule,
                branch_employee, service, branch,
                user_role, role_permission,
                "user", permission, role
            RESTART IDENTITY CASCADE
        """)

        # ── Roles ──────────────────────────────────────────────────────────
        print("Seeding roles...")
        role_ids_list = insert_returning(cur, "role", ["name"], build_roles())
        role_ids = {name: rid for name, rid in zip(ROLES, role_ids_list)}
        print("  %d roles" % len(role_ids_list))

        # ── Permissions ────────────────────────────────────────────────────
        print("Seeding permissions...")
        perm_ids = insert_returning(
            cur, "permission",
            ["resource", "can_view", "can_modify", "can_add", "can_delete"],
            build_permissions())
        print("  %d permissions" % len(perm_ids))

        # ── Role-Permissions ───────────────────────────────────────────────
        print("Seeding role_permission...")
        rp_rows = build_role_permissions(role_ids, perm_ids)
        insert(cur, "role_permission", ["role_id", "permission_id"], rp_rows)
        print("  %d role_permission rows" % len(rp_rows))

        # ── Users ──────────────────────────────────────────────────────────
        n_users = max(10000, NUM_BRANCHES * 60)
        print("Seeding %d users..." % n_users)
        user_rows = build_users(n_users)
        insert_returning(
            cur, '"user"',
            ["id", "email", "name", "password_hash", "password_salt",
             "phone", "created_at", "updated_at"],
            user_rows)
        user_uuids = [r[0] for r in user_rows]
        insert(cur, "user_role", ["user_id", "role_id"],
               [(uid, role_ids["Guest"]) for uid in user_uuids])
        print("  %d users" % len(user_uuids))

        # ── Branches ──────────────────────────────────────────────────────
        print("Seeding %d branches..." % NUM_BRANCHES)
        branch_rows, branch_types = build_branches(random.sample(user_uuids, NUM_BRANCHES))
        branch_uuids = [r[0] for r in branch_rows]
        insert(cur, "branch",
               ["id", "owner_id", "name", "address", "contact_info",
                "is_active", "created_at", "updated_at"],
               branch_rows)
        print("  %d branches" % NUM_BRANCHES)

        # ── Branch Schedules ───────────────────────────────────────────────
        print("Seeding branch_schedules...")
        bs_rows = build_branch_schedules(branch_uuids)
        insert(cur, "branch_schedule",
               ["branch_id", "day_of_week", "opening_time", "closing_time",
                "interval_minutes", "is_active", "created_at", "updated_at"],
               bs_rows)
        print("  %d schedule rows" % len(bs_rows))

        # ── Employees ─────────────────────────────────────────────────────
        print("Seeding branch_employees...")
        emp_rows = build_employees(branch_uuids, user_uuids)
        emp_id_to_branch, emp_all_ids = insert_returning_with_branch(
            cur, "branch_employee",
            ["branch_id", "user_id", "salary", "hired_at", "terminated_at",
             "profile_image_url", "is_active", "created_at", "updated_at"],
            emp_rows)
        employee_map = {bid: [] for bid in branch_uuids}
        for eid, bid in emp_id_to_branch.items():
            employee_map[bid].append(eid)
        print("  %d employees" % len(emp_all_ids))

        # ── Schedule Overrides ─────────────────────────────────────────────
        print("Seeding schedule_overrides...")
        so_rows = build_schedule_overrides(branch_uuids, employee_map)
        insert(cur, "schedule_override",
               ["branch_id", "employee_id", "start_time", "end_time",
                "is_open", "created_at", "updated_at"],
               so_rows)
        print("  %d overrides" % len(so_rows))

        # ── Services ──────────────────────────────────────────────────────
        print("Seeding services...")
        svc_rows = build_services(branch_uuids, branch_types)
        svc_id_to_branch, svc_all_ids = insert_returning_with_branch(
            cur, "service",
            ["branch_id", "name", "price", "duration_minutes", "description",
             "capacity", "is_active", "is_public", "is_participants_identified",
             "created_at", "updated_at"],
            svc_rows)
        service_map = {bid: [] for bid in branch_uuids}
        for sid, bid in svc_id_to_branch.items():
            service_map[bid].append(sid)
        cur.execute("SELECT id, duration_minutes, price, is_participants_identified FROM service")
        service_info = {row[0]: (row[1], row[2], row[3]) for row in cur.fetchall()}
        print("  %d services" % len(svc_all_ids))

        # ── Employee-Service ───────────────────────────────────────────────
        print("Seeding employee_service...")
        es_rows, es_lookup = build_employee_services(employee_map, service_map, branch_uuids)
        insert(cur, "employee_service", ["service_id", "employee_id"], es_rows)
        print("  %d employee_service rows" % len(es_rows))

        # ── Reservations, Participants, Payments ───────────────────────────
        print("Seeding reservations, participants, payments...")
        res_rows, part_rows, pay_rows = build_reservations_and_payments(
            branch_uuids, branch_types, user_uuids,
            employee_map, service_map, service_info, es_lookup)
        insert(cur, "reservation",
               ["id", "service_id", "user_id", "employee_id", "status",
                "start_time", "end_time", "amount", "note", "created_at", "updated_at"],
               res_rows)
        if part_rows:
            insert(cur, "participant",
                   ["reservation_id", "first_name", "last_name", "date_of_birth",
                    "address_line1", "address_line2", "city", "state_region",
                    "postal_code", "country", "note"],
                   part_rows)
        insert(cur, "payment",
               ["id", "reservation_id", "online", "status", "transaction_id",
                "amount", "currency", "created_at", "updated_at"],
               pay_rows)
        print("  %d reservations, %d participants, %d payments"
              % (len(res_rows), len(part_rows), len(pay_rows)))

        conn.commit()
        total = (len(user_uuids) + NUM_BRANCHES + len(bs_rows) + len(emp_all_ids) +
                 len(so_rows) + len(svc_all_ids) + len(es_rows) +
                 len(res_rows) + len(part_rows) + len(pay_rows))
        print("\n✓ Seed complete — ~%s rows across all tables." % "{:,}".format(total))

    except Exception as e:
        conn.rollback()
        print("\n✗ Error: %s" % e)
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed the reservation system database.")
    parser.add_argument("--dsn", default="postgresql://postgres:postgres@localhost/reservations")
    args = parser.parse_args()
    main(args.dsn)
