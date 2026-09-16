# Simulated checkout app

Tiny plain-JavaScript Node.js >=22 app for source deployment to **Linux App
Service**. There is no Docker image, bundler, React build, order schema, or real
purchase. The hosting integration is owned by the parent lab.

## Start and validate

From this folder:

```sh
npm ci --ignore-scripts
npm test
npm run check
npm audit
npm start
```

The HTTP server binds to `0.0.0.0` on `PORT`, default `8080`. Startup and health
do not connect to PostgreSQL. Missing database settings only cause checkout to
return a sanitized 503. Do not commit credentials or put them in browser code.

## Environment

| Variable | Meaning |
| --- | --- |
| `PORT` | HTTP listening port; default `8080` |
| `POSTGRES_HOST` | PostgreSQL DNS hostname matching its trusted TLS certificate |
| `POSTGRES_PORT` | PostgreSQL port; default `5432` |
| `POSTGRES_DATABASE` | Existing database name |
| `POSTGRES_USER` | UAMI principal display name registered as the PostgreSQL Entra admin by the lab Bicep; not its client/object ID |
| `AZURE_CLIENT_ID` | Client ID of the user-assigned managed identity (UAMI) attached to the app; required for checkout |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Server-side SDK connection string; omit for local offline use |

PostgreSQL is **Microsoft Entra-only**; there is no database password setting.
The server uses `ManagedIdentityCredential` with `AZURE_CLIENT_ID`, not developer
CLI credentials or a system-assigned identity fallback. On each fresh connection,
the async `pg.Client` password callback requests a token for
`https://ossrdbms-aad.database.windows.net/.default`. The SDK may reuse a valid
cached token; the app rejects missing/expired tokens and never logs or returns them.
Local checkout requires a hosting environment with that UAMI available; all tests
inject credentials and database clients and make no real managed-identity calls.

**Disposable lab only:** the hosting Bicep registers this UAMI as the PostgreSQL
Microsoft Entra administrator to avoid separate database-user bootstrapping. This
is elevated database access, **not a production privilege model**. Production apps
should use a separately provisioned, least-privilege database principal, not an
Entra administrator. This app only executes `SELECT 1`.

TLS certificate validation is mandatory. Each checkout constructs a fresh `pg`
Client, connects and runs only `SELECT 1`, then closes/destroys the connection in
`finally`. One five-second `Promise.race` deadline covers token acquisition,
connection and query together. An outstanding SDK token request may finish after
the deadline, but does not delay the 503 or socket cleanup; late rejections are handled.
Four attempts per
Node process are allowed concurrently; excess requests receive 503 immediately.
No connection pool can hide a deny rule behind an existing DB connection.

## Routes and telemetry

| Method | Path | Result |
| --- | --- | --- |
| GET | `/` | Self-contained UI |
| GET | `/app.js`, `/styles.css` | Only explicitly allowlisted static assets |
| GET | `/healthz` | 200 JSON independent of database health |
| POST | `/checkout` | 200 simulated success or sanitized 503 JSON |

Known paths with other methods return 405 with `Allow`; unknown paths return
404. Bodies are ignored. There are no database mutation or fault-control routes.

SDK telemetry is manual-only, unsampled (`samplingPercentage: 100`): one request
named `POST /checkout`, plus a PostgreSQL dependency for each admitted attempt.
Both include success/failure and duration; requests include the HTTP status.
Dependency target is a fixed label, not a connection string. No request bodies,
query parameters, host headers, access tokens, or exception details are recorded.
Automatic dependency, request, exception, console and live-metrics collection are
disabled to prevent duplicates and sensitive diagnostics. Use in a controlled
lab, not as a production checkout service. Missing telemetry config disables
telemetry without blocking the app. Unavailable telemetry never fails checkout.

## Traffic and deployment handoff

Manual checkout makes one request. The traffic loop waits for each request to
finish, then waits three seconds; it automatically stops at ten minutes. Stop
aborts the browser request and prevents subsequent attempts; already-started
server work can run until its five-second deadline. No traffic starts on load.

Supply this folder as the source app to the parent azd integration. Runtime start
command is `npm start`; production dependencies must be installed on Linux during
remote build. Exclude local `node_modules` from any source archive. No `.deployment`
file is included: SCM/azd remote-build configuration has not been verified here
and remains the parent integration's responsibility. No Azure deployment was run.
