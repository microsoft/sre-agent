provider "google" {
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
}

resource "google_project_service" "required" {
  for_each = toset([
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "sre_agent" {
  project                   = var.project_id
  workload_identity_pool_id = "sre-agent-pool"
  display_name              = "SREAgentPool"

  depends_on = [google_project_service.required]

  lifecycle {
    ignore_changes = [description]
  }
}

resource "google_iam_workload_identity_pool_provider" "azure" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.sre_agent.workload_identity_pool_id
  workload_identity_pool_provider_id = "sre-agent-provider"
  display_name                       = "SREAgentProvider"

  attribute_mapping = {
    "google.subject" = "assertion.tid + '::' + assertion.oid"
  }
  attribute_condition = var.attribute_condition

  oidc {
    issuer_uri        = "https://login.microsoftonline.com/${lower(var.azure_tenant_id)}/v2.0"
    allowed_audiences = ["59f0a04a-b322-4310-adc9-39ac41e9631e"]
  }

  lifecycle {
    ignore_changes = [description]
  }
}

locals {
  # The pool name contains its hosting project number, not the project ID.
  principal_id       = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/sre-agent-pool/subject/${lower(var.azure_tenant_id)}::${lower(var.uami_object_id)}"
  organization_scope = var.assignment_scope == "organization"
  role_permissions = setunion(
    var.existing_role_permissions,
    toset(local.read_permissions),
    # Project listing on a parent is only applicable to organization-level roles.
    local.organization_scope ? toset(["resourcemanager.projects.list"]) : toset([]),
    var.access_mode == "read-write" ? toset(local.write_permissions) : toset([]),
  )

  # ==================== READ PERMISSIONS ====================
  read_permissions = [
    # Mandatory permission for the project to appear in gcloud projects list.
    "resourcemanager.projects.get",

    # IAM policy read access
    "resourcemanager.projects.getIamPolicy",
    "iam.roles.list",

    # Cloud Storage buckets and objects
    "storage.buckets.get",
    "storage.buckets.list",
    "storage.objects.get",
    "storage.objects.list",

    # Cloud Run services, revisions, and jobs
    "run.services.get",
    "run.services.list",
    "run.revisions.get",
    "run.revisions.list",
    "run.jobs.get",
    "run.jobs.list",

    # Compute Engine VM instances
    "compute.instances.get",
    "compute.instances.list",

    # Compute Engine disks
    "compute.disks.get",
    "compute.disks.list",

    # Google Kubernetes Engine (GKE) clusters
    "container.clusters.get",
    "container.clusters.list",
    "container.operations.get",
    "container.operations.list",

    # Cloud SQL instances and databases
    "cloudsql.instances.get",
    "cloudsql.instances.list",
    "cloudsql.databases.get",
    "cloudsql.databases.list",

    # Pub/Sub topics and subscriptions
    "pubsub.topics.get",
    "pubsub.topics.list",
    "pubsub.subscriptions.get",
    "pubsub.subscriptions.list",

    # BigQuery Metadata Viewer (roles/bigquery.metadataViewer; project reads included above)
    "bigquery.datasets.get",
    "bigquery.datasets.getIamPolicy",
    "bigquery.models.getMetadata",
    "bigquery.models.list",
    "bigquery.propertyGraphs.get",
    "bigquery.propertyGraphs.list",
    "bigquery.routines.get",
    "bigquery.routines.list",
    "bigquery.tables.get",
    "bigquery.tables.getIamPolicy",
    "bigquery.tables.list",
    "dataplex.projects.search",

    # Cloud Functions
    "cloudfunctions.functions.get",
    "cloudfunctions.functions.list",
    "cloudfunctions.locations.list",

    # VPC networks and firewall rules
    "compute.networks.get",
    "compute.networks.list",
    "compute.firewalls.get",
    "compute.firewalls.list",

    # Artifact Registry repositories
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.list",
    "artifactregistry.locations.list",

    # Service Usage
    "serviceusage.services.list",

    # Cloud Logging: log entries, log metrics, and sinks
    "logging.logEntries.list",
    "logging.logs.list",
    "logging.logMetrics.get",
    "logging.logMetrics.list",
    "logging.sinks.get",
    "logging.sinks.list",

    # Cloud Monitoring: metrics, dashboards, and alert policies
    "monitoring.timeSeries.list",
    "monitoring.metricDescriptors.get",
    "monitoring.metricDescriptors.list",
    "monitoring.dashboards.get",
    "monitoring.dashboards.list",
    "monitoring.alertPolicies.get",
    "monitoring.alertPolicies.list",

    # Load balancing: forwarding rules, backends, health checks, and proxies
    "compute.forwardingRules.get",
    "compute.forwardingRules.list",
    "compute.globalForwardingRules.get",
    "compute.globalForwardingRules.list",
    "compute.backendServices.get",
    "compute.backendServices.list",
    "compute.regionBackendServices.get",
    "compute.regionBackendServices.list",
    "compute.backendBuckets.get",
    "compute.backendBuckets.list",
    "compute.healthChecks.get",
    "compute.healthChecks.list",
    "compute.httpHealthChecks.get",
    "compute.httpHealthChecks.list",
    "compute.httpsHealthChecks.get",
    "compute.httpsHealthChecks.list",
    "compute.urlMaps.get",
    "compute.urlMaps.list",
    "compute.regionUrlMaps.get",
    "compute.regionUrlMaps.list",
    "compute.targetHttpProxies.get",
    "compute.targetHttpProxies.list",
    "compute.targetHttpsProxies.get",
    "compute.targetHttpsProxies.list",
    "compute.targetTcpProxies.get",
    "compute.targetTcpProxies.list",
    "compute.targetSslProxies.get",
    "compute.targetSslProxies.list",

    # Network infrastructure: IP addresses, routers, routes, and subnets
    "compute.addresses.get",
    "compute.addresses.list",
    "compute.globalAddresses.get",
    "compute.globalAddresses.list",
    "compute.routers.get",
    "compute.routers.list",
    "compute.routes.get",
    "compute.routes.list",
    "compute.subnetworks.get",
    "compute.subnetworks.list",

    # Cloud DNS: managed zones, DNS records, and changes
    "dns.managedZones.get",
    "dns.managedZones.list",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.changes.get",
    "dns.changes.list",

    # Memorystore for Redis instances
    "redis.instances.get",
    "redis.instances.list",

    # Memorystore for Memcached instances
    "memcache.instances.get",
    "memcache.instances.list",

    # Filestore instances
    "file.instances.get",
    "file.instances.list",
  ]

  # ==================== WRITE PERMISSIONS ====================
  write_permissions = [
    # Cloud Storage buckets and objects
    "storage.buckets.create",
    "storage.buckets.update",
    "storage.objects.create",
    "storage.objects.update",

    # Cloud Run services and jobs
    "run.services.create",
    "run.services.update",
    "run.jobs.create",
    "run.jobs.update",

    # Compute Engine VM instances
    "compute.instances.create",
    "compute.instances.update",
    "compute.instances.start",
    "compute.instances.stop",
    "compute.zoneOperations.get",
    "compute.regionOperations.get",
    "compute.globalOperations.get",

    # Compute Engine disks
    "compute.disks.create",
    "compute.disks.update",

    # Google Kubernetes Engine (GKE) clusters
    "container.clusters.create",
    "container.clusters.update",

    # Cloud SQL instances
    "cloudsql.instances.create",
    "cloudsql.instances.update",

    # Pub/Sub topics and subscriptions
    "pubsub.topics.create",
    "pubsub.topics.update",
    "pubsub.topics.attachSubscription",
    "pubsub.subscriptions.create",
    "pubsub.subscriptions.update",

    # BigQuery tables (metadata only; no table data access)
    "bigquery.tables.create",
    "bigquery.tables.update",

    # Cloud Functions
    "cloudfunctions.functions.create",
    "cloudfunctions.functions.update",

    # VPC networks and firewall rules
    "compute.networks.create",
    "compute.networks.update",
    "compute.firewalls.create",
    "compute.firewalls.update",

    # Artifact Registry repositories
    "artifactregistry.repositories.create",
    "artifactregistry.repositories.update",

    # Cloud Logging: log metrics and sinks
    "logging.logMetrics.create",
    "logging.logMetrics.update",
    "logging.sinks.create",
    "logging.sinks.update",

    # Cloud Monitoring: dashboards and alert policies
    "monitoring.dashboards.create",
    "monitoring.dashboards.update",
    "monitoring.alertPolicies.create",
    "monitoring.alertPolicies.update",

    # Load balancing: forwarding rules, backends, health checks, and proxies
    "compute.forwardingRules.create",
    "compute.forwardingRules.update",
    "compute.globalForwardingRules.create",
    "compute.globalForwardingRules.update",
    "compute.backendServices.create",
    "compute.backendServices.update",
    "compute.regionBackendServices.create",
    "compute.regionBackendServices.update",
    "compute.backendBuckets.create",
    "compute.backendBuckets.update",
    "compute.healthChecks.create",
    "compute.healthChecks.update",
    "compute.httpHealthChecks.create",
    "compute.httpHealthChecks.update",
    "compute.httpsHealthChecks.create",
    "compute.httpsHealthChecks.update",
    "compute.urlMaps.create",
    "compute.urlMaps.update",
    "compute.regionUrlMaps.create",
    "compute.regionUrlMaps.update",
    "compute.targetHttpProxies.create",
    "compute.targetHttpProxies.update",
    "compute.targetHttpsProxies.create",
    "compute.targetHttpsProxies.update",
    "compute.targetTcpProxies.create",
    "compute.targetTcpProxies.update",
    "compute.targetSslProxies.create",
    "compute.targetSslProxies.update",

    # Network infrastructure: IP addresses, routers, routes, and subnets
    "compute.addresses.create",
    "compute.globalAddresses.create",
    "compute.routers.create",
    "compute.routers.update",
    "compute.routes.create",
    "compute.subnetworks.create",
    "compute.subnetworks.update",
    "compute.subnetworks.use",

    # Cloud DNS: managed zones and DNS records
    "dns.managedZones.create",
    "dns.managedZones.update",
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.update",
    "dns.changes.create",

    # Memorystore for Redis instances
    "redis.instances.create",
    "redis.instances.update",

    # Memorystore for Memcached instances
    "memcache.instances.create",
    "memcache.instances.update",

    # Filestore instances
    "file.instances.create",
    "file.instances.update",
  ]
}

resource "google_project_iam_custom_role" "sre_agent_role" {
  count = local.organization_scope ? 0 : 1

  project     = var.project_id
  role_id     = "SREAgentRole"
  title       = "SREAgentRole"
  description = "Shared SRE Agent resource access."
  stage       = "GA"

  permissions = local.role_permissions

  depends_on = [google_project_service.required]

  lifecycle {
    ignore_changes = [description, stage]
  }
}

resource "google_organization_iam_custom_role" "sre_agent_role" {
  count = local.organization_scope ? 1 : 0

  org_id      = var.organization_id
  role_id     = "SREAgentRole"
  title       = "SREAgentRole"
  description = "Shared SRE Agent resource access."
  stage       = "GA"
  permissions = local.role_permissions

  depends_on = [google_project_service.required]

  lifecycle {
    ignore_changes = [description, stage]

    precondition {
      condition     = var.organization_id != ""
      error_message = "organization_id is required when assignment_scope is organization."
    }
  }
}

resource "google_project_iam_member" "sre_agent_role_assignment" {
  count = local.organization_scope ? 0 : 1

  project = var.project_id
  role    = google_project_iam_custom_role.sre_agent_role[0].name
  member  = local.principal_id

  depends_on = [google_iam_workload_identity_pool_provider.azure]
}

resource "google_organization_iam_member" "sre_agent_role_assignment" {
  count = local.organization_scope ? 1 : 0

  org_id = var.organization_id
  role   = google_organization_iam_custom_role.sre_agent_role[0].name
  member = local.principal_id

  depends_on = [google_iam_workload_identity_pool_provider.azure]
}

output "role_name" {
  description = "Full resource name of the custom role, assigned to the federated managed identity at the selected scope."
  value       = local.organization_scope ? google_organization_iam_custom_role.sre_agent_role[0].name : google_project_iam_custom_role.sre_agent_role[0].name
}

output "workload_identity_provider" {
  description = "Full provider resource name to enter in the GCP connector."
  value       = google_iam_workload_identity_pool_provider.azure.name
}

output "principal_id" {
  description = "Federated IAM member assigned the custom role."
  value       = local.principal_id
}
