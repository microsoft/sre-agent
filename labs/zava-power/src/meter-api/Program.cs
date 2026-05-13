// meter-api: Simulated smart meter data service for the Zava Power ZeroOps Lab.
// Provides hourly usage, meter reads, and alerts for demo/observability scenarios.
// Includes a SIMULATE_OOM mode that leaks memory on /health calls to exercise autoscaling and diagnostics.

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Services.AddApplicationInsightsTelemetry();

var app = builder.Build();
var logger = app.Services.GetRequiredService<ILogger<Program>>();

// --- OOM simulation state ---
var memoryLeakList = new List<byte[]>();
var simulateOom = string.Equals(
    Environment.GetEnvironmentVariable("SIMULATE_OOM"), "true", StringComparison.OrdinalIgnoreCase);

// --- Helpers ---
var random = new Random();

// GET /health
app.MapGet("/health", () =>
{
    if (simulateOom)
    {
        var chunk = new byte[10 * 1024 * 1024]; // ~10 MB
        memoryLeakList.Add(chunk);
        logger.LogWarning("SIMULATE_OOM active — leaked {Count} chunks ({MB} MB total)",
            memoryLeakList.Count, memoryLeakList.Count * 10);
    }

    logger.LogInformation("Health check requested");
    return Results.Ok(new { status = "healthy", service = "meter-api", version = "1.0.0" });
});

// GET /usage — simulated hourly usage for the last 24 hours
app.MapGet("/usage", () =>
{
    logger.LogInformation("Usage data requested");
    var now = DateTime.UtcNow;
    var usage = Enumerable.Range(0, 24).Select(i =>
    {
        var kwh = Math.Round(1.0 + random.NextDouble() * 4.0, 1);
        return new
        {
            hour = now.AddHours(-23 + i).ToString("yyyy-MM-ddTHH:00:00Z"),
            kwh,
            cost_cents = (int)(kwh * 13)
        };
    }).ToArray();

    return Results.Ok(usage);
});

// GET /reads — simulated meter reads for 10 meters
app.MapGet("/reads", () =>
{
    logger.LogInformation("Meter reads requested");
    var now = DateTime.UtcNow;
    var reads = Enumerable.Range(1, 10).Select(i => new
    {
        meter_id = $"MTR-{1000 + i}",
        reading_kwh = Math.Round(10000 + random.NextDouble() * 5000, 1),
        timestamp = now.AddMinutes(-random.Next(0, 60)).ToString("o"),
        quality = "good"
    }).ToArray();

    return Results.Ok(reads);
});

// GET /alerts — simulated smart meter alerts
app.MapGet("/alerts", () =>
{
    logger.LogInformation("Alerts requested");
    var now = DateTime.UtcNow;
    var alerts = new[]
    {
        new { alert_id = "ALT-001", type = "high_usage",      meter_id = "MTR-1003", message = "Usage exceeded 8 kWh in a single hour",    severity = "warning",  timestamp = now.AddMinutes(-12).ToString("o") },
        new { alert_id = "ALT-002", type = "tamper_detected",  meter_id = "MTR-1007", message = "Possible meter tamper detected",           severity = "critical", timestamp = now.AddMinutes(-37).ToString("o") },
        new { alert_id = "ALT-003", type = "outage_detected",  meter_id = "MTR-1005", message = "No readings received for 30+ minutes",     severity = "critical", timestamp = now.AddMinutes(-45).ToString("o") },
        new { alert_id = "ALT-004", type = "high_usage",       meter_id = "MTR-1009", message = "Sustained high usage over the past 3 hours", severity = "warning", timestamp = now.AddMinutes(-5).ToString("o") }
    };

    return Results.Ok(alerts);
});

logger.LogInformation("meter-api starting — SIMULATE_OOM={OomEnabled}", simulateOom);
app.Run();
