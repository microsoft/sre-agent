"use strict";

// Application Insights — initialized before any other module so the diagnostic-channel
// patches are in place. Auto-collects requests, exceptions, dependencies and perf so the
// requests/exceptions/dependencies tables populate for crash and latency investigation.
// Guarded so local runs without a connection string still boot.
const appInsights = require("applicationinsights");
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  appInsights.setup(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING)
    .setAutoCollectRequests(true)
    .setAutoCollectExceptions(true)
    .setAutoCollectDependencies(true)
    .setAutoCollectPerformance(true, true)
    .setSendLiveMetrics(true)
    .start();
  appInsights.defaultClient.context.tags[appInsights.defaultClient.context.keys.cloudRole] = "assessment-api";
}
const express = require("express");

const app = express();
app.use(express.json());

// Per-request timing telemetry -> container console -> Log Analytics. Enables latency
// queries/alerts (ContainerAppConsoleLogs_CL ... extract "ms=").
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Math.round(Number(process.hrtime.bigint() - start) / 1e6);
    console.log(`req method=${req.method} path=${req.path} status=${res.statusCode} ms=${ms}`);
  });
  next();
});
// ZAVA-PERF-INJECT-POINT (chaos/break-perf.ps1 inserts the regression below this line)

const PORT = process.env.PORT || 8080;
const SERVICE = "assessment-api";
// Optional upstream dependency: validates the course exists before serving a quiz.
const COURSE_API_URL = process.env.COURSE_API_URL || "";

// Static quiz bank keyed by course id. Every course served by course-api must appear here:
// a course with no entry falls through to defaultQuiz() and renders as unusable placeholder
// questions in the student portal.
const QUIZZES = {
  "BIO-101": [
    { q: "If every cell arises only from a pre-existing cell, what does that imply about the origin of a multicellular organism?",
      options: ["It assembles from free-floating organic molecules", "It arises spontaneously from decaying matter", "It develops from a single fertilized cell", "It is copied whole from a parent organism"], answer: 2 },
    { q: "When an organism passes its traits to the next generation, which molecule carries the instructions that make that continuity possible?",
      options: ["DNA", "ATP", "Cellulose", "Hemoglobin"], answer: 0 },
    { q: "If two unrelated species independently evolve similar wing structures, what does that similarity most likely reflect?",
      options: ["A recent common ancestor", "Convergent evolution under similar selective pressures", "Genetic drift in an isolated population", "A shared developmental accident"], answer: 1 },
    { q: "Why does energy flow through an ecosystem in one direction while matter cycles through it repeatedly?",
      options: ["Energy is lost as heat at every transfer, while atoms are reused", "Producers consume all available energy before it can return", "Decomposers destroy energy but preserve matter", "Energy cannot pass between trophic levels"], answer: 0 },
    { q: "If a cell's membrane were freely permeable to every solute, which fundamental capability would the cell lose?",
      options: ["The ability to synthesize proteins", "The ability to store genetic information", "The ability to replicate its DNA", "The ability to hold an internal state different from its surroundings"], answer: 3 }
  ],
  "MATH-220": [
    { q: "If a quantity's rate of change is proportional to the quantity itself, which kind of function describes its growth?",
      options: ["Linear", "Exponential", "Quadratic", "Logarithmic"], answer: 1 },
    { q: "An infinite sum of ever-smaller terms can still fail to settle on a finite value. Which series demonstrates that?",
      options: ["A geometric series with ratio 1/2", "A p-series with p = 2", "The harmonic series", "The alternating harmonic series"], answer: 2 },
    { q: "If velocity is integrated over an interval of time, what does the resulting definite integral represent?",
      options: ["Total displacement over that interval", "Instantaneous acceleration", "Average speed at the endpoint", "The greatest velocity attained"], answer: 0 },
    { q: "Why can a smooth function be approximated arbitrarily well near a point by a Taylor polynomial?",
      options: ["Because every smooth function is itself a polynomial", "Because its derivatives at that point encode its local behavior", "Because integration reverses differentiation", "Because continuity implies linearity"], answer: 1 },
    { q: "If the partial sums of a series of positive terms are increasing and bounded above, what follows about the series?",
      options: ["It diverges", "It oscillates without settling", "Nothing can be concluded without further information", "It converges"], answer: 3 }
  ],
  "HIST-180": [
    { q: "If the Columbian Exchange carried crops, people and pathogens across the Atlantic, which consequence most reshaped indigenous American societies?",
      options: ["The adoption of a shared written language", "Catastrophic population loss caused by introduced disease", "A shift from farming to nomadic herding", "The rapid growth of inland trading guilds"], answer: 1 },
    { q: "What underlying shift allowed European powers to project sustained influence across distant continents after 1500?",
      options: ["Advances in navigation, finance and armed shipping", "A sudden collapse of Asian trade networks", "The abandonment of religious rivalry at home", "A uniform legal code imposed across Europe"], answer: 0 },
    { q: "When industrialization concentrated workers in cities, which new form of political organization emerged in response?",
      options: ["Feudal manorial courts", "Guild apprenticeship systems", "Organized labor movements", "Absolute monarchy"], answer: 2 },
    { q: "Nationalism can both unite and fracture states. Which outcome illustrates its fracturing effect?",
      options: ["The unification of the German states in 1871", "The founding of overseas trading companies", "The spread of a common European currency", "The dissolution of multi-ethnic empires after 1918"], answer: 3 },
    { q: "If decolonization transferred formal sovereignty to new states, why did economic dependence so often persist?",
      options: ["Trade and capital structures built under colonial rule remained in place", "The new states rejected foreign trade entirely", "Former colonies possessed no natural resources", "Independence treaties forbade industrialization"], answer: 0 }
  ],
  "CHEM-110": [
    { q: "If matter is neither created nor destroyed in a reaction, what must be true of a balanced chemical equation?",
      options: ["The same number of atoms of each element appears on both sides", "The number of molecules is identical on both sides", "The mass of the products exceeds that of the reactants", "Atoms are conserved only when energy is released"], answer: 0 },
    { q: "Graphite and diamond are built from the same element, yet their properties differ enormously. What accounts for that difference?",
      options: ["They contain different isotopes", "Their atoms are bonded in different structural arrangements", "One is an element and the other a compound", "Their atoms hold different numbers of protons"], answer: 1 },
    { q: "When a reaction at equilibrium is disturbed by a change in concentration or temperature, how does the system respond?",
      options: ["It stops until the disturbance is removed", "It reverses permanently", "It shifts so as to partially offset the change", "It proceeds to completion in the forward direction"], answer: 2 },
    { q: "What does it mean, thermodynamically, for a reaction to be spontaneous?",
      options: ["It proceeds without continuous external input, however slowly", "It occurs instantaneously", "It releases heat in every case", "It requires a catalyst before it can begin"], answer: 0 },
    { q: "If electrons occupy discrete energy levels, what explains the distinct colors that an excited element emits?",
      options: ["The nucleus emits visible light directly", "Heating an element alters its atomic number", "Electrons are destroyed as they lose energy", "Transitions between fixed energy levels release photons of specific energies"], answer: 3 }
  ],
  "ECON-201": [
    { q: "If every choice forecloses an alternative, what is the true cost of a decision?",
      options: ["The value of the best alternative forgone", "The amount of money actually paid", "The total resources available to the chooser", "The cost already sunk into the decision"], answer: 0 },
    { q: "If a price ceiling is set below the market-clearing price, what outcome should be expected?",
      options: ["A persistent surplus", "A persistent shortage", "No change in the quantity traded", "An immediate increase in supply"], answer: 1 },
    { q: "Why does a firm in a competitive market choose the output at which marginal cost equals marginal revenue?",
      options: ["It guarantees the lowest possible average cost", "It maximizes total revenue", "Any other level of output would forgo attainable profit", "It removes fixed costs from the calculation"], answer: 2 },
    { q: "If the benefits or harms of a transaction fall on people who are not party to it, what has the market failed to price?",
      options: ["A sunk cost", "A fixed cost", "A transfer payment", "An externality"], answer: 3 },
    { q: "As a consumer eats one slice of pizza after another, why does the amount they will pay for each additional slice decline?",
      options: ["Diminishing marginal utility", "Rising fixed costs", "An increase in market supply", "A shift in the production function"], answer: 0 }
  ],
  "PSY-100": [
    { q: "If the mind is an unwritten slate at birth, through which channel does all knowledge enter human consciousness?",
      options: ["Innate intuition", "Sensory experience", "Divine revelation", "Unconscious memory"], answer: 1 },
    { q: "When a person is torn between immediate desire and moral duty, which structure of the mind does Freud describe as the mediator with reality?",
      options: ["The id", "The superego", "The ego", "The shadow"], answer: 2 },
    { q: "Which position holds that every choice is the unavoidable consequence of prior conditioning rather than an act of free will?",
      options: ["Existentialism", "Rationalism", "Dualism", "Determinism"], answer: 3 },
    { q: "When we perceive an object, we experience a unified whole rather than a collection of separate parts. Which principle explains that?",
      options: ["Gestalt perception", "Empiricism", "Behavioral conditioning", "Reductionism"], answer: 0 },
    { q: "According to the existential perspective, what is the fundamental source of human suffering?",
      options: ["Repressed traumatic memories", "The search for meaning in an indifferent universe", "An imbalance of brain chemistry", "A failure to adapt to environmental demands"], answer: 1 }
  ]
};

