-- (a) Tables and seed data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name      TEXT NOT NULL
);

CREATE TABLE applications (
    application_id   SERIAL PRIMARY KEY,
    student_id       INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income   NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark     NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on     DATE NOT NULL,
    status           TEXT NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     TEXT NOT NULL,
    new_status     TEXT NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Eligibility inputs cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative, got %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION tf_applications_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
EXECUTE FUNCTION tf_applications_decision_audit();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(12, 2);
    v_mark     NUMERIC(5, 2);
    v_status   TEXT;
    v_eligible BOOLEAN;
    v_new_stat TEXT;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed with status %',
            p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);
    v_new_stat := CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications
    SET status = v_new_stat
    WHERE application_id = p_application_id;
END;
$$;

-- Seed 3 students and 6 PENDING applications (qualifying, non-qualifying, boundary)
INSERT INTO students (student_number, full_name) VALUES
    ('SCH001', 'Mutale Kabwe'),
    ('SCH002', 'Chanda Mulenga'),
    ('SCH003', 'Tandiwe Phiri');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2500.00, 82.50, DATE '2026-11-10', 'PENDING'), -- qualifying
    (1, 18, 3000.00, 70.00, DATE '2026-11-12', 'PENDING'), -- exact lower/upper boundary (APPROVED)
    (2, 25, 1800.00, 75.00, DATE '2026-11-14', 'PENDING'), -- upper age boundary (APPROVED)
    (2, 22, 3500.00, 88.00, DATE '2026-11-15', 'PENDING'), -- income > 3000 (REJECTED)
    (3, 21, 2000.00, 69.50, DATE '2026-11-18', 'PENDING'), -- mark < 70 (REJECTED)
    (3, 26, 1500.00, 90.00, DATE '2026-11-20', 'PENDING'); -- age > 25 (REJECTED)

-- (e) View
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index, query, and EXPLAIN
CREATE INDEX idx_applications_status_submitted_on ON applications (status, submitted_on);

-- Justification: Leading with status filters to the target status, and submitted_on
-- supports date-range scans within that status without table sorting.
EXPLAIN (ANALYZE, BUFFERS)
SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- (g) Procedure and scheduled job
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- pg_cron every Monday at 08:00
SELECT cron.schedule(
    'q10_assess_pending_applications',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);