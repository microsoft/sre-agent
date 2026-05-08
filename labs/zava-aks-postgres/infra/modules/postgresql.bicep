@description('Azure region for the PostgreSQL flexible server.')
param location string

@description('Unique suffix for the server name.')
param uniqueSuffix string

@description('Resource ID of the delegated subnet for the flexible server.')
param subnetId string

@description('Resource ID of the private DNS zone for the flexible server.')
param privateDnsZoneId string

var serverName = 'zava-pg-${uniqueSuffix}'

// SKU rationale: Burstable B1ms gives ~20% baseline vCPU and a 32 GB / ~120 IOPS
// storage floor. Under sustained 1s self-probe load it depletes CPU credits, and
// every query becomes 30–60ms purely from CPU starvation — indistinguishable
// from the missing-index symptom the demo wants to teach. GeneralPurpose D2ds_v5
// at 128 GB raises the IOPS floor to ~500 and removes the credit-cliff noise so
// "slow query" actually means "missing index", not "Burstable throttle".
resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  sku: {
    name: 'Standard_D2ds_v5'
    tier: 'GeneralPurpose'
  }
  properties: {
    version: '16'
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
    }
    storage: {
      storageSizeGB: 128
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: subnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pgServer
  name: 'zava_store'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// ---------------------------------------------------------------------------
// First-class telemetry: enable Query Store + wait sampling.
//
// Why this matters for the demo: the goal is for the SRE Agent to *diagnose*
// from Log Analytics (KQL) BEFORE falling back to in-cluster execution
// (`az aks command invoke … kubectl exec deploy/zava-api -- node bin/run-sql.js`).
// Azure PG Flex pre-loads pg_qs and
// pgms_wait_sampling in shared_preload_libraries, but they're idle by default —
// flipping query_capture_mode to ALL turns them on. Once on, the per-query
// stats and wait events flow into Log Analytics automatically through the
// existing `allLogs` diagnostic setting (PostgreSQLFlexQueryStoreRuntime +
// PostgreSQLFlexQueryStoreWaitStats tables). No restart required, no
// shared_preload_libraries change.
//
// Note on auto_explain: deliberately NOT enabled. It would require modifying
// shared_preload_libraries (which Azure manages with curated entries like
// pg_failover_slots / pg_cron) and a server restart. Query Store gives the
// agent what it needs — query texts, plan ids, runtime stats — through
// AzureDiagnostics without that risk.
// ---------------------------------------------------------------------------

resource pgStatStatements 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pgServer
  name: 'pg_stat_statements.track'
  properties: {
    value: 'all'
    source: 'user-override'
  }
}

// NOTE: PG Flex rejects parallel parameter writes with "ServerIsBusy". Chain
// the configurations with explicit dependsOn to serialize them.
resource pgqsCaptureMode 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pgServer
  name: 'pg_qs.query_capture_mode'
  properties: {
    value: 'ALL'
    source: 'user-override'
  }
  dependsOn: [pgStatStatements]
}

resource pgqsRetention 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pgServer
  name: 'pg_qs.retention_period_in_days'
  properties: {
    value: '7'
    source: 'user-override'
  }
  dependsOn: [pgqsCaptureMode]
}

resource pgmsWaitSampling 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pgServer
  name: 'pgms_wait_sampling.query_capture_mode'
  properties: {
    value: 'ALL'
    source: 'user-override'
  }
  dependsOn: [pgqsRetention]
}

// track_io_timing surfaces shared_blks_read_time / write_time in Query Store —
// the agent needs this to distinguish "slow because IO-bound" from "slow
// because CPU-bound". Tiny per-query overhead, on by default in many cloud PGs.
resource pgTrackIoTiming 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pgServer
  name: 'track_io_timing'
  properties: {
    value: 'on'
    source: 'user-override'
  }
  dependsOn: [pgmsWaitSampling]
}

// Azure PG Flexible Server uses SSD-backed storage for this SKU. Keep the
// planner's random I/O cost close to sequential I/O so category queries use the
// `(category, name)` index for ordered traversal instead of bitmap scan + sort.
resource pgRandomPageCost 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: pgServer
  name: 'random_page_cost'
  properties: {
    value: '1.1'
    source: 'user-override'
  }
  dependsOn: [pgTrackIoTiming]
}

output serverName string = pgServer.name
output fqdn string = pgServer.properties.fullyQualifiedDomainName
output serverResourceId string = pgServer.id
