[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [string] $ResourceGroup = "rg-sre-onprem-lab",
  [string] $Location = "eastus",
  [string] $MachineName = "sre-onprem-01",
  [string] $WorkspaceName = "law-sre-onprem-lab"
)
$ErrorActionPreference = "Stop"
az account set --subscription $SubscriptionId
$providers = @("Microsoft.HybridCompute","Microsoft.GuestConfiguration","Microsoft.HybridConnectivity","Microsoft.AzureArcData","Microsoft.Insights","Microsoft.OperationalInsights")
foreach ($p in $providers) { az provider register --namespace $p | Out-Null }
az group create -n $ResourceGroup -l $Location | Out-Null
az extension add --name connectedmachine --upgrade --yes | Out-Null
$machineId = az connectedmachine show -g $ResourceGroup -n $MachineName --query id -o tsv
if (-not $machineId) { throw "Arc machine '$MachineName' was not found in '$ResourceGroup'. Onboard it first." }
az monitor log-analytics workspace create -g $ResourceGroup -n $WorkspaceName -l $Location | Out-Null
$workspaceId = az monitor log-analytics workspace show -g $ResourceGroup -n $WorkspaceName --query id -o tsv
az connectedmachine extension create --machine-name $MachineName -g $ResourceGroup -l $Location --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorLinuxAgent --enable-auto-upgrade true | Out-Null
az monitor log-analytics workspace table create -g $ResourceGroup --workspace-name $WorkspaceName --name SreLabApp_CL --columns TimeGenerated=datetime RawData=string | Out-Null
$hostRule = @{
  location=$Location; kind="Linux"; properties=@{
    dataSources=@{
      performanceCounters=@(@{name="perfCounters";streams=@("Microsoft-Perf");samplingFrequencyInSeconds=60;counterSpecifiers=@("Processor(*)\% Processor Time","Memory(*)\% Used Memory","Logical Disk(*)\% Used Space","Network(*)\Total Bytes Transmitted","Network(*)\Total Bytes Received")});
      syslog=@(@{name="syslogBase";streams=@("Microsoft-Syslog");facilityNames=@("auth","authpriv","cron","daemon","kern","syslog","user");logLevels=@("Info","Notice","Warning","Error","Critical","Alert","Emergency")})
    }; destinations=@{logAnalytics=@(@{name="law";workspaceResourceId=$workspaceId})}; dataFlows=@(@{streams=@("Microsoft-Perf","Microsoft-Syslog");destinations=@("law")})
  }
}
$appRule = @{
  location=$Location; kind="Linux"; properties=@{
    streamDeclarations=@{"Custom-SreLabApp_CL"=@{columns=@(@{name="TimeGenerated";type="datetime"},@{name="RawData";type="string"})}};
    dataSources=@{logFiles=@(@{name="sreLabAppLog";streams=@("Custom-SreLabApp_CL");filePatterns=@("/var/log/sre-lab/app.log");format="text";settings=@{text=@{recordStartTimestampFormat="ISO 8601"}}})};
    destinations=@{logAnalytics=@(@{name="law";workspaceResourceId=$workspaceId})};
    dataFlows=@(@{streams=@("Custom-SreLabApp_CL");destinations=@("law");transformKql="source";outputStream="Custom-SreLabApp_CL"})
  }
}
$tmp = Join-Path $env:TEMP "sre-onprem-lab"; New-Item -ItemType Directory -Force $tmp | Out-Null
$hostPath=Join-Path $tmp "dcr-host.json"; $appPath=Join-Path $tmp "dcr-app.json"
$hostRule | ConvertTo-Json -Depth 20 | Set-Content $hostPath -Encoding utf8
$appRule | ConvertTo-Json -Depth 20 | Set-Content $appPath -Encoding utf8
az monitor data-collection rule create -g $ResourceGroup -n dcr-sre-onprem-host --rule-file $hostPath | Out-Null
az monitor data-collection rule create -g $ResourceGroup -n dcr-sre-onprem-app --rule-file $appPath | Out-Null
$hostDcr=az monitor data-collection rule show -g $ResourceGroup -n dcr-sre-onprem-host --query id -o tsv
$appDcr=az monitor data-collection rule show -g $ResourceGroup -n dcr-sre-onprem-app --query id -o tsv
az monitor data-collection rule association create --name dcra-sre-onprem-01-host --rule-id $hostDcr --resource $machineId | Out-Null
az monitor data-collection rule association create --name dcra-sre-onprem-01-app --rule-id $appDcr --resource $machineId | Out-Null
Write-Host "Monitoring deployed. Wait 5-15 minutes, then run the queries under queries/."
