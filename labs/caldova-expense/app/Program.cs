using System.Data;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var config = app.Configuration;
var logPath = config["Caldova:StructuredLogPath"] ?? @"C:\ProgramData\CaldovaExpense\logs\app.log";
var chaosPath = config["Caldova:ChaosStatePath"] ?? @"C:\ProgramData\CaldovaExpense\chaos.json";
var eventSource = config["Caldova:EventLogSource"] ?? "CaldovaExpense";
var eventLogName = config["Caldova:EventLogName"] ?? "Application";
var sapEndpoint = config["Caldova:SapFi:Endpoint"] ?? "https://sap-fi.internal.caldovagroup.com:8443/sap/opu/odata/sap/API_JOURNALENTRY";
var sapIp = config["Caldova:SapFi:TargetIp"] ?? "10.42.1.25";
var sapPort = int.TryParse(config["Caldova:SapFi:TargetPort"], out var parsedPort) ? parsedPort : 8443;
var sapLiveProbe = bool.TryParse(config["Caldova:SapFi:UseLiveNetworkProbe"], out var parsedLive) && parsedLive;

Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
Directory.CreateDirectory(Path.GetDirectoryName(chaosPath)!);

var logLock = new object();
var cpuWorkersLock = new object();
CancellationTokenSource? cpuBurnCts = null;

void WriteStructuredLog(string level, string category, string message, string? correlationId = null)
{
    var corr = correlationId ?? Activity.Current?.Id ?? Guid.NewGuid().ToString("N")[..12];
    var sanitized = message.Replace('\r', ' ').Replace('\n', ' ');
    var line = $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} {level,-5} [{category}] corr={corr} host={Environment.MachineName} {sanitized}";
    Console.WriteLine(line);
    try
    {
        lock (logLock)
        {
            File.AppendAllText(logPath, line + Environment.NewLine);
        }
    }
    catch
    {
        // Never crash request pipeline if file log directory is temporarily locked
    }
}

void WriteWindowsEvent(int eventId, string severity, string message)
{
    if (!OperatingSystem.IsWindows())
    {
        return;
    }

    try
    {
        if (EventLog.SourceExists(eventSource))
        {
            var entryType = severity switch
            {
                "Error"   => EventLogEntryType.Error,
                "Warning" => EventLogEntryType.Warning,
                _         => EventLogEntryType.Information
            };
            EventLog.WriteEntry(eventSource, message, entryType, eventId);
        }
    }
    catch
    {
        // Source registration is performed by 3-deploy-caldova-expense.ps1 (elevated).
    }
}

ChaosState ReadChaosState()
{
    try
    {
        if (!File.Exists(chaosPath))
        {
            return ChaosState.Normal;
        }

        var json = File.ReadAllText(chaosPath);
        var state = JsonSerializer.Deserialize<ChaosState>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });

        if (state is null || string.IsNullOrWhiteSpace(state.Mode))
        {
            return ChaosState.Normal;
        }

        if (state.ExpiresUtc.HasValue && state.ExpiresUtc.Value <= DateTimeOffset.UtcNow)
        {
            return ChaosState.Normal;
        }

        return state with { Mode = state.Mode.Trim().ToLowerInvariant() };
    }
    catch
    {
        return ChaosState.Normal;
    }
}

