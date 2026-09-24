function Get-OptionalProperty {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Normalize-AzureLocation {
    param([string]$Location)
    return ($Location -replace '\s', '').ToLowerInvariant()
}

function Test-Ipv4Cidr {
    param([string]$Value, [int]$ExpectedMask, [string]$Name)
    if ($Value -notmatch "^(\d{1,3}\.){3}\d{1,3}/$ExpectedMask`$") {
        throw "$Name must be a valid IPv4 /$ExpectedMask CIDR."
    }
    foreach ($octet in ($Value.Split('/')[0].Split('.'))) {
        if ([int]$octet -lt 0 -or [int]$octet -gt 255) {
            throw "$Name contains an invalid IPv4 octet."
        }
    }
}

function Get-CidrKey {
    param([string]$Value, [int]$Count)
    return (($Value.Split('/')[0].Split('.')[0..($Count - 1)]) -join '.')
}

function Test-DeploymentInputs {
    param(
        [string]$Topology,
        [string]$AgentLocation,
        [string]$SplunkLocation,
        [string]$AgentVnetPrefix,
        [string]$SplunkVnetPrefix,
        [string]$AgentSubnetPrefix,
        [string]$SplunkSubnetPrefix,
        [string]$SplunkPrivateIp,
        [string]$AdminSshPublicKey
    )

    if ($Topology -notin @('same-region', 'cross-region')) { throw 'topology must be same-region or cross-region.' }
    if (-not $AgentLocation -or -not $SplunkLocation) { throw 'Agent and Splunk locations must not be empty.' }
    Test-Ipv4Cidr $AgentVnetPrefix 16 'agent_vnet_address_prefix'
    Test-Ipv4Cidr $SplunkVnetPrefix 16 'splunk_vnet_address_prefix'
    Test-Ipv4Cidr $AgentSubnetPrefix 27 'agent_subnet_prefix'
    Test-Ipv4Cidr $SplunkSubnetPrefix 24 'splunk_subnet_prefix'
    if ($SplunkPrivateIp -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { throw 'splunk_private_ip must be a valid IPv4 address.' }

    if ($Topology -eq 'same-region') {
        if ((Normalize-AzureLocation $AgentLocation) -ne (Normalize-AzureLocation $SplunkLocation)) { throw 'same-region requires agent and Splunk locations to match.' }
        if ($AgentVnetPrefix -ne $SplunkVnetPrefix) { throw 'same-region requires one shared VNet address prefix.' }
        if ((Get-CidrKey $AgentSubnetPrefix 3) -eq (Get-CidrKey $SplunkSubnetPrefix 3)) { throw 'same-region agent and Splunk subnets must not overlap.' }
    }
    else {
        if ((Normalize-AzureLocation $AgentLocation) -eq (Normalize-AzureLocation $SplunkLocation)) { throw 'cross-region requires different agent and Splunk locations.' }
        if ((Get-CidrKey $AgentVnetPrefix 2) -eq (Get-CidrKey $SplunkVnetPrefix 2)) { throw 'cross-region VNet address prefixes must not overlap.' }
    }

    if ((Get-CidrKey $AgentVnetPrefix 2) -ne (Get-CidrKey $AgentSubnetPrefix 2)) { throw 'agent_subnet_prefix must be contained in agent_vnet_address_prefix.' }
    if ((Get-CidrKey $SplunkVnetPrefix 2) -ne (Get-CidrKey $SplunkSubnetPrefix 2)) { throw 'splunk_subnet_prefix must be contained in splunk_vnet_address_prefix.' }
    $privateIpParts = $SplunkPrivateIp.Split('.')
    if (($privateIpParts[0..2] -join '.') -ne (Get-CidrKey $SplunkSubnetPrefix 3) -or [int]$privateIpParts[3] -lt 4 -or [int]$privateIpParts[3] -gt 254) {
        throw 'splunk_private_ip must be a usable host in splunk_subnet_prefix (not Azure-reserved or broadcast).'
    }
    if ($AdminSshPublicKey -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+={0,3}( .*)?$') {
        throw 'admin SSH public key must be a valid OpenSSH public key.'
    }
}
