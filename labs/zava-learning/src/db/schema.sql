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

-- Every course in `courses` must be represented here: quiz-service and assessment-api fall
-- back to a "Sample question N" placeholder for any course with no curated rows, which shows
-- up in the student portal as an unusable quiz. The seed is declarative rather than
-- seed-once-if-empty (`DELETE` then `INSERT`) so re-running the schema against an existing
-- lab converges the table on the current set instead of preserving stale rows. The whole file
-- executes as one implicit transaction, so students never observe an empty bank.
DELETE FROM quiz_questions;

INSERT INTO quiz_questions (course_id, prompt, options, answer_idx) VALUES
  ('BIO-101',  'If every cell arises only from a pre-existing cell, what does that imply about the origin of a multicellular organism?',
   '["It assembles from free-floating organic molecules","It arises spontaneously from decaying matter","It develops from a single fertilized cell","It is copied whole from a parent organism"]'::jsonb, 2),
  ('BIO-101',  'When an organism passes its traits to the next generation, which molecule carries the instructions that make that continuity possible?',
   '["DNA","ATP","Cellulose","Hemoglobin"]'::jsonb, 0),
  ('BIO-101',  'If two unrelated species independently evolve similar wing structures, what does that similarity most likely reflect?',
   '["A recent common ancestor","Convergent evolution under similar selective pressures","Genetic drift in an isolated population","A shared developmental accident"]'::jsonb, 1),
  ('BIO-101',  'Why does energy flow through an ecosystem in one direction while matter cycles through it repeatedly?',
   '["Energy is lost as heat at every transfer, while atoms are reused","Producers consume all available energy before it can return","Decomposers destroy energy but preserve matter","Energy cannot pass between trophic levels"]'::jsonb, 0),
  ('BIO-101',  'If a cell''s membrane were freely permeable to every solute, which fundamental capability would the cell lose?',
   '["The ability to synthesize proteins","The ability to store genetic information","The ability to replicate its DNA","The ability to hold an internal state different from its surroundings"]'::jsonb, 3),

  ('MATH-220', 'If a quantity''s rate of change is proportional to the quantity itself, which kind of function describes its growth?',
   '["Linear","Exponential","Quadratic","Logarithmic"]'::jsonb, 1),
  ('MATH-220', 'An infinite sum of ever-smaller terms can still fail to settle on a finite value. Which series demonstrates that?',
   '["A geometric series with ratio 1/2","A p-series with p = 2","The harmonic series","The alternating harmonic series"]'::jsonb, 2),
  ('MATH-220', 'If velocity is integrated over an interval of time, what does the resulting definite integral represent?',
   '["Total displacement over that interval","Instantaneous acceleration","Average speed at the endpoint","The greatest velocity attained"]'::jsonb, 0),
  ('MATH-220', 'Why can a smooth function be approximated arbitrarily well near a point by a Taylor polynomial?',
   '["Because every smooth function is itself a polynomial","Because its derivatives at that point encode its local behavior","Because integration reverses differentiation","Because continuity implies linearity"]'::jsonb, 1),
  ('MATH-220', 'If the partial sums of a series of positive terms are increasing and bounded above, what follows about the series?',
   '["It diverges","It oscillates without settling","Nothing can be concluded without further information","It converges"]'::jsonb, 3),

  ('HIST-180', 'If the Columbian Exchange carried crops, people and pathogens across the Atlantic, which consequence most reshaped indigenous American societies?',
   '["The adoption of a shared written language","Catastrophic population loss caused by introduced disease","A shift from farming to nomadic herding","The rapid growth of inland trading guilds"]'::jsonb, 1),
  ('HIST-180', 'What underlying shift allowed European powers to project sustained influence across distant continents after 1500?',
   '["Advances in navigation, finance and armed shipping","A sudden collapse of Asian trade networks","The abandonment of religious rivalry at home","A uniform legal code imposed across Europe"]'::jsonb, 0),
  ('HIST-180', 'When industrialization concentrated workers in cities, which new form of political organization emerged in response?',
   '["Feudal manorial courts","Guild apprenticeship systems","Organized labor movements","Absolute monarchy"]'::jsonb, 2),
  ('HIST-180', 'Nationalism can both unite and fracture states. Which outcome illustrates its fracturing effect?',
   '["The unification of the German states in 1871","The founding of overseas trading companies","The spread of a common European currency","The dissolution of multi-ethnic empires after 1918"]'::jsonb, 3),
  ('HIST-180', 'If decolonization transferred formal sovereignty to new states, why did economic dependence so often persist?',
   '["Trade and capital structures built under colonial rule remained in place","The new states rejected foreign trade entirely","Former colonies possessed no natural resources","Independence treaties forbade industrialization"]'::jsonb, 0),

  ('CHEM-110', 'If matter is neither created nor destroyed in a reaction, what must be true of a balanced chemical equation?',
   '["The same number of atoms of each element appears on both sides","The number of molecules is identical on both sides","The mass of the products exceeds that of the reactants","Atoms are conserved only when energy is released"]'::jsonb, 0),
  ('CHEM-110', 'Graphite and diamond are built from the same element, yet their properties differ enormously. What accounts for that difference?',
   '["They contain different isotopes","Their atoms are bonded in different structural arrangements","One is an element and the other a compound","Their atoms hold different numbers of protons"]'::jsonb, 1),
  ('CHEM-110', 'When a reaction at equilibrium is disturbed by a change in concentration or temperature, how does the system respond?',
   '["It stops until the disturbance is removed","It reverses permanently","It shifts so as to partially offset the change","It proceeds to completion in the forward direction"]'::jsonb, 2),
  ('CHEM-110', 'What does it mean, thermodynamically, for a reaction to be spontaneous?',
   '["It proceeds without continuous external input, however slowly","It occurs instantaneously","It releases heat in every case","It requires a catalyst before it can begin"]'::jsonb, 0),
  ('CHEM-110', 'If electrons occupy discrete energy levels, what explains the distinct colors that an excited element emits?',
   '["The nucleus emits visible light directly","Heating an element alters its atomic number","Electrons are destroyed as they lose energy","Transitions between fixed energy levels release photons of specific energies"]'::jsonb, 3),

  ('ECON-201', 'If every choice forecloses an alternative, what is the true cost of a decision?',
   '["The value of the best alternative forgone","The amount of money actually paid","The total resources available to the chooser","The cost already sunk into the decision"]'::jsonb, 0),
  ('ECON-201', 'If a price ceiling is set below the market-clearing price, what outcome should be expected?',
   '["A persistent surplus","A persistent shortage","No change in the quantity traded","An immediate increase in supply"]'::jsonb, 1),
  ('ECON-201', 'Why does a firm in a competitive market choose the output at which marginal cost equals marginal revenue?',
   '["It guarantees the lowest possible average cost","It maximizes total revenue","Any other level of output would forgo attainable profit","It removes fixed costs from the calculation"]'::jsonb, 2),
  ('ECON-201', 'If the benefits or harms of a transaction fall on people who are not party to it, what has the market failed to price?',
   '["A sunk cost","A fixed cost","A transfer payment","An externality"]'::jsonb, 3),
  ('ECON-201', 'As a consumer eats one slice of pizza after another, why does the amount they will pay for each additional slice decline?',
   '["Diminishing marginal utility","Rising fixed costs","An increase in market supply","A shift in the production function"]'::jsonb, 0),

  ('PSY-100',  'If the mind is an unwritten slate at birth, through which channel does all knowledge enter human consciousness?',
   '["Innate intuition","Sensory experience","Divine revelation","Unconscious memory"]'::jsonb, 1),
  ('PSY-100',  'When a person is torn between immediate desire and moral duty, which structure of the mind does Freud describe as the mediator with reality?',
   '["The id","The superego","The ego","The shadow"]'::jsonb, 2),
  ('PSY-100',  'Which position holds that every choice is the unavoidable consequence of prior conditioning rather than an act of free will?',
   '["Existentialism","Rationalism","Dualism","Determinism"]'::jsonb, 3),
  ('PSY-100',  'When we perceive an object, we experience a unified whole rather than a collection of separate parts. Which principle explains that?',
   '["Gestalt perception","Empiricism","Behavioral conditioning","Reductionism"]'::jsonb, 0),
  ('PSY-100',  'According to the existential perspective, what is the fundamental source of human suffering?',
   '["Repressed traumatic memories","The search for meaning in an indifferent universe","An imbalance of brain chemistry","A failure to adapt to environmental demands"]'::jsonb, 1);

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
