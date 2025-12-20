namespace SREPerfDemo.Utilities;

// Simulates static memory leaks
public static class StaticMemoryHolder
{
    private static readonly List<List<byte[]>> MemoryStorage = new();

    public static void AddToMemory(List<byte[]> data)
    {
        MemoryStorage.Add(data);
    }

    public static int GetMemoryCount()
    {
        return MemoryStorage.Sum(list => list.Count);
    }
}