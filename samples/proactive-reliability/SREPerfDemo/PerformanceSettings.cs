namespace SREPerfDemo;

public class PerformanceSettings
{
    // NOTE: EnableSlowEndpoints is now CODE-CONTROLLED in ProductsController.cs
    // It's hardcoded as a const: true for slow/unhealthy, false for fast/healthy
    // This allows slot swaps to change behavior (code swaps with the slot)
    
    public bool EnableCpuIntensiveEndpoints { get; set; } = false;
    public int ResponseTimeThresholdMs { get; set; } = 1000;
    public int CpuThresholdPercentage { get; set; } = 80;
    public int MemoryThresholdMB { get; set; } = 100;
}
