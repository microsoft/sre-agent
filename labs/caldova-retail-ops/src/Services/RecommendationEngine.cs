namespace CaldovaRetailOps.Services;

/// <summary>
/// Scores catalog recommendations for a customer using a per-segment
/// weighting model. Models are trained offline on a nightly schedule and
/// loaded into memory; a segment's weights stay <c>null</c> here until its
/// first model has finished training and been published.
/// </summary>
public class RecommendationEngine
{
    private static readonly Dictionary<string, double[]?> SegmentModels = new()
    {
        ["returning"] = new[] { 0.8, 0.6, 0.4 },
        ["loyalty"] = new[] { 0.9, 0.7, 0.5 },
        // The "new" segment (customers who signed up in the last 24 hours)
        // only gets a trained model once nightly scoring has run for them at
        // least once; until then this stays unset.
        ["new"] = null
    };

    private static readonly (string Sku, string Name, double Price)[] Catalog =
    {
        ("CAL-055", "Insulated Gloves", 32.00),
        ("CAL-061", "Wool Base Layer", 48.00),
        ("CAL-073", "Thermal Beanie", 18.00)
    };

    public string ResolveSegment(string customerId) =>
        customerId.StartsWith("NEW-", StringComparison.OrdinalIgnoreCase) ? "new" :
        customerId.StartsWith("VIP-", StringComparison.OrdinalIgnoreCase) ? "loyalty" :
        "returning";

    public object GetRecommendations(string customerId)
    {
        var segment = ResolveSegment(customerId);
        var weights = SegmentModels[segment];

        var scored = Catalog
            .Select((item, index) => new
            {
                item,
                // Every segment is expected to have a trained model by the
                // time customers reach this code path.
                score = weights[index % weights.Length]
            })
            .OrderByDescending(x => x.score)
            .Select(x => new { sku = x.item.Sku, name = x.item.Name, price = x.item.Price })
            .ToArray();

        return new { customerId, segment, items = scored };
    }
}
