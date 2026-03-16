using System.Diagnostics;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;

public class PerformanceMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<PerformanceMiddleware> _logger;
    private readonly TelemetryClient _telemetryClient;
    private static DateTime _lastMetricsEmit = DateTime.MinValue;
    private static readonly object _metricsLock = new();

    public PerformanceMiddleware(RequestDelegate next, ILogger<PerformanceMiddleware> logger, TelemetryClient telemetryClient)
    {
        _next = next;
        _logger = logger;
        _telemetryClient = telemetryClient;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var stopwatch = Stopwatch.StartNew();

        try
        {
            await _next(context);
        }
        finally
        {
            stopwatch.Stop();
            var responseTimeMs = stopwatch.Elapsed.TotalMilliseconds;

            // Record for health checks
            PerformanceHealthCheck.RecordResponseTime(responseTimeMs);

            // Log performance data
            _logger.LogInformation("Request {Method} {Path} completed in {ResponseTime}ms with status {StatusCode}",
                context.Request.Method,
                context.Request.Path,
                Math.Round(responseTimeMs, 2),
                context.Response.StatusCode);

            // Add custom header for monitoring
            context.Response.Headers["X-Response-Time-Ms"] = responseTimeMs.ToString("F2");

            // Log slow requests
            if (responseTimeMs > 500)
            {
                _logger.LogWarning("Slow request detected: {Method} {Path} took {ResponseTime}ms",
                    context.Request.Method,
                    context.Request.Path,
                    Math.Round(responseTimeMs, 2));
            }

            // Emit custom metrics to App Insights every 30 seconds
            EmitRollingWindowMetrics();
        }
    }

    private void EmitRollingWindowMetrics()
    {
        lock (_metricsLock)
        {
            // Only emit every 30 seconds to avoid flooding
            if ((DateTime.UtcNow - _lastMetricsEmit).TotalSeconds < 30)
                return;

            _lastMetricsEmit = DateTime.UtcNow;
        }

        var snapshot = PerformanceHealthCheck.GetSnapshot();
        if (snapshot.SampleCount == 0)
            return;

        // Track rolling window metrics as custom metrics
        _telemetryClient.TrackMetric(new MetricTelemetry
        {
            Name = "perf_rolling_avg_ms",
            Sum = snapshot.AvgResponseTimeMs,
            Count = 1,
            Properties = { ["source"] = "rolling_window_100" }
        });

        _telemetryClient.TrackMetric(new MetricTelemetry
        {
            Name = "perf_rolling_p95_ms",
            Sum = snapshot.P95ResponseTimeMs,
            Count = 1,
            Properties = { ["source"] = "rolling_window_100" }
        });

        _telemetryClient.TrackMetric(new MetricTelemetry
        {
            Name = "perf_rolling_max_ms",
            Sum = snapshot.MaxResponseTimeMs,
            Count = 1,
            Properties = { ["source"] = "rolling_window_100" }
        });

        _telemetryClient.TrackMetric(new MetricTelemetry
        {
            Name = "perf_sample_count",
            Sum = snapshot.SampleCount,
            Count = 1
        });

        // Track baseline deviation if we have a baseline
        if (snapshot.BaselineAvgMs > 0)
        {
            var deviationPercent = ((snapshot.AvgResponseTimeMs - snapshot.BaselineAvgMs) / snapshot.BaselineAvgMs) * 100;
            _telemetryClient.TrackMetric(new MetricTelemetry
            {
                Name = "perf_baseline_deviation_percent",
                Sum = deviationPercent,
                Count = 1,
                Properties = { 
                    ["baseline_ms"] = snapshot.BaselineAvgMs.ToString("F2"),
                    ["current_ms"] = snapshot.AvgResponseTimeMs.ToString("F2")
                }
            });

            // Log significant deviations
            if (Math.Abs(deviationPercent) > 50)
            {
                _logger.LogWarning(
                    "Significant performance deviation detected: {DeviationPercent:F1}% from baseline. Current: {CurrentMs:F2}ms, Baseline: {BaselineMs:F2}ms",
                    deviationPercent, snapshot.AvgResponseTimeMs, snapshot.BaselineAvgMs);
            }
        }

        // Track health status as event
        _telemetryClient.TrackEvent("PerformanceSnapshot", new Dictionary<string, string>
        {
            ["status"] = snapshot.Status,
            ["avgMs"] = snapshot.AvgResponseTimeMs.ToString("F2"),
            ["p95Ms"] = snapshot.P95ResponseTimeMs.ToString("F2"),
            ["maxMs"] = snapshot.MaxResponseTimeMs.ToString("F2"),
            ["sampleCount"] = snapshot.SampleCount.ToString(),
            ["baselineMs"] = snapshot.BaselineAvgMs.ToString("F2"),
            ["deviationPercent"] = snapshot.BaselineAvgMs > 0 
                ? (((snapshot.AvgResponseTimeMs - snapshot.BaselineAvgMs) / snapshot.BaselineAvgMs) * 100).ToString("F1")
                : "N/A"
        });
    }
}