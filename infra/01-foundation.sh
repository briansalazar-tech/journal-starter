#!/usr/bin/env bash
# Phase 1: network foundation and logging.
#
# Creates (all free or near-free; see infra/README.md):
#   - resource provider registrations the later phases need
#   - a Log Analytics workspace with a daily ingestion cap
#   - three NSGs, one per tier, with least-privilege inbound rules
#   - the VNet and three subnets (app, db, admin), each with its NSG
#   - the private DNS zone PostgreSQL will register in, linked to the VNet
#
# Requirements this phase lays the groundwork for:
#   #2  PostgreSQL on its own private subnet that only the app (and admin) subnets reach
#   #3  no management port is reachable from the internet
#
# Safe to re-run: existing resources are left as they are, and NSG rules are
# updated to match this file.

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

confirm "create the network foundation in ${RG}"

# ---------------------------------------------------------------------------
log "Resource providers"
# Registration is per subscription, one-time, and free. Microsoft.App
# (Container Apps) is not registered on this subscription yet.
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.Network \
          Microsoft.DBforPostgreSQL Microsoft.ContainerRegistry Microsoft.KeyVault \
          Microsoft.ManagedIdentity Microsoft.Compute; do
  state="$(az_tsv provider show --namespace "$ns" --query registrationState)"
  if [[ $state == Registered ]]; then
    echo "  ${ns}: registered"
  else
    echo "  ${ns}: ${state}, registering (can take a few minutes)..."
    az provider register --namespace "$ns" --wait -o none
  fi
done

# ---------------------------------------------------------------------------
log "Resource group ${RG}"
az group create --name "$RG" --location "$LOCATION" --tags "${TAGS[@]}" -o none

# ---------------------------------------------------------------------------
log "Log Analytics workspace ${LOG_WORKSPACE} (cap ${LOG_DAILY_CAP_GB} GB/day)"
# Container Apps sends the API's stdout/stderr here. The daily cap stops
# ingestion (not the app) if something gets noisy, which bounds the cost.
az monitor log-analytics workspace create \
  --resource-group "$RG" --workspace-name "$LOG_WORKSPACE" --location "$LOCATION" \
  --retention-time "$LOG_RETENTION_DAYS" --quota "$LOG_DAILY_CAP_GB" \
  --tags "${TAGS[@]}" -o none

# ---------------------------------------------------------------------------
# NSGs. Azure's built-in defaults already deny inbound internet traffic and
# allow traffic within the VNet; the rules below narrow "within the VNet" to
# exactly the flows each tier needs.

nsg_rule() { # <nsg> <name> <priority> <Allow|Deny> <protocol> <source> <destination> <port>...
  local nsg=$1 name=$2 priority=$3 access=$4 protocol=$5 src=$6 dst=$7
  shift 7
  az network nsg rule create \
    --resource-group "$RG" --nsg-name "$nsg" --name "$name" \
    --priority "$priority" --direction Inbound --access "$access" --protocol "$protocol" \
    --source-address-prefixes "$src" --source-port-ranges '*' \
    --destination-address-prefixes "$dst" --destination-port-ranges "$@" \
    -o none
  echo "  ${nsg}: ${priority} ${access} ${name}"
}

log "Network security groups"
# Only create, never re-create: re-running "nsg create" on an existing NSG
# would briefly wipe its custom rules (and with them, public HTTPS access).
for nsg in "$NSG_APP" "$NSG_DB" "$NSG_ADMIN"; do
  if ! az network nsg show --resource-group "$RG" --name "$nsg" -o none 2>/dev/null; then
    az network nsg create --resource-group "$RG" --name "$nsg" --location "$LOCATION" \
      --tags "${TAGS[@]}" -o none
  fi
done

# App tier: the public HTTPS entry point (requirement #1). Port 80 is allowed
# only so Container Apps can redirect plain HTTP to HTTPS.
nsg_rule "$NSG_APP" Allow-Web-From-Internet 100 Allow Tcp Internet "$SNET_APP_CIDR" 80 443

