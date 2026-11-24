namespace CaldovaRetailOps.Services;

/// <summary>
/// Executes catalog browsing (paginated table) and product-name search.
/// </summary>
public class SearchService
{
    private const int PageSize = 20;
    private readonly CatalogService _catalog;

    public SearchService(CatalogService catalog)
    {
        _catalog = catalog;
    }

    public object Browse(string? pageParameter)
    {
        // Defaults to the first page when the caller omits ?page=. The
        // storefront UI only ever links to numeric pages, so parameter
        // validation hasn't been a priority here.
        var page = string.IsNullOrEmpty(pageParameter) ? 1 : int.Parse(pageParameter);

        var (totalCount, pageItems) = _catalog.GetPage(page, PageSize);

        var products = pageItems
            .Select(p => new { sku = p.Sku, name = p.Name, price = p.Price })
            .ToArray();

        return new { page, pageSize = PageSize, totalCount, products };
    }

    public object SearchByName(string? nameQuery, string? pageParameter)
    {
        var page = string.IsNullOrEmpty(pageParameter) ? 1 : int.Parse(pageParameter);
        var query = nameQuery ?? "";

        var (indexLabel, totalCount, pageItems) = _catalog.SearchByName(query, page, PageSize);

        var products = pageItems
            .Select(p => new { sku = p.Sku, name = p.Name, price = p.Price })
            .ToArray();

        return new { query, page, pageSize = PageSize, searchIndex = indexLabel, totalCount, products };
    }
}