void EnsureCpuBurnMatchesState(ChaosState state)
{
    lock (cpuWorkersLock)
    {
        if (state.Mode == "cpu-pressure")
        {
            if (cpuBurnCts is { IsCancellationRequested: false })
            {
                return;
            }

            cpuBurnCts = new CancellationTokenSource();
            var token = cpuBurnCts.Token;
            var workerCount = Math.Max(1, Environment.ProcessorCount - 1);
            for (var i = 0; i < workerCount; i++)
            {
                _ = Task.Run(() =>
                {
                    var sw = Stopwatch.StartNew();
                    while (!token.IsCancellationRequested)
                    {
                        if (sw.ElapsedMilliseconds >= 85)
                        {
                            Thread.Sleep(15);
                            sw.Restart();
                        }
                        _ = Math.Sqrt(Random.Shared.NextDouble() * 1_000_000);
                    }
                }, token);
            }

            WriteStructuredLog("WARN", "ChaosCpu", $"CPU saturation workers started (workers={workerCount}, expiresUtc={state.ExpiresUtc:O})");
            WriteWindowsEvent(5004, "Warning",
                $"CaldovaExpense worker pool experiencing high CPU saturation (workers={workerCount}, mode=cpu-pressure, expiresUtc={state.ExpiresUtc:O}).");
        }
        else if (cpuBurnCts is not null)
        {
            cpuBurnCts.Cancel();
            cpuBurnCts.Dispose();
            cpuBurnCts = null;
        }
    }
}

string GetEffectiveConnectionString(ChaosState chaos)
{
    var baseConn = config.GetConnectionString("CaldovaExpenseDb")
        ?? "Server=localhost,1433;Database=CaldovaExpenseDb;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=5;";

    if (chaos.Mode == "db-auth-broken")
    {
        var builderConn = new SqlConnectionStringBuilder(baseConn)
        {
            InitialCatalog = "CaldovaExpenseDb_RestrictedVault",
            ConnectTimeout = 4
        };
        return builderConn.ConnectionString;
    }

    return baseConn;
}

string GetProcessIdentity()
{
    if (OperatingSystem.IsWindows())
    {
        try
        {
            return WindowsIdentity.GetCurrent().Name;
        }
        catch
        {
            return Environment.UserName;
        }
    }
    return Environment.UserName;
}

async Task<(bool Reachable, string Detail)> CheckOrSyncSapFiAsync(ChaosState chaos, string voucherRef, decimal amount, string correlationId)
{
    if (chaos.Mode == "sap-unavailable")
    {
        await Task.Delay(TimeSpan.FromMilliseconds(2200));
        var err = $"UpstreamDependencyUnavailable: Failed to post journal voucher '{voucherRef}' (${amount:F2}) to SAP FI endpoint {sapEndpoint} ({sapIp}:{sapPort}) — SocketException (10060): A connection attempt failed because the connected party did not properly respond after a period of time.";
        WriteWindowsEvent(5002, "Error", err);
        WriteStructuredLog("ERROR", "SapFiSync", err, correlationId);
        return (false, err);
    }

    if (sapLiveProbe)
    {
        try
        {
            using var tcp = new TcpClient();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await tcp.ConnectAsync(sapIp, sapPort, cts.Token);
            return (true, $"Connected live to SAP FI gateway {sapIp}:{sapPort}");
        }
        catch (Exception ex)
        {
            var err = $"UpstreamDependencyUnavailable: Live S2S probe to SAP FI {sapIp}:{sapPort} failed: {ex.Message}";
            WriteWindowsEvent(5002, "Error", err);
            WriteStructuredLog("ERROR", "SapFiSync", err, correlationId);
            return (false, err);
        }
    }

    await Task.Delay(TimeSpan.FromMilliseconds(45));
    return (true, $"Voucher {voucherRef} posted to SAP FI ({sapIp}:{sapPort})");
}

// Request completion logging middleware (single completion line per /api request for accurate error-rate KQL)
app.Use(async (ctx, next) =>
{
    var correlationId = ctx.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString("N")[..12];
    ctx.Response.Headers["X-Correlation-ID"] = correlationId;
    ctx.Items["CorrelationId"] = correlationId;

    var chaos = ReadChaosState();
    EnsureCpuBurnMatchesState(chaos);

    var sw = Stopwatch.StartNew();
    await next();
    sw.Stop();

    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        var status = ctx.Response.StatusCode;
        var level = status >= 500 ? "ERROR" : (status >= 400 ? "WARN" : "INFO");
        var outcome = status >= 500 ? "failed" : "completed";
        WriteStructuredLog(
            level,
            "HttpRequest",
            $"Request {ctx.Request.Method} {ctx.Request.Path} {outcome} status={status} durationMs={sw.ElapsedMilliseconds} chaosMode={chaos.Mode}",
            correlationId);
    }
});

