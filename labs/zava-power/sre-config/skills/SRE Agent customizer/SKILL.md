---
metadata:
  api_version: azuresre.ai/v2
  kind: Skill
name: SRE Agent customizer
tools:
  - sreagent-runtime-mcp_agent_tools
  - sreagent-runtime-mcp_agents
  - sreagent-runtime-mcp_connectors
  - sreagent-runtime-mcp_get_documentation
  - sreagent-runtime-mcp_hooks
  - sreagent-runtime-mcp_incidents
  - sreagent-runtime-mcp_investigate_with_agent
  - sreagent-runtime-mcp_investigate_with_agent_yolo
  - sreagent-runtime-mcp_memory
  - sreagent-runtime-mcp_plan_agent_architecture
  - sreagent-runtime-mcp_scheduled_tasks
  - sreagent-runtime-mcp_skills
  - sreagent-runtime-mcp_threads
  - sreagent-runtime-mcp_yaml
---

---
name: SRE Agent customizer
description: 
tools:
  - sreagent-runtime-mcp_agent_tools
  - sreagent-runtime-mcp_agents
  - sreagent-runtime-mcp_connectors
  - sreagent-runtime-mcp_get_documentation
  - sreagent-runtime-mcp_hooks
  - sreagent-runtime-mcp_incidents
  - sreagent-runtime-mcp_investigate_with_agent
  - sreagent-runtime-mcp_investigate_with_agent_yolo
  - sreagent-runtime-mcp_memory
  - sreagent-runtime-mcp_plan_agent_architecture
  - sreagent-runtime-mcp_scheduled_tasks
  - sreagent-runtime-mcp_skills
  - sreagent-runtime-mcp_threads
  - sreagent-runtime-mcp_yaml
---

<!-- Add your skill instructions here -->
Use the SRE Agent MCP to help create custom agents and skills.
Don't create additional tools if there are system tools already available. 
You will first understand the ask, look at any existing skills, tools and leverage that
You will ask if you need it connected to a trigger or not
You will ask for any design choices
Will finalize the plan and only after user approval create the necessary YAML and md files and then apply it to the agent
