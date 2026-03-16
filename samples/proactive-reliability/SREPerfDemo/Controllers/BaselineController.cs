using Microsoft.AspNetCore.Mvc;

namespace SREPerfDemo.Controllers;

/// <summary>
/// Endpoint for SRE Agent to query and manage performance baselines
/// </summary>
[ApiController]
[Route("api/[controller]")]
public class BaselineController : ControllerBase
{
    private readonly ILogger<BaselineController> _logger;

    public BaselineController(ILogger<BaselineController> logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Get current performance snapshot including baseline deviation
    /// SRE Agent can call this every 15 mins to check for anomalies
    /// </summary>
    [HttpGet]
    public IActionResult GetSnapshot()
    {
        var snapshot = PerformanceHealthCheck.GetSnapshot();
        
        return Ok(new
        {
            timestamp = DateTime.UtcNow,
            metrics = new
            {
                sampleCount = snapshot.SampleCount,
                avgResponseTimeMs = snapshot.AvgResponseTimeMs,
                p95ResponseTimeMs = snapshot.P95ResponseTimeMs,
                maxResponseTimeMs = snapshot.MaxResponseTimeMs,
                minResponseTimeMs = snapshot.MinResponseTimeMs,
                status = snapshot.Status
            },
            baseline = new
            {
                established = snapshot.BaselineEstablished,
                avgMs = snapshot.BaselineAvgMs,
                deviationPercent = snapshot.DeviationPercent
            },
            alerts = new
            {
                significantDeviation = snapshot.DeviationPercent.HasValue && Math.Abs(snapshot.DeviationPercent.Value) > 50,
                isUnhealthy = snapshot.Status == "Unhealthy",
                isDegraded = snapshot.Status == "Degraded",
                requiresRollback = snapshot.DeviationPercent.HasValue && snapshot.DeviationPercent.Value > 100 // 2x slower than baseline
            }
        });
    }

    /// <summary>
    /// Set baseline from current rolling window (call when app is known to be healthy)
    /// </summary>
    [HttpPost("establish")]
    public IActionResult EstablishBaseline()
    {
        var snapshot = PerformanceHealthCheck.GetSnapshot();
        
        if (snapshot.SampleCount < 10)
        {
            return BadRequest(new { error = "Need at least 10 samples to establish baseline", currentSamples = snapshot.SampleCount });
        }

        PerformanceHealthCheck.SetBaseline(snapshot.AvgResponseTimeMs);
        
        _logger.LogInformation("Baseline established at {BaselineMs}ms from {SampleCount} samples", 
            snapshot.AvgResponseTimeMs, snapshot.SampleCount);
        
        return Ok(new
        {
            message = "Baseline established",
            baselineMs = snapshot.AvgResponseTimeMs,
            fromSamples = snapshot.SampleCount
        });
    }

    /// <summary>
    /// Manually set baseline value (for SRE Agent to set known-good value)
    /// </summary>
    [HttpPost("set")]
    public IActionResult SetBaseline([FromBody] SetBaselineRequest request)
    {
        if (request.BaselineMs <= 0)
        {
            return BadRequest(new { error = "Baseline must be positive" });
        }

        PerformanceHealthCheck.SetBaseline(request.BaselineMs);
        
        _logger.LogInformation("Baseline manually set to {BaselineMs}ms", request.BaselineMs);
        
        return Ok(new
        {
            message = "Baseline set",
            baselineMs = request.BaselineMs
        });
    }

    /// <summary>
    /// Reset baseline to allow re-establishment
    /// </summary>
    [HttpPost("reset")]
    public IActionResult ResetBaseline()
    {
        PerformanceHealthCheck.ResetBaseline();
        
        _logger.LogInformation("Baseline reset");
        
        return Ok(new { message = "Baseline reset" });
    }
}

public class SetBaselineRequest
{
    public double BaselineMs { get; set; }
}
