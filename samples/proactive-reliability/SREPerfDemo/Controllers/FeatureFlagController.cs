using Microsoft.AspNetCore.Mvc;

namespace SREPerfDemo.Controllers;

[ApiController]
[Route("api/[controller]")]
public class FeatureFlagController : ControllerBase
{
    private readonly ILogger<FeatureFlagController> _logger;
    private readonly IConfiguration _configuration;

    public FeatureFlagController(ILogger<FeatureFlagController> logger, IConfiguration configuration)
    {
        _logger = logger;
        _configuration = configuration;
    }

    [HttpGet("performance-mode")]
    public ActionResult<object> GetPerformanceMode()
    {
        var slowEndpointsEnabled = _configuration.GetValue<bool>("PerformanceSettings:EnableSlowEndpoints");
        var cpuIntensiveEnabled = _configuration.GetValue<bool>("PerformanceSettings:EnableCpuIntensiveEndpoints");
        var responseThreshold = _configuration.GetValue<int>("PerformanceSettings:ResponseTimeThresholdMs");

        return Ok(new
        {
            SlowEndpointsEnabled = slowEndpointsEnabled,
            CpuIntensiveEndpointsEnabled = cpuIntensiveEnabled,
            ResponseTimeThresholdMs = responseThreshold,
            Mode = cpuIntensiveEnabled ? "CPU-Intensive Performance" : slowEndpointsEnabled ? "Degraded Performance" : "Good Performance",
            Timestamp = DateTime.UtcNow
        });
    }

    [HttpPost("enable-slow-mode")]
    public ActionResult EnableSlowMode()
    {
        _logger.LogWarning("PERFORMANCE DEGRADATION: Slow mode has been enabled manually via API");

        // In a real app, this would update a feature flag service
        // For demo purposes, we'll just log this action
        return Ok(new
        {
            Message = "Slow mode enabled. This would typically update a feature flag service.",
            Warning = "This will cause performance degradation in the application.",
            Timestamp = DateTime.UtcNow
        });
    }

    [HttpPost("disable-slow-mode")]
    public ActionResult DisableSlowMode()
    {
        _logger.LogInformation("PERFORMANCE RECOVERY: Slow mode has been disabled manually via API");

        return Ok(new
        {
            Message = "Slow mode disabled. Performance should return to normal.",
            Timestamp = DateTime.UtcNow
        });
    }

    [HttpPost("enable-cpu-intensive-mode")]
    public ActionResult EnableCpuIntensiveMode()
    {
        _logger.LogWarning("CPU INTENSIVE MODE: CPU-intensive operations have been enabled manually via API");

        return Ok(new
        {
            Message = "CPU-intensive mode enabled. This will cause high CPU usage and performance degradation.",
            Warning = "This will cause high CPU usage and performance degradation in the application.",
            Timestamp = DateTime.UtcNow
        });
    }

    [HttpPost("disable-cpu-intensive-mode")]
    public ActionResult DisableCpuIntensiveMode()
    {
        _logger.LogInformation("CPU INTENSIVE MODE DISABLED: CPU-intensive operations have been disabled manually via API");

        return Ok(new
        {
            Message = "CPU-intensive mode disabled. Performance should return to normal.",
            Timestamp = DateTime.UtcNow
        });
    }

    [HttpGet("metrics")]
    public ActionResult<object> GetMetrics()
    {
        // Get current performance data
        var memoryUsage = GC.GetTotalMemory(false);
        var gen0Collections = GC.CollectionCount(0);
        var gen1Collections = GC.CollectionCount(1);
        var gen2Collections = GC.CollectionCount(2);

        return Ok(new
        {
            MemoryUsage = new
            {
                TotalMemoryBytes = memoryUsage,
                TotalMemoryMB = Math.Round(memoryUsage / (1024.0 * 1024.0), 2)
            },
            GarbageCollection = new
            {
                Gen0Collections = gen0Collections,
                Gen1Collections = gen1Collections,
                Gen2Collections = gen2Collections
            },
            Timestamp = DateTime.UtcNow
        });
    }

    [HttpGet("error-spike")]
    public ActionResult ErrorSpike()
    {
        // Simulate error spike to trigger Failure Anomaly detection
        // 85% error rate to guarantee Smart Detection fires
        var random = Random.Shared.Next(100);

        if (random < 85)
        {
            _logger.LogError("SIMULATED ERROR SPIKE: Intentional error for Failure Anomaly detection (random={Random})", random);

            // Vary the error types to simulate realistic failure scenarios
            if (random < 30)
            {
                return StatusCode(500, new {
                    error = "Internal Server Error",
                    message = "Database connection failed",
                    timestamp = DateTime.UtcNow,
                    errorCode = "DB_CONNECTION_FAILED"
                });
            }
            else if (random < 60)
            {
                return StatusCode(503, new {
                    error = "Service Unavailable",
                    message = "Downstream service timeout",
                    timestamp = DateTime.UtcNow,
                    errorCode = "SERVICE_TIMEOUT"
                });
            }
            else
            {
                throw new InvalidOperationException("Simulated unhandled exception for failure anomaly detection");
            }
        }

        return Ok(new {
            message = "Success",
            timestamp = DateTime.UtcNow,
            note = "This endpoint randomly generates errors to trigger Smart Detection"
        });
    }
}