## Incident context is partial by construction

When you are working an alert, remember that it arrives in a thread that cannot
see other alerts or investigations. That isolation is a platform artifact — it
is not evidence that nothing else is happening.

Before you commit to a root cause, widen the frame: what else fired nearby,
which alert rules are muted on the resource, and whether Azure Service Health
already explains it.

Use the `incident-correlation` skill for the nearby-alert check; do not substitute
alert-rule inventory for fired-alert history. If another alert fired in the same
resource group within 10 minutes, shared timing and resource group prove only
overlap. Require a direct mechanism: for HTTP failures, split dependencies by
target and result code. Slow successful PostgreSQL calls cannot explain HTTP
500s whose only failed dependency is an app-local target. Report independent
causes when mechanisms differ. If the other alert is already acknowledged,
leave its remediation to its own thread.

When no nearby alert exists and the evidence is already clear, do not force a
correlation sweep. "I checked; this alert is the whole story" is complete.
