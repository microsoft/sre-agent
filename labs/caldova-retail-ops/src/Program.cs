// Caldova Retail Ops - ASP.NET Core Web API.
//
// Deployed to Azure App Service with `azd deploy`. A
// static HTML/CSS/JS frontend lives in wwwroot and calls these JSON
// endpoints.

using CaldovaRetailOps.Services;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<CatalogService>();
builder.Services.AddSingleton<RecommendationEngine>();
builder.Services.AddSingleton<SearchService>();
builder.Services.AddSingleton<ReportingService>();
var app = builder.Build();

const string Service = "caldova-retail-ops";
var startedAt = DateTimeOffset.UtcNow;

app.Use(async (context, next) =>
{
    var started = DateTimeOffset.UtcNow;
    await next();
    var elapsedMs = (DateTimeOffset.UtcNow - started).TotalMilliseconds;
    Console.WriteLine($"caldova_request service={Service} method={context.Request.Method} path={context.Request.Path} status={context.Response.StatusCode} ms={elapsedMs:F0}");
});

app.UseDefaultFiles();
app.UseStaticFiles();

// ---------------------------------------------------------------------------
// API routes
// ---------------------------------------------------------------------------

app.MapGet("/api/health", () => Results.Json(new
{
    status = "ok",
    service = Service,
    startedAt = startedAt.ToString("o"),
    timestamp = DateTimeOffset.UtcNow.ToString("o")
}));

app.MapGet("/api/status", () => Results.Json(new
{
    service = Service,
    uptimeSeconds = (int)(DateTimeOffset.UtcNow - startedAt).TotalSeconds,
    dotnetVersion = Environment.Version.ToString(),
    instance = Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID") is { Length: > 0 } id ? id[..Math.Min(8, id.Length)] : "local"
}));

app.MapGet("/api/checkout", () =>
    Results.Json(new { orderId = "CAL-10482", items = 3, total = 142.50, status = "confirmed" }));

app.MapGet("/api/search", (HttpRequest request, SearchService search) =>
    Results.Json(search.Browse(request.Query["page"].ToString())));

app.MapGet("/api/search/by-name", (HttpRequest request, SearchService search) =>
    Results.Json(search.SearchByName(request.Query["name"].ToString(), request.Query["page"].ToString())));

app.MapGet("/api/reports", (HttpRequest request, ReportingService reporting) =>
{
    var day = int.TryParse(request.Query["day"].ToString(), out var parsedDay) ? parsedDay : 1;
    return Results.Json(reporting.GetDailySales(day));
});

app.MapGet("/api/recommendations", (HttpRequest request, RecommendationEngine engine) =>
{
    var customerId = request.Query["customerId"].ToString();
    if (string.IsNullOrWhiteSpace(customerId))
    {
        customerId = "RETURNING-0001";
    }
    return Results.Json(engine.GetRecommendations(customerId));
});

// ---------------------------------------------------------------------------
// Lightweight, stable endpoints suitable for Application Insights
// Availability Tests - these are intentionally simple and always return a
// successful response so they can be used to generate steady background
// load/traffic without tripping any of the scenarios above.
// ---------------------------------------------------------------------------

app.MapGet("/api/ping", () => Results.Json(new { status = "ok", timestamp = DateTimeOffset.UtcNow.ToString("o") }));

app.MapGet("/api/version", () => Results.Json(new
{
    service = Service,
    version = "1.0.0",
    dotnetVersion = Environment.Version.ToString()
}));

app.MapGet("/api/store-locator", (HttpRequest request) =>
{
    var zip = request.Query["zip"].ToString();
    var stores = new[]
    {
        new { storeId = "CAL-STORE-101", city = "Denver", state = "CO", zip = "80202" },
        new { storeId = "CAL-STORE-204", city = "Bozeman", state = "MT", zip = "59715" },
        new { storeId = "CAL-STORE-317", city = "Asheville", state = "NC", zip = "28801" },
        new { storeId = "CAL-STORE-412", city = "Bend", state = "OR", zip = "97701" }
    };
    return Results.Json(new { zip, stores });
});

app.MapGet("/api/inventory-summary", () => Results.Json(new
{
    totalSkus = 2000,
    lowStockSkus = 37,
    warehouses = new[]
    {
        new { name = "North Warehouse", utilizationPct = 68 },
        new { name = "South Warehouse", utilizationPct = 52 }
    }
}));

app.MapFallbackToFile("index.html");

app.Run();
