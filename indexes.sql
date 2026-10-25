-- ============================================================
-- INDEXES
-- ============================================================

-- user lookups
CREATE INDEX idx_user_email ON "user"(email);

-- branch lookups
CREATE INDEX idx_branch_owner ON branch(owner_id);
CREATE INDEX idx_branch_active ON branch(is_active);

-- schedule lookups
CREATE INDEX idx_branch_schedule_branch ON branch_schedule(branch_id);
CREATE INDEX idx_schedule_override_branch ON schedule_override(branch_id);
CREATE INDEX idx_schedule_override_employee ON schedule_override(employee_id);

-- employee lookups
CREATE INDEX idx_branch_employee_branch ON branch_employee(branch_id);
CREATE INDEX idx_branch_employee_user ON branch_employee(user_id);

-- service lookups
CREATE INDEX idx_service_branch ON service(branch_id);
CREATE INDEX idx_employee_service_employee ON employee_service(employee_id);
CREATE INDEX idx_employee_service_service ON employee_service(service_id);

-- reservation lookups (most queried table)
CREATE INDEX idx_reservation_user ON reservation(user_id);
CREATE INDEX idx_reservation_service ON reservation(service_id);
CREATE INDEX idx_reservation_employee ON reservation(employee_id);
CREATE INDEX idx_reservation_status ON reservation(status);
CREATE INDEX idx_reservation_start_time ON reservation(start_time);

-- participant lookups
CREATE INDEX idx_participant_reservation ON participant(reservation_id);

-- payment lookups
CREATE INDEX idx_payment_reservation ON payment(reservation_id);
CREATE INDEX idx_payment_status ON payment(status);




-- mine
CREATE INDEX idx_reservation_employee_time
ON reservation (employee_id, status, start_time, end_time);

--
CREATE INDEX idx_branch_schedule_branch_day
ON branch_schedule (branch_id, day_of_week, is_active);