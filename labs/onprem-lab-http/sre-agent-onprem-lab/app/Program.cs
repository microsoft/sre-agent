using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var logPath = Environment.GetEnvironmentVariable("APP_LOG_PATH") ?? "/var/log/sre-lab/app.log";
Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
var logLock = new object();
var modeLock = new object();
var mode = "normal";

void AppLog(string level, string message)
{
    var line = $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ} {level,-5} {message}";
    Console.WriteLine(line);
    lock (logLock) File.AppendAllText(logPath, line + Environment.NewLine);
}

void ControlLog(string message) =>
    Console.WriteLine($"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ} LAB   {message}");

app.Use(async (ctx, next) =>
{
    var sw = Stopwatch.StartNew();
    await next();
    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        var status = ctx.Response.StatusCode;
        var level = status >= 500 ? "ERROR" : "INFO";
        var verb = status >= 500 ? "failed" : "completed";
        AppLog(level, $"Request {ctx.Request.Method} {ctx.Request.Path} {verb} status={status} durationMs={sw.ElapsedMilliseconds}");
    }
});

app.MapGet("/", () => "sre-lab sample app");
app.MapGet("/health", () => Results.Ok("healthy"));
app.MapGet("/api/orders", () =>
{
    string current;
    lock (modeLock) current = mode;
    if (current == "http500")
    {
        AppLog("ERROR", "Unhandled exception while retrieving orders: upstream dependency unavailable");
        return Results.StatusCode(500);
    }
    return Results.Ok(new[] { new { id = 1, item = "widget", qty = 3 }, new { id = 2, item = "gadget", qty = 1 } });
});

app.MapGet("/lab/fault", () => { lock (modeLock) return Results.Ok(new { mode }); });
app.MapPost("/lab/fault", (FaultRequest req) =>
{
    var requested = (req.Mode ?? "").ToLowerInvariant();
    if (requested is not ("normal" or "http500"))
        return Results.BadRequest(new { error = "mode must be 'normal' or 'http500'" });
    lock (modeLock)
    {
        ControlLog($"fault mode changed: {mode} -> {requested}");
        mode = requested;
    }
    return Results.Ok(new { mode = requested });
});

AppLog("INFO", "Application started");
app.Run();
record FaultRequest(string? Mode);
