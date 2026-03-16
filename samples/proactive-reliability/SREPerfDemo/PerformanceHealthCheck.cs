using Microsoft.Extensions.Diagnostics.HealthChecks;
using System.Diagnostics;

public class PerformanceHealthCheck : IHealthCheck
{
    private static readonly List<double> ResponseTimes = new();
    private static readonly object Lock = new();
    
    // Baseline tracking - established from first 100 "healthy" requests or manually set
    private static double _baselineAvgMs = 0;
    private static bool _baselineEstablished = false;
    private static readonly List<double> _baselineWindow = new();

    public static void RecordResponseTime(double responseTimeMs)
    {
        lock (Lock)
        {
            ResponseTimes.Add(responseTimeMs);
            // Keep only last 100 measurements
            if (ResponseTimes.Count > 100)
            {
                ResponseTimes.RemoveAt(0);
            }

            // Auto-establish baseline from first 100 requests if they're fast (<500ms avg)
            if (!_baselineEstablished)
            {
                _baselineWindow.Add(responseTimeMs);
                if (_baselineWindow.Count >= 100)
                {
                    var avgBaseline = _baselineWindow.Average();
                    // Only set baseline if it looks healthy (< 500ms)
                    if (avgBaseline < 500)
                    {
                        _baselineAvgMs = avgBaseline;
                        _baselineEstablished = true;
                    }
                    else
                    {
                        // Reset and try again with fresh data
                        _baselineWindow.Clear();
                    }
                }
            }
        }
    }

    /// <summary>
    /// Manually set the baseline average (useful for SRE Agent to set known-good baseline)
    /// </summary>
    public static void SetBaseline(double baselineAvgMs)
    {
        lock (Lock)
        {
            _baselineAvgMs = baselineAvgMs;
            _baselineEstablished = true;
        }
    }

    /// <summary>
    /// Reset baseline to allow re-establishment
    /// </summary>
    public static void ResetBaseline()
    {
        lock (Lock)
        {
            _baselineAvgMs = 0;
            _baselineEstablished = false;
            _baselineWindow.Clear();
        }
    }

    /// <summary>
    /// Get current snapshot of performance metrics including baseline
    /// </summary>
    public static PerformanceSnapshot GetSnapshot()
    {
        lock (Lock)
        {
            if (ResponseTimes.Count == 0)
            {
                return new PerformanceSnapshot
                {
                    SampleCount = 0,
                    Status = "Unknown",
                    BaselineAvgMs = _baselineAvgMs,
                    BaselineEstablished = _baselineEstablished
                };
            }

            var sorted = ResponseTimes.OrderBy(x => x).ToList();
            var avg = ResponseTimes.Average();
            var p95Index = (int)(sorted.Count * 0.95);
            var p95 = sorted.Count > 0 ? sorted[Math.Min(p95Index, sorted.Count - 1)] : 0;

            string status;
            if (avg > 1000) status = "Unhealthy";
            else if (p95 > 2000) status = "Degraded";
            else status = "Healthy";

            return new PerformanceSnapshot
            {
                SampleCount = ResponseTimes.Count,
                AvgResponseTimeMs = Math.Round(avg, 2),
                P95ResponseTimeMs = Math.Round(p95, 2),
                MaxResponseTimeMs = Math.Round(ResponseTimes.Max(), 2),
                MinResponseTimeMs = Math.Round(ResponseTimes.Min(), 2),
                Status = status,
                BaselineAvgMs = Math.Round(_baselineAvgMs, 2),
                BaselineEstablished = _baselineEstablished
            };
        }
    }

    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        lock (Lock)
        {
            if (ResponseTimes.Count == 0)
            {
                return Task.FromResult(HealthCheckResult.Healthy("No response time data available yet"));
            }

            var avgResponseTime = ResponseTimes.Average();
            var maxResponseTime = ResponseTimes.Max();
            var p95ResponseTime = ResponseTimes.OrderBy(x => x).Skip((int)(ResponseTimes.Count * 0.95)).FirstOrDefault();

            var data = new Dictionary<string, object>
            {
                { "avgResponseTimeMs", Math.Round(avgResponseTime, 2) },
                { "maxResponseTimeMs", Math.Round(maxResponseTime, 2) },
                { "p95ResponseTimeMs", Math.Round(p95ResponseTime, 2) },
                { "sampleCount", ResponseTimes.Count }
            };

            // Performance thresholds
            if (avgResponseTime > 1000) // 1 second average
            {
                return Task.FromResult(HealthCheckResult.Unhealthy(
                    $"Average response time is too high: {avgResponseTime:F2}ms",
                    data: data));
            }

            if (p95ResponseTime > 2000) // 2 seconds for 95th percentile
            {
                return Task.FromResult(HealthCheckResult.Degraded(
                    $"95th percentile response time is high: {p95ResponseTime:F2}ms",
                    data: data));
            }

            return Task.FromResult(HealthCheckResult.Healthy(
                $"Performance is good. Avg: {avgResponseTime:F2}ms, P95: {p95ResponseTime:F2}ms",
                data: data));
        }
    }
}

/// <summary>
/// Snapshot of current performance metrics including baseline comparison
/// </summary>
public class PerformanceSnapshot
{
    public int SampleCount { get; set; }
    public double AvgResponseTimeMs { get; set; }
    public double P95ResponseTimeMs { get; set; }
    public double MaxResponseTimeMs { get; set; }
    public double MinResponseTimeMs { get; set; }
    public string Status { get; set; } = "Unknown";
    public double BaselineAvgMs { get; set; }
    public bool BaselineEstablished { get; set; }
    
    public double? DeviationPercent => BaselineAvgMs > 0 
        ? Math.Round(((AvgResponseTimeMs - BaselineAvgMs) / BaselineAvgMs) * 100, 2) 
        : null;
}