# Database tier: PostgreSQL from the app and admin subnets only (requirement #2).
nsg_rule "$NSG_DB" Allow-Postgres-From-App   100 Allow Tcp "$SNET_APP_CIDR"   "$SNET_DB_CIDR" 5432
nsg_rule "$NSG_DB" Allow-Postgres-From-Admin 110 Allow Tcp "$SNET_ADMIN_CIDR" "$SNET_DB_CIDR" 5432
# The server's own nodes talk to each other inside the subnet (for example for HA).
nsg_rule "$NSG_DB" Allow-Within-Db-Subnet    120 Allow '*' "$SNET_DB_CIDR"    "$SNET_DB_CIDR" '*'
# The VirtualNetwork tag includes Azure's platform address 168.63.129.16, so
# allow AzureLoadBalancer explicitly before the broad deny below.
nsg_rule "$NSG_DB" Allow-AzureLoadBalancer   130 Allow '*' AzureLoadBalancer  '*' '*'
nsg_rule "$NSG_DB" Deny-Other-VNet-Inbound  4000 Deny  '*' VirtualNetwork     '*' '*'

# Admin tier: no public IP and nothing allowed in yet. Phase 4 adds a single
# SSH rule from Azure Bastion once the Bastion tier is chosen (requirement #3).
nsg_rule "$NSG_ADMIN" Allow-AzureLoadBalancer  130 Allow '*' AzureLoadBalancer '*' '*'
nsg_rule "$NSG_ADMIN" Deny-Other-VNet-Inbound 4000 Deny  '*' VirtualNetwork    '*' '*'

# ---------------------------------------------------------------------------
log "Virtual network ${VNET} (${VNET_CIDR})"
# Only create, never re-create: re-running "vnet create" on an existing VNet
# would try to replace its subnet list.
if az network vnet show --resource-group "$RG" --name "$VNET" -o none 2>/dev/null; then
  echo "  exists"
else
  az network vnet create --resource-group "$RG" --name "$VNET" --location "$LOCATION" \
    --address-prefixes "$VNET_CIDR" --tags "${TAGS[@]}" -o none
fi

subnet() { # <name> <cidr> <nsg> [delegation]
  local name=$1 cidr=$2 nsg=$3 delegation=${4:-}
  if az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name "$name" -o none 2>/dev/null; then
    echo "  ${name}: exists, ensuring NSG ${nsg}"
    az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" --name "$name" \
      --network-security-group "$nsg" -o none
    return
  fi
  local args=(--resource-group "$RG" --vnet-name "$VNET" --name "$name"
              --address-prefixes "$cidr" --network-security-group "$nsg"
              # Azure is moving new subnets to "private" (no implicit internet
              # egress). Be explicit: the app must reach ACR and Foundry, the
              # jumpbox must install psql, and PostgreSQL must reach Azure
              # Storage for backups. Inbound is unaffected (NSGs above).
              --default-outbound-access true)
  [[ -n $delegation ]] && args+=(--delegations "$delegation")
  az network vnet subnet create "${args[@]}" -o none
  echo "  ${name}: created (${cidr}${delegation:+, delegated to ${delegation}})"
}

log "Subnets"
subnet "$SNET_APP"   "$SNET_APP_CIDR"   "$NSG_APP"   Microsoft.App/environments
subnet "$SNET_DB"    "$SNET_DB_CIDR"    "$NSG_DB"    Microsoft.DBforPostgreSQL/flexibleServers
subnet "$SNET_ADMIN" "$SNET_ADMIN_CIDR" "$NSG_ADMIN"

# ---------------------------------------------------------------------------
log "Private DNS zone ${PG_DNS_ZONE}"
# PostgreSQL (phase 3) registers its private IP here. Linking the zone to the
# VNet means only resources inside the VNet can resolve the server's name.
if az network private-dns zone show --resource-group "$RG" --name "$PG_DNS_ZONE" -o none 2>/dev/null; then
  echo "  zone exists"
else
  az network private-dns zone create --resource-group "$RG" --name "$PG_DNS_ZONE" \
    --tags "${TAGS[@]}" -o none
fi

DNS_LINK="link-${VNET}"
if az network private-dns link vnet show --resource-group "$RG" --zone-name "$PG_DNS_ZONE" \
     --name "$DNS_LINK" -o none 2>/dev/null; then
  echo "  VNet link exists"
else
  az network private-dns link vnet create --resource-group "$RG" --zone-name "$PG_DNS_ZONE" \
    --name "$DNS_LINK" --virtual-network "$VNET" --registration-enabled false -o none
fi

# ---------------------------------------------------------------------------
log "Done. Subnets:"
az network vnet subnet list --resource-group "$RG" --vnet-name "$VNET" \
  --query "[].{name:name, prefix:addressPrefix, delegatedTo:delegations[0].serviceName, nsg:networkSecurityGroup.id}" \
  -o table | sed -E 's#/subscriptions/[^ ]*/networkSecurityGroups/##'
echo
echo "Next: infra/README.md, 'Verify phase 1'."
