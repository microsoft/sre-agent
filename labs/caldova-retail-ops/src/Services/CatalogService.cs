using System.Text.Json;
using System.Text.Json.Serialization;

namespace CaldovaRetailOps.Services;

public class CatalogProduct
{
    [JsonPropertyName("sku")]
    public string Sku { get; set; } = "";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("price")]
    public double Price { get; set; }
}

public class SearchIndexWave
{
    [JsonPropertyName("label")]
    public string Label { get; set; } = "";

    [JsonPropertyName("effectiveDate")]
    public DateTime EffectiveDate { get; set; }

    // Null when the search team has staged a future wave's metadata ahead
    // of its launch but hasn't finished building that wave's search index
    // yet. The main product catalog (Data/products.json) is a completely
    // separate, always-populated feed - only the *search* index is staged
    // per wave, so browsing is unaffected even when a wave's index is null.
    [JsonPropertyName("products")]
    public List<CatalogProduct>? Products { get; set; }
}

/// <summary>
/// Serves the storefront's product catalog for two independent features:
///   - Browsing (paginated table): always reads the live product feed
///     (Data/products.json), unaffected by search-index staging.
///   - Searching by product name: reads a dated "search index wave"
///     (Data/catalog-waves.json). The App Setting <c>Catalog__AsOfDate</c>
///     (normally unset, defaulting to the current date) controls which
///     wave's search index is considered active "as of" a given date.
/// </summary>
public class CatalogService
{
    private readonly List<CatalogProduct> _liveCatalog;
    private readonly List<SearchIndexWave> _searchIndexWaves;

    public CatalogService(IConfiguration configuration)
    {
        var dataDir = Path.Combine(AppContext.BaseDirectory, "Data");

        var productsJson = File.ReadAllText(Path.Combine(dataDir, "products.json"));
        _liveCatalog = JsonSerializer.Deserialize<List<CatalogProduct>>(productsJson) ?? new List<CatalogProduct>();

        var wavesJson = File.ReadAllText(Path.Combine(dataDir, "catalog-waves.json"));
        _searchIndexWaves = JsonSerializer.Deserialize<List<SearchIndexWave>>(wavesJson) ?? new List<SearchIndexWave>();

        Configuration = configuration;
    }

    private IConfiguration Configuration { get; }

    /// <summary>
    /// Paginated browse of the always-available live product catalog.
    /// Not affected by Catalog__AsOfDate.
    /// </summary>
    public (int TotalCount, List<CatalogProduct> Products) GetPage(int page, int pageSize)
    {
        var pageItems = _liveCatalog
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .ToList();

        return (_liveCatalog.Count, pageItems);
    }

    private SearchIndexWave GetActiveSearchIndexWave()
    {
        var asOfSetting = Configuration["Catalog:AsOfDate"];
        var asOf = !string.IsNullOrWhiteSpace(asOfSetting) && DateTime.TryParse(asOfSetting, out var parsed)
            ? parsed
            : DateTime.UtcNow;

        // Pick the most recent wave whose effective date has arrived. If a
        // future wave's effective date has been reached by an incorrectly
        // forward-dated Catalog__AsOfDate, its search index becomes
        // "active" even though it hasn't been built yet.
        return _searchIndexWaves
            .Where(w => w.EffectiveDate <= asOf)
            .OrderByDescending(w => w.EffectiveDate)
            .First();
    }

    /// <summary>
    /// Search by product name against the active search index wave. Direct
    /// passing a null Products list to LINQ throws an ArgumentNullException
    /// when a staged wave's search index hasn't been built yet - the realistic
    /// failure mode when Catalog__AsOfDate is mistakenly pointed at a future wave.
    /// </summary>
    public (string IndexLabel, int TotalCount, List<CatalogProduct> Products) SearchByName(string nameQuery, int page, int pageSize)
    {
        var wave = GetActiveSearchIndexWave();

        var matches = wave.Products
            .Where(p => p.Name.Contains(nameQuery, StringComparison.OrdinalIgnoreCase))
            .ToList();

        var pageItems = matches
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .ToList();

        return (wave.Label, matches.Count, pageItems);
    }
}