app.MapGet("/", () =>
{
    var chaos = ReadChaosState();
    var identity = WebUtility.HtmlEncode(GetProcessIdentity());
    var host = WebUtility.HtmlEncode(Environment.MachineName);
    var fqdn = WebUtility.HtmlEncode(config["Caldova:HostFqdn"] ?? "expense.internal.caldovagroup.com");
    var modeBadgeColor = chaos.Mode == "normal" ? "#107c41" : "#c50f1f";

    var html = $$"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <title>Caldova Expense — Internal Reimbursement Portal</title>
      <style>
        body { font-family: "Segoe UI", system-ui, sans-serif; margin: 2rem auto; max-width: 960px; color: #1f2328; background: #f6f8fa; }
        header { background: #0f2942; color: #fff; padding: 1.25rem 1.5rem; border-radius: 8px; display: flex; justify-content: space-between; align-items: center; }
        .badge { padding: 0.3rem 0.7rem; border-radius: 999px; font-size: 0.85rem; font-weight: 600; background: {{modeBadgeColor}}; color: #fff; }
        .card { background: #fff; border: 1px solid #d0d7de; border-radius: 8px; padding: 1.25rem 1.5rem; margin-top: 1.25rem; }
        table { width: 100%; border-collapse: collapse; margin-top: 0.75rem; }
        th, td { text-align: left; padding: 0.55rem 0.6rem; border-bottom: 1px solid #eaeef2; font-size: 0.92rem; }
        button { background: #0969da; color: #fff; border: none; border-radius: 6px; padding: 0.5rem 0.95rem; cursor: pointer; font-weight: 600; margin-right: 0.5rem; }
        button.secondary { background: #57606a; }
        pre { background: #0d1117; color: #e6edf3; padding: 0.9rem; border-radius: 6px; overflow-x: auto; font-size: 0.85rem; }
        .meta { font-size: 0.88rem; color: #57606a; }
      </style>
    </head>
    <body>
      <header>
        <div>
          <h2 style="margin:0;">Caldova Expense Portal</h2>
          <div style="opacity:0.85;font-size:0.9rem;">Host: {{host}} ({{fqdn}}) | AppPool Identity: {{identity}}</div>
        </div>
        <span class="badge">Mode: {{WebUtility.HtmlEncode(chaos.Mode)}}</span>
      </header>

      <div class="card">
        <h3 style="margin-top:0;">Actions</h3>
        <button onclick="loadExpenses()">Refresh Expense Reports</button>
        <button onclick="submitSample()">Submit Sample Expense ($640.00 + SAP FI Sync)</button>
        <button class="secondary" onclick="checkHealth()">Check /api/health</button>
        <p class="meta">SQL Server: Windows Integrated Auth (zero credentials in config) | Upstream ERP: <code>{{WebUtility.HtmlEncode(sapEndpoint)}}</code></p>
        <div id="statusBox"></div>
        <table>
          <thead>
            <tr><th>ID</th><th>Employee</th><th>Department</th><th>Category</th><th>Amount</th><th>Status</th><th>SAP Voucher</th><th>Submitted (UTC)</th></tr>
          </thead>
          <tbody id="expenseRows"><tr><td colspan="8">Loading...</td></tr></tbody>
        </table>
      </div>

      <div class="card">
        <h3 style="margin-top:0;">Latest API Response</h3>
        <pre id="apiOutput">Ready.</pre>
      </div>

      <script>
        async function loadExpenses() {
          const res = await fetch('/api/expenses');
          const text = await res.text();
          document.getElementById('apiOutput').textContent = `HTTP ${res.status}\n` + text;
          if (!res.ok) return;
          const data = JSON.parse(text);
          const rows = (data.expenses || []).map(e =>
            `<tr><td>${e.id}</td><td>${e.employeeName}</td><td>${e.department}</td><td>${e.category}</td><td>$${Number(e.amount).toFixed(2)}</td><td>${e.status}</td><td>${e.sapVoucherId || '-'}</td><td>${e.submittedAtUtc}</td></tr>`
          ).join('');
          document.getElementById('expenseRows').innerHTML = rows || '<tr><td colspan="8">No records.</td></tr>';
        }
        async function submitSample() {
          const payload = {
            employeeName: 'Jordan Rivera',
            employeeEmail: 'jrivera@caldovagroup.com',
            department: 'Field Engineering',
            category: 'Customer Onsite Travel',
            amount: 640.00,
            description: 'Regional substation inspection travel & lodging',
            syncSap: true
          };
          const res = await fetch('/api/expenses', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
          });
          const text = await res.text();
          document.getElementById('apiOutput').textContent = `HTTP ${res.status}\n` + text;
          if (res.ok) await loadExpenses();
        }
        async function checkHealth() {
          const res = await fetch('/api/health');
          const text = await res.text();
          document.getElementById('apiOutput').textContent = `HTTP ${res.status}\n` + text;
        }
        loadExpenses();
      </script>
    </body>
    </html>
    """;

    return Results.Content(html, "text/html");
});

app.MapGet("/api/health", async (HttpContext ctx) =>
{
    var corr = ctx.Items["CorrelationId"]?.ToString() ?? "health";
    var chaos = ReadChaosState();
    var connStr = GetEffectiveConnectionString(chaos);
    var sqlHealthy = false;
    string sqlDetail;

    try
    {
        await using var conn = new SqlConnection(connStr);
        await conn.OpenAsync();
        await using var cmd = new SqlCommand("SELECT DB_NAME(), SUSER_SNAME();", conn) { CommandTimeout = 4 };
        await using var reader = await cmd.ExecuteReaderAsync();
        if (await reader.ReadAsync())
        {
            sqlHealthy = true;
            sqlDetail = $"Connected to {reader.GetString(0)} as {reader.GetString(1)}";
        }
        else
        {
            sqlDetail = "Connected";
            sqlHealthy = true;
        }
    }
    catch (SqlException ex)
    {
        sqlDetail = $"SqlException (Number={ex.Number}): {ex.Message}";
        WriteWindowsEvent(5003, "Error", $"Health check SQL failure on {Environment.MachineName}: {sqlDetail}");
        WriteStructuredLog("ERROR", "SqlHealth", sqlDetail, corr);
    }
    catch (Exception ex)
    {
        sqlDetail = ex.Message;
        WriteStructuredLog("ERROR", "SqlHealth", sqlDetail, corr);
    }

    var sapDegraded = chaos.Mode == "sap-unavailable";
    var overallHealthy = sqlHealthy && !sapDegraded;
    var payload = new
    {
        status = overallHealthy ? "Healthy" : "Degraded",
        machine = Environment.MachineName,
        processIdentity = GetProcessIdentity(),
        chaosMode = chaos.Mode,
        sql = new { healthy = sqlHealthy, detail = sqlDetail },
        sapFi = new { healthy = !sapDegraded, endpoint = sapEndpoint, target = $"{sapIp}:{sapPort}" },
        timestampUtc = DateTimeOffset.UtcNow
    };

    return Results.Json(payload, statusCode: overallHealthy ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable);
});

app.MapGet("/api/expenses", async (HttpContext ctx, int? top) =>
{
    var corr = ctx.Items["CorrelationId"]?.ToString() ?? "list";
    var chaos = ReadChaosState();
    var limit = Math.Clamp(top ?? 20, 1, 100);

    try
    {
        await using var conn = new SqlConnection(GetEffectiveConnectionString(chaos));
        await conn.OpenAsync();

        var sqlText = chaos.Mode == "sql-lock"
            ? """
              WAITFOR DELAY '00:00:07';
              SELECT TOP (@Top) Id, EmployeeName, EmployeeEmail, Department, Category, Amount, Status, SapVoucherId, Description, SubmittedAtUtc
              FROM dbo.ExpenseReports
              ORDER BY SubmittedAtUtc DESC;
              """
            : """
              SELECT TOP (@Top) Id, EmployeeName, EmployeeEmail, Department, Category, Amount, Status, SapVoucherId, Description, SubmittedAtUtc
              FROM dbo.ExpenseReports
              ORDER BY SubmittedAtUtc DESC;
              """;

        await using var cmd = new SqlCommand(sqlText, conn)
        {
            CommandTimeout = chaos.Mode == "sql-lock" ? 4 : 10
        };
        cmd.Parameters.Add(new SqlParameter("@Top", SqlDbType.Int) { Value = limit });

        var items = new List<object>();
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            items.Add(new
            {
                id = reader.GetInt32(0),
                employeeName = reader.GetString(1),
                employeeEmail = reader.GetString(2),
                department = reader.GetString(3),
                category = reader.GetString(4),
                amount = reader.GetDecimal(5),
                status = reader.GetString(6),
                sapVoucherId = reader.IsDBNull(7) ? null : reader.GetString(7),
                description = reader.IsDBNull(8) ? null : reader.GetString(8),
                submittedAtUtc = reader.GetDateTime(9).ToString("yyyy-MM-ddTHH:mm:ssZ")
            });
        }

        return Results.Ok(new { count = items.Count, machine = Environment.MachineName, expenses = items });
    }
    catch (SqlException ex) when (ex.Number == -2 || ex.Number == 1222)
    {
        var msg = $"SqlCommandTimeout (SqlError={ex.Number}): Query against CaldovaExpenseDb.dbo.ExpenseReports timed out waiting on lock or slow query. {ex.Message}";
        WriteWindowsEvent(5001, "Error", msg);
        WriteStructuredLog("ERROR", "SqlTimeout", msg, corr);
        return Results.Json(new { error = "DatabaseTimeout", detail = msg, correlationId = corr }, statusCode: StatusCodes.Status500InternalServerError);
    }
    catch (SqlException ex)
    {
        var msg = $"SqlDatabaseError (SqlError={ex.Number}, Identity={GetProcessIdentity()}): {ex.Message}";
        WriteWindowsEvent(5003, "Error", msg);
        WriteStructuredLog("ERROR", "SqlError", msg, corr);
        return Results.Json(new { error = "DatabaseFailure", sqlErrorNumber = ex.Number, detail = msg, correlationId = corr }, statusCode: StatusCodes.Status500InternalServerError);
    }
});

app.MapPost("/api/expenses", async (HttpContext ctx, SubmitExpenseRequest req) =>
{
    var corr = ctx.Items["CorrelationId"]?.ToString() ?? "submit";
    var chaos = ReadChaosState();

    if (string.IsNullOrWhiteSpace(req.EmployeeName) || req.Amount <= 0)
    {
        return Results.BadRequest(new { error = "EmployeeName and positive Amount are required." });
    }

    var shouldSyncSap = req.SyncSap || req.Amount >= 500m;
    string? sapVoucher = null;

    if (shouldSyncSap)
    {
        var candidateVoucher = $"SAPFI-{DateTime.UtcNow:yyyyMMdd}-{Random.Shared.Next(10000, 99999)}";
        var (reachable, sapDetail) = await CheckOrSyncSapFiAsync(chaos, candidateVoucher, req.Amount, corr);
        if (!reachable)
        {
            return Results.Json(new
            {
                error = "SapFiUpstreamUnavailable",
                detail = sapDetail,
                sapEndpoint,
                correlationId = corr
            }, statusCode: StatusCodes.Status502BadGateway);
        }
        sapVoucher = candidateVoucher;
    }

    try
    {
        await using var conn = new SqlConnection(GetEffectiveConnectionString(chaos));
        await conn.OpenAsync();

        if (chaos.Mode == "sql-lock")
        {
            await using var delayCmd = new SqlCommand("WAITFOR DELAY '00:00:07';", conn) { CommandTimeout = 4 };
            await delayCmd.ExecuteNonQueryAsync();
        }

        await using var cmd = new SqlCommand("dbo.usp_SubmitExpenseReport", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 8
        };
        cmd.Parameters.AddWithValue("@EmployeeName", req.EmployeeName.Trim());
        cmd.Parameters.AddWithValue("@EmployeeEmail", string.IsNullOrWhiteSpace(req.EmployeeEmail) ? "employee@caldovagroup.com" : req.EmployeeEmail.Trim());
        cmd.Parameters.AddWithValue("@Department", string.IsNullOrWhiteSpace(req.Department) ? "General Operations" : req.Department.Trim());
        cmd.Parameters.AddWithValue("@Category", string.IsNullOrWhiteSpace(req.Category) ? "Travel & Meals" : req.Category.Trim());
        cmd.Parameters.AddWithValue("@Amount", req.Amount);
        cmd.Parameters.AddWithValue("@Status", sapVoucher is not null ? "PostedToSapFi" : "Submitted");
        cmd.Parameters.AddWithValue("@SapVoucherId", (object?)sapVoucher ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Description", (object?)req.Description ?? DBNull.Value);

        var newIdObj = await cmd.ExecuteScalarAsync();
        var newId = Convert.ToInt32(newIdObj);

        WriteWindowsEvent(1001, "Information",
            $"Expense report #{newId} submitted by {req.EmployeeName} (${req.Amount:F2}, status={(sapVoucher is not null ? "PostedToSapFi" : "Submitted")}, voucher={sapVoucher ?? "none"}).");

        return Results.Created($"/api/expenses/{newId}", new
        {
            id = newId,
            status = sapVoucher is not null ? "PostedToSapFi" : "Submitted",
            sapVoucherId = sapVoucher,
            correlationId = corr
        });
    }
    catch (SqlException ex) when (ex.Number == -2 || ex.Number == 1222)
    {
        var msg = $"SqlCommandTimeout (SqlError={ex.Number}) while inserting expense report for {req.EmployeeName}: {ex.Message}";
        WriteWindowsEvent(5001, "Error", msg);
        WriteStructuredLog("ERROR", "SqlTimeout", msg, corr);
        return Results.Json(new { error = "DatabaseTimeout", detail = msg, correlationId = corr }, statusCode: StatusCodes.Status500InternalServerError);
    }
    catch (SqlException ex)
    {
        var msg = $"SqlDatabaseError (SqlError={ex.Number}, Identity={GetProcessIdentity()}) while inserting expense report: {ex.Message}";
        WriteWindowsEvent(5003, "Error", msg);
        WriteStructuredLog("ERROR", "SqlError", msg, corr);
        return Results.Json(new { error = "DatabaseFailure", sqlErrorNumber = ex.Number, detail = msg, correlationId = corr }, statusCode: StatusCodes.Status500InternalServerError);
    }
});

app.MapPost("/api/expenses/{id:int}/approve", async (HttpContext ctx, int id) =>
{
    var corr = ctx.Items["CorrelationId"]?.ToString() ?? "approve";
    var chaos = ReadChaosState();
    var voucher = $"SAPFI-{DateTime.UtcNow:yyyyMMdd}-{id:D5}";

    var (reachable, sapDetail) = await CheckOrSyncSapFiAsync(chaos, voucher, 0m, corr);
    if (!reachable)
    {
        return Results.Json(new
        {
            error = "SapFiUpstreamUnavailable",
            detail = sapDetail,
            expenseId = id,
            correlationId = corr
        }, statusCode: StatusCodes.Status502BadGateway);
    }

    try
    {
        await using var conn = new SqlConnection(GetEffectiveConnectionString(chaos));
        await conn.OpenAsync();
        await using var cmd = new SqlCommand("""
            UPDATE dbo.ExpenseReports
            SET Status = 'ApprovedAndPosted', SapVoucherId = @Voucher
            WHERE Id = @Id;
            SELECT @@ROWCOUNT;
            """, conn) { CommandTimeout = 8 };
        cmd.Parameters.AddWithValue("@Voucher", voucher);
        cmd.Parameters.AddWithValue("@Id", id);

        var updated = Convert.ToInt32(await cmd.ExecuteScalarAsync());
        if (updated == 0)
        {
            return Results.NotFound(new { error = $"Expense report #{id} not found." });
        }

        return Results.Ok(new { id, status = "ApprovedAndPosted", sapVoucherId = voucher, sapDetail, correlationId = corr });
    }
    catch (SqlException ex)
    {
        var msg = $"SqlDatabaseError (SqlError={ex.Number}) approving expense #{id}: {ex.Message}";
        WriteWindowsEvent(5003, "Error", msg);
        WriteStructuredLog("ERROR", "SqlError", msg, corr);
        return Results.Json(new { error = "DatabaseFailure", detail = msg, correlationId = corr }, statusCode: StatusCodes.Status500InternalServerError);
    }
});

// Loopback-only chaos control endpoint (also controllable directly by editing C:\ProgramData\CaldovaExpense\chaos.json via Arc Run Command)
app.MapGet("/api/admin/chaos", (HttpContext ctx) =>
{
    if (ctx.Connection.RemoteIpAddress is { } ip && !IPAddress.IsLoopback(ip))
    {
        return Results.StatusCode(StatusCodes.Status403Forbidden);
    }
    return Results.Ok(ReadChaosState());
});

app.MapPost("/api/admin/chaos", (HttpContext ctx, SetChaosRequest req) =>
{
    if (ctx.Connection.RemoteIpAddress is { } ip && !IPAddress.IsLoopback(ip))
    {
        return Results.StatusCode(StatusCodes.Status403Forbidden);
    }

    var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "normal", "sap-unavailable", "sql-lock", "db-auth-broken", "cpu-pressure"
    };

    var requested = (req.Mode ?? "normal").Trim().ToLowerInvariant();
    if (!allowed.Contains(requested))
    {
        return Results.BadRequest(new { error = $"Unsupported mode '{requested}'. Allowed: {string.Join(", ", allowed)}" });
    }

    var durationMinutes = Math.Clamp(req.DurationMinutes ?? 15, 1, 120);
    var nextState = new ChaosState(
        Mode: requested,
        UpdatedUtc: DateTimeOffset.UtcNow,
        ExpiresUtc: requested == "normal" ? null : DateTimeOffset.UtcNow.AddMinutes(durationMinutes),
        Notes: req.Notes ?? $"Set via loopback API on {Environment.MachineName}"
    );

    File.WriteAllText(chaosPath, JsonSerializer.Serialize(nextState, new JsonSerializerOptions { WriteIndented = true }));
    EnsureCpuBurnMatchesState(nextState);

    WriteStructuredLog("WARN", "ChaosControl", $"Chaos state updated to '{requested}' (expiresUtc={nextState.ExpiresUtc:O})");
    WriteWindowsEvent(4001, "Warning", $"CaldovaExpense lab fault mode set to '{requested}' (expiresUtc={nextState.ExpiresUtc:O}).");

    return Results.Ok(nextState);
});

WriteStructuredLog("INFO", "Startup", $"CaldovaExpense started on {Environment.MachineName} as {GetProcessIdentity()}");
app.Run();

public record SubmitExpenseRequest(
    string EmployeeName,
    string? EmployeeEmail,
    string? Department,
    string? Category,
    decimal Amount,
    string? Description,
    bool SyncSap = true);

public record SetChaosRequest(string? Mode, int? DurationMinutes, string? Notes);

public record ChaosState(string Mode, DateTimeOffset? UpdatedUtc, DateTimeOffset? ExpiresUtc, string? Notes)
{
    public static ChaosState Normal => new("normal", null, null, "Healthy baseline");
}
