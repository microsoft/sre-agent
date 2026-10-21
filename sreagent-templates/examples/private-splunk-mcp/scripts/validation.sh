#!/usr/bin/env bash

normalize_location() {
  printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

validate_ipv4_cidr() {
  local value="$1" expected_mask="$2" label="$3"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/${expected_mask}$ ]] ||
    { echo "$label must be a valid IPv4 /$expected_mask CIDR." >&2; return 1; }
  local address="${value%/*}" octet
  IFS=. read -r -a octets <<<"$address"
  for octet in "${octets[@]}"; do
    ((octet >= 0 && octet <= 255)) || { echo "$label contains an invalid IPv4 octet." >&2; return 1; }
  done
}

cidr_key() {
  local address="${1%/*}" count="$2"
  IFS=. read -r -a octets <<<"$address"
  local result="${octets[0]}"
  local i
  for ((i = 1; i < count; i++)); do result+=".${octets[$i]}"; done
  printf '%s' "$result"
}

validate_deployment_inputs() {
  local topology="$1" agent_location="$2" splunk_location="$3"
  local agent_vnet="$4" splunk_vnet="$5" agent_subnet="$6" splunk_subnet="$7"
  local private_ip="$8" ssh_key="$9"

  [[ "$topology" == "same-region" || "$topology" == "cross-region" ]] ||
    { echo "topology must be same-region or cross-region." >&2; return 1; }
  [[ -n "$agent_location" && -n "$splunk_location" ]] ||
    { echo "agent and Splunk locations must not be empty." >&2; return 1; }
  validate_ipv4_cidr "$agent_vnet" 16 agent_vnet_address_prefix
  validate_ipv4_cidr "$splunk_vnet" 16 splunk_vnet_address_prefix
  validate_ipv4_cidr "$agent_subnet" 27 agent_subnet_prefix
  validate_ipv4_cidr "$splunk_subnet" 24 splunk_subnet_prefix
  [[ "$private_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    { echo "splunk_private_ip must be a valid IPv4 address." >&2; return 1; }

  local normalized_agent normalized_splunk
  normalized_agent="$(normalize_location "$agent_location")"
  normalized_splunk="$(normalize_location "$splunk_location")"
  if [[ "$topology" == "same-region" ]]; then
    [[ "$normalized_agent" == "$normalized_splunk" ]] ||
      { echo "same-region requires agent and Splunk locations to match." >&2; return 1; }
    [[ "$agent_vnet" == "$splunk_vnet" ]] ||
      { echo "same-region requires one shared VNet address prefix." >&2; return 1; }
    [[ "$(cidr_key "$agent_subnet" 3)" != "$(cidr_key "$splunk_subnet" 3)" ]] ||
      { echo "same-region agent and Splunk subnets must not overlap." >&2; return 1; }
  else
    [[ "$normalized_agent" != "$normalized_splunk" ]] ||
      { echo "cross-region requires different agent and Splunk locations." >&2; return 1; }
    [[ "$(cidr_key "$agent_vnet" 2)" != "$(cidr_key "$splunk_vnet" 2)" ]] ||
      { echo "cross-region VNet address prefixes must not overlap." >&2; return 1; }
  fi

  [[ "$(cidr_key "$agent_vnet" 2)" == "$(cidr_key "$agent_subnet" 2)" ]] ||
    { echo "agent_subnet_prefix must be contained in agent_vnet_address_prefix." >&2; return 1; }
  [[ "$(cidr_key "$splunk_vnet" 2)" == "$(cidr_key "$splunk_subnet" 2)" ]] ||
    { echo "splunk_subnet_prefix must be contained in splunk_vnet_address_prefix." >&2; return 1; }

  IFS=. read -r ip1 ip2 ip3 ip4 <<<"$private_ip"
  [[ "$ip1.$ip2.$ip3" == "$(cidr_key "$splunk_subnet" 3)" && "$ip4" -ge 4 && "$ip4" -le 254 ]] ||
    { echo "splunk_private_ip must be a usable host in splunk_subnet_prefix (not Azure-reserved or broadcast)." >&2; return 1; }
  [[ "$ssh_key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521))[[:space:]][A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] ||
    { echo "admin SSH public key must be a valid OpenSSH public key." >&2; return 1; }
}
