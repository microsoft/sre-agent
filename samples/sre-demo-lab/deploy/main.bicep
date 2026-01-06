// =============================================================================
// SRE Agent Demo Lab - Main Bicep Template
// =============================================================================
// Deploys infrastructure for demonstrating SRE Agent troubleshooting capabilities
// - Log Analytics Workspace
// - Virtual Machines with Azure Monitor Agent
// - Data Collection Rules for performance metrics
// - Recovery Services Vault with backup policies
// - Azure Monitor Alert Rules
// =============================================================================

targetScope = 'resourceGroup'

// =============================================================================
// Parameters
// =============================================================================

@description('Location for all resources')
param location string = resourceGroup().location

@description('Base name for resources')
param baseName string = 'sre-demo'

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('SSH public key for VM access')
@secure()
param sshPublicKey string

@description('Number of VMs to deploy')
@minValue(1)
@maxValue(5)
param vmCount int = 2

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Email for alert notifications')
param alertEmail string = ''

// =============================================================================
// Variables
// =============================================================================

var logAnalyticsName = 'log-analytics-${baseName}'
var dcrName = 'dcr-${baseName}-perf'
var rsvName = 'rsv-${baseName}'
var actionGroupName = 'ag-${baseName}'

// =============================================================================
// Modules
// =============================================================================

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'logAnalytics'
  params: {
    name: logAnalyticsName
    location: location
  }
}

module virtualMachines 'modules/virtual-machines.bicep' = {
  name: 'virtualMachines'
  params: {
    location: location
    baseName: baseName
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    vmCount: vmCount
    vmSize: vmSize
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module dataCollection 'modules/data-collection.bicep' = {
  name: 'dataCollection'
  params: {
    name: dcrName
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    vmIds: virtualMachines.outputs.vmIds
  }
}

module recoveryVault 'modules/recovery-vault.bicep' = {
  name: 'recoveryVault'
  params: {
    name: rsvName
    location: location
    vmIds: virtualMachines.outputs.vmIds
    vmNames: virtualMachines.outputs.vmNames
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  params: {
    location: location
    baseName: baseName
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    actionGroupName: actionGroupName
    alertEmail: alertEmail
    rsvName: rsvName
  }
}

// =============================================================================
// Outputs
// =============================================================================

output resourceGroupName string = resourceGroup().name
output logAnalyticsWorkspaceId string = logAnalytics.outputs.workspaceId
output logAnalyticsWorkspaceName string = logAnalyticsName
output vmNames array = virtualMachines.outputs.vmNames
output vmIds array = virtualMachines.outputs.vmIds
output rsvName string = rsvName
output dcrName string = dcrName
