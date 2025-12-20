using Microsoft.AspNetCore.Mvc;
using SREPerfDemo.Utilities;

namespace SREPerfDemo.Controllers;

[ApiController]
[Route("api/[controller]")]
public class CpuIntensiveController : ControllerBase
{
    private readonly ILogger<CpuIntensiveController> _logger;
    private static readonly List<Product> Products = GenerateProducts();

    public CpuIntensiveController(ILogger<CpuIntensiveController> logger)
    {
        _logger = logger;
    }

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Product>>> GetProducts()
    {
        _logger.LogInformation("Getting all products (CPU-intensive version)");

        // Simulate CPU-intensive processing
        await Task.Run(() =>
        {
            // CPU-intensive operations that will cause high CPU usage
            for (int i = 0; i < 1000000; i++)
            {
                // Expensive mathematical operations
                var result = Math.Sqrt(i) * Math.Pow(i, 2) + Math.Sin(i) * Math.Cos(i);
                
                // String operations that consume CPU
                var hash = $"product_{i}_{result}".GetHashCode();
                
                // More CPU work
                if (i % 10000 == 0)
                {
                    Thread.Sleep(1); // Brief pause to allow other threads
                }
            }
        });

        // Additional CPU work - sorting with expensive comparison
        var sortedProducts = Products
            .OrderBy(p => ExpensiveHash(p.Name))
            .ThenBy(p => ExpensiveHash(p.Category))
            .ToList();

        return Ok(sortedProducts.Take(20));
    }

    [HttpGet("{id}")]
    public async Task<ActionResult<Product>> GetProduct(int id)
    {
        _logger.LogInformation("Getting product {ProductId} (CPU-intensive version)", id);

        // CPU-intensive N+1 simulation
        await Task.Run(() =>
        {
            for (int i = 0; i < 20; i++)
            {
                // Expensive computation per iteration
                var expensiveResult = 0;
                for (int j = 0; j < 100000; j++)
                {
                    expensiveResult += j * i * id;
                }
                
                // String processing
                var hash = $"product_{id}_{i}_{expensiveResult}".GetHashCode();
                
                Thread.Sleep(10); // Small delay to accumulate CPU time
            }
        });

        // Inefficient linear search with CPU work
        Product? product = null;
        await Task.Run(() =>
        {
            foreach (var p in Products)
            {
                // CPU-intensive comparison
                var comparisonHash = ExpensiveHash(p.Name + p.Category);
                if (p.Id == id && comparisonHash % 2 == 0)
                {
                    product = p;
                    break;
                }
                
                // Additional CPU work per iteration
                var work = 0;
                for (int i = 0; i < 1000; i++)
                {
                    work += i * p.Id;
                }
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
        _logger.LogInformation("Searching products with query: {Query} (CPU-intensive version)", query);

        // CPU-intensive search simulation
        await Task.Run(() =>
        {
            // Expensive preprocessing
            for (int i = 0; i < 500000; i++)
            {
                var result = Math.Pow(i, 1.5) + Math.Log(i + 1);
                var hash = $"search_{query}_{i}_{result}".GetHashCode();
                
                if (i % 50000 == 0)
                {
                    Thread.Sleep(5);
                }
            }
        });

        if (string.IsNullOrWhiteSpace(query))
        {
            // CPU-intensive random selection
            var randomProducts = new List<Product>();
            await Task.Run(() =>
            {
                for (int i = 0; i < 10; i++)
                {
                    var randomIndex = Random.Shared.Next(Products.Count);
                    var product = Products[randomIndex];

                    // CPU-intensive processing per product
                    var expensiveCalc = 0;
                    for (int j = 0; j < 200000; j++)
                    {
                        expensiveCalc += j * randomIndex * ExpensiveHash(product.Name);
                    }

                    randomProducts.Add(product);
                }
            });

            return Ok(randomProducts);
        }

        // CPU-intensive search with expensive string operations
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
                    // CPU-intensive string matching
                    var matchScore = 0;
                    for (int i = 0; i < productText.Length; i++)
                    {
                        for (int j = 0; j < word.Length; j++)
                        {
                            if (i + j < productText.Length && productText[i + j] == word[j])
                            {
                                matchScore += ExpensiveHash($"{i}_{j}_{productText[i + j]}");
                            }
                        }
                    }

                    if (matchScore > 1000) // Arbitrary threshold
                    {
                        results.Add(product);
                        break;
                    }
                }

                // Additional CPU work per product
                var hash = 0;
                for (int i = 0; i < product.Name.Length * 10000; i++)
                {
                    hash += i * ExpensiveHash(product.Name);
                }
            }
        });

        return Ok(results.Take(10));
    }

    [HttpGet("cpu-stress")]
    public async Task<ActionResult<string>> CpuStressTest()
    {
        _logger.LogInformation("Running CPU stress test");

        var startTime = DateTime.UtcNow;
        var iterations = 0;

        await Task.Run(() =>
        {
            var endTime = startTime.AddSeconds(30); // Run for 30 seconds
            
            while (DateTime.UtcNow < endTime)
            {
                // CPU-intensive mathematical operations
                var result = 0.0;
                for (int i = 0; i < 10000; i++)
                {
                    result += Math.Sqrt(i) * Math.Pow(i, 2) + Math.Sin(i) * Math.Cos(i);
                }

                // String processing
                var hash = $"stress_{iterations}_{result}".GetHashCode();
                
                // Memory allocation to stress GC
                var largeArray = new int[1000];
                for (int i = 0; i < largeArray.Length; i++)
                {
                    largeArray[i] = hash + i;
                }

                iterations++;
                
                // Brief pause to prevent complete CPU lock
                if (iterations % 1000 == 0)
                {
                    Thread.Sleep(1);
                }
            }
        });

        var duration = DateTime.UtcNow - startTime;
        return Ok($"CPU stress test completed. Iterations: {iterations}, Duration: {duration.TotalSeconds:F2}s, CPU usage should be high");
    }

    [HttpGet("memory-cpu-leak")]
    public async Task<ActionResult<string>> MemoryCpuLeak()
    {
        _logger.LogInformation("Triggering memory and CPU leak simulation");

        // Create memory leak with CPU-intensive operations
        var leakData = new List<byte[]>();
        var cpuWork = 0;

        await Task.Run(() =>
        {
            for (int i = 0; i < 50; i++)
            {
                // Create 2MB byte arrays
                leakData.Add(new byte[2 * 1024 * 1024]);
                
                // CPU-intensive work while allocating memory
                for (int j = 0; j < 100000; j++)
                {
                    cpuWork += j * i * ExpensiveHash($"leak_{i}_{j}");
                }
                
                Thread.Sleep(20);
            }
        });

        // Store in static holder to simulate memory leak
        StaticMemoryHolder.AddToMemory(leakData);

        return Ok($"Memory leak created: {leakData.Count * 2} MB allocated. CPU work: {cpuWork}. Total static memory: {StaticMemoryHolder.GetMemoryCount()} MB");
    }

    private static int ExpensiveHash(string input)
    {
        var hash = 0;
        for (int i = 0; i < input.Length; i++)
        {
            for (int j = 0; j < 1000; j++)
            {
                hash += input[i] * j + i;
            }
        }
        return hash;
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
