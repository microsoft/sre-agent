using Microsoft.AspNetCore.Mvc;

namespace SREPerfDemo.Controllers;

[ApiController]
[Route("api/[controller]")]
public class ProductsController : ControllerBase
{
    private readonly ILogger<ProductsController> _logger;
    private static readonly List<Product> Products = GenerateProducts();

    // ============================================================
    // DEPLOYMENT FLAG - Controls slow/fast behavior
    // ============================================================
    // Set to TRUE for unhealthy deployment (slow N+1 queries)
    // Set to FALSE for healthy deployment (optimized queries)
    // This flag is CODE-CONTROLLED, not via app settings.
    // After a slot swap, the code changes and behavior changes with it.
    // ============================================================
    private const bool EnableSlowEndpoints = false;  // VERSION 3.0 - Improved with better logging and metrics

    public ProductsController(ILogger<ProductsController> logger)
    {
        _logger = logger;
    }

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Product>>> GetProducts()
    {
        _logger.LogInformation("Getting all products (SlowMode: {SlowMode})", EnableSlowEndpoints);

        if (EnableSlowEndpoints)
        {
            // BAD DEPLOYMENT: Inefficient N+1 query pattern with CPU-intensive processing
            // This simulates a developer accidentally removing query optimization
            var result = new List<Product>();
            foreach (var product in Products.Take(20))
            {
                // Simulate inefficient individual lookups instead of batch query
                await Task.Delay(Random.Shared.Next(50, 150)); // Each item takes 50-150ms
                
                // CPU-intensive "validation" that was added in bad deployment
                PerformExpensiveValidation(product);
                result.Add(product);
            }
            return Ok(result);
        }
        else
        {
            // HEALTHY: Optimized batch query with caching
            await Task.Delay(Random.Shared.Next(10, 50)); // 10-50ms delay
            return Ok(Products.Take(20));
        }
    }

    [HttpGet("{id}")]
    public async Task<ActionResult<Product>> GetProduct(int id)
    {
        _logger.LogInformation("Getting product {ProductId} (SlowMode: {SlowMode})", id, EnableSlowEndpoints);

        if (EnableSlowEndpoints)
        {
            // BAD DEPLOYMENT: Missing index, full table scan simulation
            await Task.Delay(Random.Shared.Next(200, 500)); // 200-500ms delay
            
            // Expensive "security check" added in bad deployment
            foreach (var p in Products)
            {
                PerformExpensiveValidation(p);
                if (p.Id == id)
                {
                    return Ok(p);
                }
            }
            return NotFound();
        }
        else
        {
            // HEALTHY: Indexed lookup
            await Task.Delay(Random.Shared.Next(5, 25)); // 5-25ms delay
            var product = Products.FirstOrDefault(p => p.Id == id);
            if (product == null)
            {
                return NotFound();
            }
            return Ok(product);
        }
    }

    [HttpGet("search")]
    public async Task<ActionResult<IEnumerable<Product>>> SearchProducts([FromQuery] string query)
    {
        _logger.LogInformation("Searching products with query: {Query} (SlowMode: {SlowMode})", query, EnableSlowEndpoints);

        if (EnableSlowEndpoints)
        {
            // BAD DEPLOYMENT: Removed search index, doing full text scan with regex
            await Task.Delay(Random.Shared.Next(500, 1500)); // 500-1500ms delay
            
            // CPU-intensive search without optimization
            var results = new List<Product>();
            foreach (var p in Products)
            {
                PerformExpensiveValidation(p);
                if (string.IsNullOrWhiteSpace(query) || 
                    p.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    p.Category.Contains(query, StringComparison.OrdinalIgnoreCase))
                {
                    results.Add(p);
                    if (results.Count >= 10) break;
                }
            }
            return Ok(results);
        }
        else
        {
            // HEALTHY: Indexed search
            await Task.Delay(Random.Shared.Next(20, 100)); // 20-100ms delay

            if (string.IsNullOrWhiteSpace(query))
            {
                return Ok(Products.Take(10));
            }

            var results = Products
                .Where(p => p.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                           p.Category.Contains(query, StringComparison.OrdinalIgnoreCase))
                .Take(10);

            return Ok(results);
        }
    }

    /// <summary>
    /// Simulates an expensive validation that was added in a bad deployment
    /// This represents a developer adding "security checks" without considering performance
    /// </summary>
    private void PerformExpensiveValidation(Product product)
    {
        // CPU-intensive operations that simulate a poorly optimized validation
        for (int i = 0; i < 100000; i++)
        {
            var hash = $"{product.Name}_{product.Id}_{i}".GetHashCode();
            var check = Math.Sqrt(hash) * Math.Sin(i);
        }
    }

    private static List<Product> GenerateProducts()
    {
        var categories = new[] { "Electronics", "Clothing", "Books", "Home", "Sports", "Food" };
        var products = new List<Product>();

        for (int i = 1; i <= 1000; i++)
        {
            products.Add(new Product
            {
                Id = i,
                Name = $"Product {i}",
                Category = categories[Random.Shared.Next(categories.Length)],
                Price = Math.Round(Random.Shared.NextDouble() * 1000, 2),
                InStock = Random.Shared.Next(0, 100) > 20
            });
        }

        return products;
    }
}

public class Product
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public double Price { get; set; }
    public bool InStock { get; set; }
}




