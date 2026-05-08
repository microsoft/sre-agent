# pagerduty recipe — terraform.tfvars
agent_name         = "tf-pd2"
resource_group_name = "rg-tf-pd2"
location           = "swedencentral"
target_resource_groups = ["rg-ebc-demo3"]

enable_log_analytics_connector = true
law_resource_id = "/subscriptions/cbf44432-7f45-4906-a85d-d2b14a1e8328/resourceGroups/rg-ebc-demo3/providers/Microsoft.OperationalInsights/workspaces/law-ebc-demo3"

skills = []
subagents = []
common_prompts = []
