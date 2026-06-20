$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=sql-zava.database.windows.net;Database=sqldb-zava;Encrypt=True;TrustServerCertificate=False"
$conn.AccessToken = $token
$conn.Open()

Write-Output "Connected. Running expensive queries to spike DTU..."

for ($i = 1; $i -le 5; $i++) {
    Write-Output "Query batch $i/5..."
    $cmd = $conn.CreateCommand()
    $cmd.CommandTimeout = 120
    $cmd.CommandText = "SELECT TOP 1000 p1.Name, p1.Category, p1.Price, p2.Name, p2.Price FROM Products p1 CROSS JOIN Products p2 WHERE p1.Category = p2.Category AND p1.Id <> p2.Id ORDER BY p1.Price DESC, p2.Price ASC"
    try {
        $null = $cmd.ExecuteNonQuery()
        Write-Output "  Batch $i complete"
    } catch {
        Write-Output "  Batch $i error"
    }
}

Write-Output "Running continuous load for 3 minutes..."

$endTime = (Get-Date).AddMinutes(3)
$count = 0
while ((Get-Date) -lt $endTime) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandTimeout = 60
    $cmd.CommandText = "SELECT COUNT(*) FROM Products p1 CROSS JOIN Products p2 WHERE p1.Category = 'Espresso' AND p2.Category = 'Pastries'"
    try {
        $null = $cmd.ExecuteScalar()
        $count++
    } catch {}
    if ($count % 10 -eq 0) { Write-Output "  $count queries..." }
}

$conn.Close()
Write-Output "Done. $count queries executed. Alert should fire within 5 minutes."