function defaultQuiz(courseId) {
  return [
    { q: `Sample question 1 for ${courseId}`, options: ["A", "B", "C", "D"], answer: 0 },
    { q: `Sample question 2 for ${courseId}`, options: ["A", "B", "C", "D"], answer: 2 }
  ];
}

app.get("/health", (_req, res) => {
  res.status(200).json({ status: "ok", service: SERVICE, ts: new Date().toISOString() });
});

app.get("/quiz/:courseId", async (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  if (COURSE_API_URL) {
    try {
      const r = await fetch(`${COURSE_API_URL}/courses/${courseId}`, { signal: AbortSignal.timeout(4000) });
      if (r.status === 404) return res.status(404).json({ error: "course_not_found", courseId });
    } catch (err) {
      // Upstream course-api unreachable (e.g. blocked network path) -> surface as 502.
      return res.status(502).json({ error: "course_lookup_failed", detail: String(err) });
    }
  }
  const quiz = QUIZZES[courseId] || defaultQuiz(courseId);
  res.json({ courseId, questionCount: quiz.length, questions: quiz.map(({ q, options }) => ({ q, options })) });
});

app.post("/quiz/:courseId/submit", (req, res) => {
  const courseId = req.params.courseId.toUpperCase();
  const quiz = QUIZZES[courseId] || defaultQuiz(courseId);
  const answers = Array.isArray(req.body && req.body.answers) ? req.body.answers : [];
  let correct = 0;
  quiz.forEach((item, i) => { if (answers[i] === item.answer) correct++; });
  res.json({ courseId, total: quiz.length, correct, scorePct: Math.round((correct / quiz.length) * 100) });
});

app.listen(PORT, () => {
  console.log(`[${SERVICE}] listening on :${PORT}`);
});
