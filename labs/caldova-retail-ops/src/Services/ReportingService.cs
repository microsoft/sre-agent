namespace CaldovaRetailOps.Services;

/// <summary>
/// Returns the sales figure for a given day within a 7-day reporting window.
/// </summary>
public class ReportingService
{
    // Monday through Sunday, in order.
    private static readonly int[] SalesByDay = { 1200, 980, 1500, 1100, 1300, 1700, 2000 };

    public object GetDailySales(int day)
    {
        // Callers pass a 1-based day-of-week (1 = Monday ... 7 = Sunday).
        var sales = SalesByDay[day];
        return new { day, sales };
    }
}
