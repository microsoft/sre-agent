'use strict';

const elements = Object.fromEntries([
  'health', 'result', 'timing', 'checkout', 'start', 'stop', 'loop',
  'attempts', 'successes', 'failures',
].map((id) => [id, document.getElementById(id)]));
let running = false;
let busy = false;
let nextAttempt;
let deadlineTimer;
let deadline = 0;
let attempts = 0;
let successes = 0;
let failures = 0;
let activeRequest;

function updateButtons() {
  elements.checkout.disabled = busy || running;
  elements.start.disabled = busy || running;
  elements.stop.disabled = !running;
}

function stopTraffic(message = 'On-sale simulation stopped. No new requests will be sent.') {
  running = false;
  clearTimeout(nextAttempt);
  clearTimeout(deadlineTimer);
  activeRequest?.abort();
  elements.loop.textContent = message;
  updateButtons();
}

async function checkHealth() {
  try {
    const response = await fetch('/healthz', { signal: AbortSignal.timeout(7000) });
    if (!response.ok) throw new Error('Unavailable');
    elements.health.textContent = 'Tickets available';
    elements.health.dataset.state = 'success';
  } catch {
    elements.health.textContent = 'Ticketing unavailable';
    elements.health.dataset.state = 'failure';
  }
}

async function checkout() {
  if (busy) return;
  busy = true;
  updateButtons();
  elements.result.textContent = 'Reserving your tickets…';
  elements.result.dataset.state = 'pending';
  const started = performance.now();
  activeRequest = new AbortController();
  attempts += 1;
  elements.attempts.textContent = attempts;
  try {
    const response = await fetch('/checkout', {
      method: 'POST',
      signal: AbortSignal.any([activeRequest.signal, AbortSignal.timeout(7000)]),
    });
    const data = await response.json();
    if (!response.ok || data.success !== true) throw new Error('Unavailable');
    successes += 1;
    elements.result.textContent = 'Tickets reserved';
    elements.result.dataset.state = 'success';
  } catch {
    failures += 1;
    elements.result.textContent = 'Reservation could not be completed';
    elements.result.dataset.state = 'failure';
  } finally {
    activeRequest = undefined;
    busy = false;
    elements.successes.textContent = successes;
    elements.failures.textContent = failures;
    elements.timing.textContent = `${Math.round(performance.now() - started)} ms · ${new Date().toLocaleTimeString()}`;
    updateButtons();
    void checkHealth();
  }
}

async function trafficStep() {
  if (!running) return;
  if (Date.now() >= deadline) {
    stopTraffic('On-sale simulation ended after 10 minutes.');
    return;
  }
  await checkout();
  if (running) nextAttempt = setTimeout(trafficStep, 3000);
}

elements.checkout.addEventListener('click', checkout);
elements.start.addEventListener('click', () => {
  if (busy || running) return;
  running = true;
  deadline = Date.now() + 10 * 60 * 1000;
  deadlineTimer = setTimeout(() => stopTraffic('On-sale simulation ended after 10 minutes.'), 10 * 60 * 1000);
  elements.loop.textContent = 'Live demand is running: fans are joining the ticket queue.';
  updateButtons();
  void trafficStep();
});
elements.stop.addEventListener('click', () => stopTraffic());
window.addEventListener('pagehide', () => stopTraffic());
void checkHealth();