
CREATE TABLE role (
    id   SMALLINT     PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(50)  NOT NULL UNIQUE
);

CREATE TABLE permission (
    id          INTEGER      PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    resource    VARCHAR(50)  NOT NULL,
    can_view    BOOLEAN      NOT NULL DEFAULT FALSE,
    can_modify  BOOLEAN      NOT NULL DEFAULT FALSE,
    can_add     BOOLEAN      NOT NULL DEFAULT FALSE,
    can_delete  BOOLEAN      NOT NULL DEFAULT FALSE
);

-- USER

CREATE TABLE "user" (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(50)  NOT NULL UNIQUE,
    name            VARCHAR(50),
    password_hash   VARCHAR(256),
    password_salt   VARCHAR(20),
    phone           VARCHAR(10),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- JUNCTION: user_role, role_permission

CREATE TABLE user_role (
    user_id UUID     NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    role_id SMALLINT NOT NULL REFERENCES role(id) ON DELETE RESTRICT,
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE role_permission (
    role_id       SMALLINT NOT NULL REFERENCES role(id) ON DELETE CASCADE,
    permission_id INTEGER  NOT NULL REFERENCES permission(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);
-- BRANCH

CREATE TABLE branch (
    id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id     UUID         REFERENCES "user"(id) ON DELETE SET NULL,
    name         VARCHAR(256) NOT NULL,
    address      VARCHAR(256) NOT NULL,
    contact_info VARCHAR(256) NOT NULL,
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (owner_id, name)
);

CREATE TABLE branch_schedule (
    id               INTEGER     PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    branch_id        UUID        NOT NULL REFERENCES branch(id) ON DELETE CASCADE,
    day_of_week      SMALLINT    NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    opening_time     TIMETZ      NOT NULL,
    closing_time     TIMETZ      NOT NULL,
    interval_minutes INTEGER     NOT NULL CHECK (interval_minutes > 0),
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_branch_schedule_times CHECK (opening_time < closing_time)
    UNIQUE (branch_id, day_of_week)
);

CREATE TABLE schedule_override (
    id          INTEGER     PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    branch_id   UUID        NOT NULL REFERENCES branch(id) ON DELETE CASCADE,
    employee_id INTEGER,    -- FK set after branch_employee is created; nullable = branch-wide override
    start_time  TIMESTAMPTZ NOT NULL,
    end_time    TIMESTAMPTZ NOT NULL,
    is_open     BOOLEAN     NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_schedule_override_times CHECK (start_time < end_time)
);

-- BRANCH EMPLOYEE

CREATE TABLE branch_employee (
    id                INTEGER     PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    branch_id         UUID        NOT NULL REFERENCES branch(id) ON DELETE CASCADE,
    user_id           UUID        NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    salary            INTEGER     NOT NULL CHECK (salary >= 0),
    hired_at          DATE        NOT NULL,
    terminated_at     DATE,
    profile_image_url VARCHAR(256),
    is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_employee_dates CHECK (terminated_at IS NULL OR terminated_at > hired_at)
    UNIQUE (branch_id, user_id)
);

-- Now that branch_employee exists, add the FK on schedule_override
ALTER TABLE schedule_override
    ADD CONSTRAINT fk_schedule_override_employee
    FOREIGN KEY (employee_id) REFERENCES branch_employee(id) ON DELETE SET NULL;

-- SERVICE


CREATE TABLE service (
    id                       INTEGER      PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    branch_id                UUID         NOT NULL REFERENCES branch(id) ON DELETE CASCADE,
    name                     VARCHAR(256) NOT NULL,
    price                    INTEGER      NOT NULL CHECK (price >= 0),
    duration_minutes         INTEGER      NOT NULL CHECK (duration_minutes > 0),
    description              TEXT,
    capacity                 INTEGER      NOT NULL DEFAULT 1 CHECK (capacity > 0),
    is_active                BOOLEAN      NOT NULL DEFAULT TRUE,
    is_public                BOOLEAN      NOT NULL DEFAULT TRUE,
    is_participants_identified BOOLEAN    NOT NULL DEFAULT FALSE,
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (branch_id, name)
);

CREATE TABLE employee_service (
    service_id  INTEGER NOT NULL REFERENCES service(id) ON DELETE CASCADE,
    employee_id INTEGER NOT NULL REFERENCES branch_employee(id) ON DELETE CASCADE,
    PRIMARY KEY (service_id, employee_id)
);

-- RESERVATION

CREATE TABLE reservation (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id  INTEGER     REFERENCES service(id) ON DELETE SET NULL,
    user_id     UUID        NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    employee_id INTEGER     REFERENCES branch_employee(id) ON DELETE SET NULL,
    status      SMALLINT    NOT NULL DEFAULT 0
                            CHECK (status IN (0, 1, 2, 3)),
                            -- 0=pending, 1=confirmed, 2=finished, 3=canceled
    start_time  TIMESTAMPTZ NOT NULL,
    end_time    TIMESTAMPTZ,
    amount      INTEGER     NOT NULL DEFAULT 1 CHECK (amount >= 1),
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_reservation_times CHECK (end_time IS NULL OR end_time > start_time)
);

CREATE TABLE participant (
    id             INTEGER     PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    reservation_id UUID        NOT NULL REFERENCES reservation(id) ON DELETE CASCADE,
    first_name     VARCHAR(50),
    last_name      VARCHAR(50),
    date_of_birth  DATE,
    address_line1  VARCHAR(50),
    address_line2  VARCHAR(50),
    city           VARCHAR(50),
    state_region   VARCHAR(50),
    postal_code    VARCHAR(50),
    country        VARCHAR(50),
    note           TEXT
);

-- PAYMENT

CREATE TABLE payment (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    reservation_id UUID         NOT NULL REFERENCES reservation(id) ON DELETE CASCADE,
    online         BOOLEAN      NOT NULL DEFAULT FALSE,
    status         SMALLINT     NOT NULL DEFAULT 0
                                CHECK (status IN (0, 1, 2, 3)),
                                -- 0=pending, 1=confirmed, 2=finished, 3=canceled
    transaction_id VARCHAR(256) UNIQUE,  -- NULL for cash payments
    amount         INTEGER      NOT NULL CHECK (amount >= 0),
    currency       VARCHAR(8)   NOT NULL DEFAULT 'EUR',
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

