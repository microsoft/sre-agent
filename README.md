# 🚀 Welcome to the Azure SRE Agent GitHub Repository!
We’re excited to launch this space for collaboration around the [SRE Agent](https://learn.microsoft.com/en-us/azure/sre-agent/overview), a key tool in our mission to improve service reliability and operational excellence. 

## This repository is a community-driven hub where you can:
* 🐛 Report bugs encountered while using the SRE Agent 
* 💡 Request features that would improve usability or functionality
* ❓ Share challenges or feedback related to using the product 
* 🤝 Engage with the team and community to help shape the future of the SRE Agent 

> [!NOTE]
> This repo is not intended for integration-related issues. For those, please use the appropriate internal or partner support channels. 

## 🧼 Hygiene Guidelines for Creating Issues

To help us keep things organized and productive, please follow these simple rules:
* Be descriptive: Include steps to reproduce, logs, screenshots, and thread ID where applicable.  
* Use labels: Tag your issue appropriately (bug, feature-request, usability, etc.) to help with triage. 
* Avoid duplicates: Search existing issues before creating a new one. 
* Stay constructive: We welcome feedback, but please keep it respectful and focused. 
* No personal data: Please do not include any personally identifiable information (PII) in your issue. 

## 🧭 How to Find the Thread ID in SRE Agent

Your direct chat interaction or incident is tracked as a thread in SRE Agent. Including the Thread ID in your GitHub issue helps us investigate quickly and accurately. A thread ID is a hex string like `50f7521d-dfee-487e-9188-5abdc8adde91`.

### 🔍 How to Locate the Thread ID:
**Get thread ID for threads under "Activities" view <br />**
<img width="722" height="126" alt="Screenshot 2025-10-09 at 3 22 07 PM" src="https://github.com/user-attachments/assets/62f6ea4b-3494-4f67-a85e-d16611f35da7" /> <br />



**Get thread ID for threads under Incident Management view <br />** 
step 1: <br />
<img width="670" height="108" alt="Screenshot 2025-10-09 at 3 21 51 PM" src="https://github.com/user-attachments/assets/18794670-499b-4c74-aedd-0541621d78e6" /> <br />




step2: <br />
<img width="747" height="108" alt="Screenshot 2025-10-09 at 3 21 37 PM" src="https://github.com/user-attachments/assets/09dbaf67-49f5-4346-b5eb-6624f4c5b803" /> <br />





## 📝 Issue Template
When creating a new issue, please use the following format: 

**Issue Description** 
Briefly describe the problem or request. 

**Agent Name** 
name of Agent

**Subscription ID**
subscription in which agent is deployed 

**Region**
Region where agent is deployed 

**Resource group** 
For Agent deployment related issues, provide the resource group in which it was created

**Thread ID** 
Paste the thread ID from the SRE Agent portal (e.g., 50f7521d-dfee-487e-9188-5abdc8adde91) 

**Steps to Reproduce** 
1. Describe the action you took 
2. Mention the resource or Azure service (if involved)
3. Describe what you expected vs. what happened
4. include  error messages experienced by you in Incident or chat threads or ARM deployment error details or HTTP status codes

**Expected Behavior** 
What should happen? 

**Actual Behavior** 
What actually happened 
