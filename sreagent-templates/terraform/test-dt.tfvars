# dynatrace recipe — terraform.tfvars
agent_name              = "tf-dt"
resource_group_name     = "rg-tf-dt"
location                = "swedencentral"
target_resource_groups  = ["rg-contoso-swe"]

enable_log_analytics_connector = true
law_resource_id = "/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-contoso-swe/providers/Microsoft.OperationalInsights/workspaces/law-7defkiyvn3r44"

enable_app_insights_connector = true
app_insights_resource_id = "/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-contoso-swe/providers/microsoft.insights/components/sreagent-recipes-telemetry"
app_insights_app_id = "3b50188a-a191-4f74-994a-2e7ed8afc018"

skills     = []
subagents  = []
common_prompts = []

# NOTE: Dynatrace MCP connector + DT token must be added via connectors variable
# or post-deploy via apply-extras. The TF module deploys the core agent + ARM connectors.
