# Continuous slow query simulation
# Keeps querying Products by Category (no index) and measures response time
# When SRE Agent creates the index, times should drop dramatically

$token = az account get-access-token --resource https://database.windows.net --query accessToken -o tsv

$conn = New-Object System.Data.SqlClient.SqlConnection
$conn.ConnectionString = "Server=sql-zava.database.windows.net;Database=sqldb-zava;Encrypt=True;TrustServerCertificate=True"
$conn.AccessToken = $token
$conn.Open()

Write-Output "=== Continuous Category Query Simulation ==="
Write-Output "Querying Products WHERE Category = 'Espresso' every 3 seconds"
Write-Output "Watch for response time to drop when SRE Agent creates the index"
Write-Output "Press Ctrl+C to stop"
Write-Output ""
Write-Output "Time                  | Duration (ms) | Rows | Status"
Write-Output "----------------------|---------------|------|-------"

$categories = @('Espresso', 'Brewed Coffee', 'Pastries', 'Merch')
$iteration = 0

while ($true) {
    $category = $categories[$iteration % $categories.Count]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 30
        $cmd.CommandText = "SELECT COUNT(*) as cnt FROM Products WHERE Category = '$category' OPTION (MAXDOP 1, RECOMPILE)"
        $result = $cmd.ExecuteScalar()
        $sw.Stop()
        
        $duration = $sw.ElapsedMilliseconds
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        
        if ($duration -gt 500) {
            $status = "SLOW"
        } elseif ($duration -gt 100) {
            $status = "OK"
        } else {
            $status = "FAST"
        }
        
        Write-Output "$timestamp | $($duration.ToString().PadLeft(13)) | $($result.ToString().PadLeft(4)) | $status"
    } catch {
        $sw.Stop()
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | ERROR         |      | $($_.Exception.Message)"
    }
    
    $iteration++
    Start-Sleep -Seconds 3
}
