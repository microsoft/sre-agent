using Microsoft.AspNetCore.Mvc;
using SREPerfDemo.Utilities;

namespace SREPerfDemo.Controllers;

[ApiController]
[Route("api/[controller]")]
public class SlowProductsController : ControllerBase
{
    private readonly ILogger<SlowProductsController> _logger;
    private static readonly List<Product> Products = GenerateProducts();

    public SlowProductsController(ILogger<SlowProductsController> logger)
    {
        _logger = logger;
    }

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Product>>> GetProducts()
    {
        _logger.LogInformation("Getting all products (slow version)");

        // Simulate very slow database query with excessive processing
        await Task.Delay(Random.Shared.Next(2000, 5000)); // 2-5 second delay!

        // Inefficient processing - sorting the entire list multiple times
        var sortedProducts = Products
            .OrderBy(p => p.Name)
            .ThenBy(p => p.Category)
            .ThenBy(p => p.Price)
            .ToList();

        // More unnecessary processing
        foreach (var product in sortedProducts)
        {
            // Simulate expensive computation
            var hash = product.Name.GetHashCode() + product.Category.GetHashCode();
            await Task.Delay(1); // Small delay per item adds up
        }

        return Ok(sortedProducts.Take(20));
    }

    [HttpGet("{id}")]
    public async Task<ActionResult<Product>> GetProduct(int id)
    {
        _logger.LogInformation("Getting product {ProductId} (slow version)", id);

        // Simulate N+1 query problem - multiple database calls
        for (int i = 0; i < 10; i++)
        {
            await Task.Delay(Random.Shared.Next(100, 300)); // Multiple slow queries
        }

        // Inefficient linear search instead of indexed lookup
        Product? product = null;
        await Task.Run(() =>
        {
            foreach (var p in Products)
            {
                if (p.Id == id)
                {
                    product = p;
                    break;
                }
                // Simulate work being done for each iteration
                Thread.Sleep(1);
            }
        });

        if (product == null)
        {
            return NotFound();
        }

        return Ok(product);
    }

    [HttpGet("search")]
    public async Task<ActionResult<IEnumerable<Product>>> SearchProducts([FromQuery] string query)
    {
        _logger.LogInformation("Searching products with query: {Query} (slow version)", query);

        // Simulate full table scan without indexing
        await Task.Delay(Random.Shared.Next(1500, 3000)); // 1.5-3 second delay

        if (string.IsNullOrWhiteSpace(query))
        {
            // Return random products with expensive computation
            var randomProducts = new List<Product>();
            await Task.Run(() =>
            {
                for (int i = 0; i < 10; i++)
                {
                    var randomIndex = Random.Shared.Next(Products.Count);
                    randomProducts.Add(Products[randomIndex]);

                    // Simulate expensive computation per product
                    var expensiveCalc = 0;
                    for (int j = 0; j < 100000; j++)
                    {
                        expensiveCalc += j * randomIndex;
                    }
                }
            });

            return Ok(randomProducts);
        }

        // Inefficient search with nested loops and expensive string operations
        var results = new List<Product>();
        await Task.Run(() =>
        {
            foreach (var product in Products)
            {
                // Expensive string operations
                var productText = $"{product.Name.ToLower()} {product.Category.ToLower()}";
                var queryWords = query.ToLower().Split(' ');

                foreach (var word in queryWords)
                {
                    if (productText.Contains(word))
                    {
                        results.Add(product);
                        break;
                    }
                }

                // Simulate additional expensive work per product
                var hash = 0;
                for (int i = 0; i < product.Name.Length * 1000; i++)
                {
                    hash += i;
                }
            }
        });

        return Ok(results.Take(10));
    }

    [HttpGet("memory-leak")]
    public async Task<ActionResult<string>> MemoryLeakEndpoint()
    {
        _logger.LogInformation("Triggering memory leak simulation");

        // Simulate memory leak by creating large objects that aren't properly disposed
        var largeList = new List<byte[]>();

        await Task.Run(() =>
        {
            for (int i = 0; i < 100; i++)
            {
                // Create 1MB byte arrays
                largeList.Add(new byte[1024 * 1024]);
                Thread.Sleep(10);
            }
        });

        // Don't dispose or clear the list - simulating a memory leak
        // In a real scenario, this might be stored in a static field
        StaticMemoryHolder.AddToMemory(largeList);

        return Ok($"Added {largeList.Count} MB to memory. Total static memory: {StaticMemoryHolder.GetMemoryCount()} MB");
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