-- Zava Learning platform schema + seed.
-- Applied once at provision time (chaos/_common.ps1 Invoke-DbSchema or the postprovision
-- hook). Models a McGraw-Hill-style course/quiz/gradebook platform on Postgres.
--
-- The schema is deliberately shaped so the DB fault lanes are REAL (no app toggles):
--   * query lane  -> relies on idx_question_bank_course; chaos/break-query.ps1 DROPs it,
--                    forcing a sequential scan over a large table (real latency).
--   * pool lane   -> uses a dedicated role app_pool; chaos/break-pool.ps1 sets a real
--                    CONNECTION LIMIT on it (real "too many connections" 500s).
--   * secret lane -> the app authenticates with a password sourced from Key Vault;
--                    chaos/break-secret.ps1 rotates that secret to an invalid value.

CREATE TABLE IF NOT EXISTS courses (
  id         TEXT PRIMARY KEY,
  title      TEXT NOT NULL,
  discipline TEXT NOT NULL,
  units      INT  NOT NULL,
  enrolled   INT  NOT NULL
);

INSERT INTO courses (id, title, discipline, units, enrolled) VALUES
  ('BIO-101',  'Introduction to Biology',        'Science',        12, 4821),
  ('MATH-220', 'Calculus II',                    'Mathematics',    10, 3110),
  ('HIST-180', 'World History Since 1500',       'Humanities',      8, 2675),
  ('CHEM-110', 'General Chemistry',              'Science',        14, 3902),
  ('ECON-201', 'Principles of Microeconomics',   'Business',        9, 5240),
  ('PSY-100',  'Foundations of Psychology',      'Social Science',  7, 6188)
ON CONFLICT (id) DO NOTHING;

-- Large question bank. The quiz endpoint filters this by course_id; with
-- idx_question_bank_course present the lookup is an index scan (fast). The query lane
-- fault DROPs that index, turning every quiz load into a seq scan over ~3M rows.
CREATE TABLE IF NOT EXISTS question_bank (
  id          BIGSERIAL PRIMARY KEY,
  course_id   TEXT NOT NULL,
  prompt      TEXT NOT NULL,
  options     JSONB NOT NULL,
  answer_idx  INT  NOT NULL,
  active      BOOLEAN NOT NULL DEFAULT true
);

-- Seed ~3M rows spread across the courses (idempotent: only seed when empty). The table is
-- intentionally large enough that, without idx_question_bank_course, a full seq scan on the
-- 1-vCore Burstable server takes several seconds (a believable "corrupt index" latency spike).
INSERT INTO question_bank (course_id, prompt, options, answer_idx, active)
SELECT
  (ARRAY['BIO-101','MATH-220','HIST-180','CHEM-110','ECON-201','PSY-100'])[1 + (g % 6)],
  'Practice question #' || g,
  '["A","B","C","D"]'::jsonb,
  (g % 4),
  true
FROM generate_series(1, 3000000) AS g
WHERE NOT EXISTS (SELECT 1 FROM question_bank);

CREATE INDEX IF NOT EXISTS idx_question_bank_course ON question_bank (course_id) WHERE active;

-- A small curated set actually served to students (kept stable for the demo).
CREATE TABLE IF NOT EXISTS quiz_questions (
  id         SERIAL PRIMARY KEY,
  course_id  TEXT NOT NULL REFERENCES courses(id),
  prompt     TEXT NOT NULL,
  options    JSONB NOT NULL,
  answer_idx INT  NOT NULL
);

INSERT INTO quiz_questions (course_id, prompt, options, answer_idx)
SELECT * FROM (VALUES
  ('BIO-101',  'The basic unit of life is the?',            '["Atom","Cell","Organ","Tissue"]'::jsonb, 1),
  ('BIO-101',  'DNA is found primarily in the?',            '["Nucleus","Membrane","Cytoplasm","Wall"]'::jsonb, 0),
  ('MATH-220', 'The integral of 1/x dx is?',                '["ln|x|+C","x^2+C","-1/x^2+C","e^x+C"]'::jsonb, 0),
  ('MATH-220', 'A series that approaches a limit is said to?','["Diverge","Oscillate","Converge","Repeat"]'::jsonb, 2),
  ('ECON-201', 'Demand curves typically slope?',            '["Upward","Downward","Flat","Vertical"]'::jsonb, 1),
  ('ECON-201', 'Opportunity cost is the value of the?',     '["Best alternative","Total spend","Sunk cost","Tax"]'::jsonb, 0)
) AS v(course_id, prompt, options, answer_idx)
WHERE NOT EXISTS (SELECT 1 FROM quiz_questions);

-- Gradebook: quiz submissions / scores.
CREATE TABLE IF NOT EXISTS submissions (
  id         BIGSERIAL PRIMARY KEY,
  course_id  TEXT NOT NULL,
  student_id TEXT NOT NULL,
  total      INT  NOT NULL,
  correct    INT  NOT NULL,
  score_pct  INT  NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_submissions_course ON submissions (course_id);
