#!/usr/bin/env bash
# Phase 3: database tier.
#
# Creates, from infra/templates/postgres.bicep:
#   - an Azure Database for PostgreSQL Flexible Server with private access
#     (VNet integration) in snet-db: no public endpoint, and only a private IP
#     registered in the phase 1 private DNS zone
#   - the career_journal database
#   - you as the server's Microsoft Entra admin (set PG_ENTRA_ADMIN=0 to skip)
#
# Requirement #2: reachable only from inside the VNet, where the phase 1 NSG
#                 allows port 5432 from snet-app and snet-admin only.
# Requirement #3: the admin password is a Key Vault reference that Azure
#                 Resource Manager resolves itself; it never passes through
#                 this shell or appears in deployment history.
# Requirement #4: automated backups with point-in-time restore.
#
# BILLING STARTS HERE: ~$16/month while the server exists (B1ms + 32 GB).
#
# Safe to re-run: the deployment is declarative and converges on the template.
# The schema and the app's role come in phase 4.

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

TEMPLATE="$(dirname "$0")/templates/postgres.bicep"

# ---------------------------------------------------------------------------
# Prerequisites from phases 1 and 2
if ! SNET_DB_ID="$(az_tsv network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" \
     --name "$SNET_DB" --query id 2>/dev/null)"; then
  echo "Subnet ${SNET_DB} not found. Run ./infra/01-foundation.sh first." >&2
  exit 1
fi
PG_DNS_ZONE_ID="$(az_tsv network private-dns zone show --resource-group "$RG" --name "$PG_DNS_ZONE" --query id)"
if ! KV_ID="$(az_tsv keyvault show --name "$KEY_VAULT" --query id 2>/dev/null)"; then
  echo "Key Vault ${KEY_VAULT} not found. Run ./infra/02-secrets.sh first." >&2
  exit 1
fi
if [[ $(az_tsv keyvault secret list --vault-name "$KEY_VAULT" \
      --query "[?name=='${SECRET_PG_ADMIN_PASSWORD}'] | length(@)") -eq 0 ]]; then
  echo "Secret ${SECRET_PG_ADMIN_PASSWORD} not found. Run ./infra/02-secrets.sh first." >&2
  exit 1
fi

ENTRA_ID="" ENTRA_NAME=""
if [[ $PG_ENTRA_ADMIN == 1 ]]; then # Changed to 0 from 1
  ENTRA_ID="$(az_tsv ad signed-in-user show --query id)"
  ENTRA_NAME="$(az_tsv ad signed-in-user show --query userPrincipalName)"
fi

echo "Server       : ${PG_SERVER} (PostgreSQL ${PG_VERSION}, ${PG_SKU}, ${PG_STORAGE_GB} GB)"
echo "Network      : private access only, subnet ${SNET_DB}, zone ${PG_DNS_ZONE}"
echo "Backups      : ${PG_BACKUP_DAYS} days, point-in-time restore"
echo "Admins       : ${PG_ADMIN_USER} (password in Key Vault)${ENTRA_NAME:+, Entra: ${ENTRA_NAME}}"
echo "Cost         : ~\$16/month from now until teardown"
confirm "create the PostgreSQL server in ${RG} (takes 5-15 minutes)"

WORK_TMP="$(mktemp -d)"
trap 'rm -rf "$WORK_TMP"' EXIT

# ---------------------------------------------------------------------------
log "Bicep CLI"
if az bicep version >/dev/null 2>&1; then
  echo "  installed"
else
  az bicep install
fi

# ---------------------------------------------------------------------------
log "Allow Azure Resource Manager to read the admin password from ${KEY_VAULT}"
# Needed for Key Vault references in deployment parameters. Only identities
# with the vault's deploy/action permission (Owner, Contributor) can use it,
# and only for deployments; it doesn't give anyone read access to secrets.
if [[ $(az_tsv keyvault show --name "$KEY_VAULT" --query properties.enabledForTemplateDeployment) == true ]]; then
  echo "  already enabled"
else
  az keyvault update --name "$KEY_VAULT" --enabled-for-template-deployment true -o none
  echo "  enabled"
fi

# ---------------------------------------------------------------------------
log "Deploying ${PG_SERVER}"
# The parameters file holds only names, IDs and a *reference* to the secret,
# never the password itself.
tags_json="$(printf '"%s",' "${TAGS[@]}" | sed -E 's/"([^=]+)=([^"]*)"/"\1": "\2"/g; s/,$//')"

write_params() { # <zone, or "" for Azure's choice>
cat >"$WORK_TMP/params.json" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "serverName":            { "value": "${PG_SERVER}" },
    "location":              { "value": "${LOCATION}" },
    "tags":                  { "value": { ${tags_json} } },
    "postgresVersion":       { "value": "${PG_VERSION}" },
    "skuName":               { "value": "${PG_SKU}" },
    "skuTier":               { "value": "${PG_TIER}" },
    "availabilityZone":      { "value": "${1}" },
    "storageSizeGB":         { "value": ${PG_STORAGE_GB} },
    "backupRetentionDays":   { "value": ${PG_BACKUP_DAYS} },
    "administratorLogin":    { "value": "${PG_ADMIN_USER}" },
    "administratorLoginPassword": {
      "reference": {
        "keyVault": { "id": "${KV_ID}" },
        "secretName": "${SECRET_PG_ADMIN_PASSWORD}"
      }
    },
    "delegatedSubnetId":     { "value": "${SNET_DB_ID}" },
    "privateDnsZoneId":      { "value": "${PG_DNS_ZONE_ID}" },
    "databaseName":          { "value": "${PG_DATABASE}" },
    "entraAdminObjectId":    { "value": "${ENTRA_ID}" },
    "entraAdminPrincipalName": { "value": "${ENTRA_NAME}" }
  }
}
EOF
}

# When a create fails (for example SkuNotAvailable), Azure has often already
# started building the server. It then deletes it (portal state "Dropping"),
# and the name stays taken until that finishes, which can take several
# minutes. Starting the next attempt sooner fails with ServerNameAlreadyExists.
NAME_CHECK_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.DBforPostgreSQL/locations/${LOCATION}/checkNameAvailability?api-version=2025-08-01"
printf '{"name":"%s","type":"Microsoft.DBforPostgreSQL/flexibleServers"}' "$PG_SERVER" \
  >"$WORK_TMP/name-check.json"

wait_for_failed_server_cleanup() {
  local state free
  for attempt in $(seq 1 60); do
    state="$(az_tsv postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" \
      --query state 2>/dev/null || true)"
    if [[ -n $state && $state != Dropping ]]; then
      return 0                                   # a real, usable server
    fi
    if [[ -z $state ]]; then
      free="$(az_tsv rest --method post --url "$NAME_CHECK_URL" \
        --body "@$(native_path "$WORK_TMP/name-check.json")" --query nameAvailable)"
      [[ $free == true ]] && return 0            # gone, name released
    fi
    (( attempt == 1 )) && echo "  waiting for Azure to remove a failed server and release its name (can take several minutes)..."
    sleep 15
  done
  echo "  ${PG_SERVER} is still not available after 15 minutes. Re-run this script later," >&2
  echo "  or set SUFFIX to a new value to use a different name." >&2
  exit 1
}

wait_for_failed_server_cleanup

# A server's zone can't be changed by redeploying, so once it exists, keep it.
existing_zone="$(az_tsv postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" \
  --query availabilityZone 2>/dev/null || true)"
if [[ -n $existing_zone ]]; then
  zones=("$existing_zone")
  echo "  server exists in zone ${existing_zone}; updating it there"
else
  read -r -a zones <<<"$PG_ZONES"
fi

deployed=0
for zone in "${zones[@]}"; do
  [[ $zone == any ]] && zone=""
  write_params "$zone"
  DEPLOYMENT="postgres-$(date -u +%Y%m%d-%H%M%S)"
  echo "  deployment ${DEPLOYMENT}, zone ${zone:-any} (watch: portal > ${RG} > Deployments)"
  if az deployment group create --resource-group "$RG" --name "$DEPLOYMENT" \
       --template-file "$(native_path "$TEMPLATE")" \
       --parameters "@$(native_path "$WORK_TMP/params.json")" -o none 2>"$WORK_TMP/error.txt"; then
    deployed=1
    break
  fi
  # Only a capacity error is worth retrying in another zone; anything else
  # (bad parameter, permissions, Entra admin) would just fail again.
  failures="$(az deployment operation group list --resource-group "$RG" --name "$DEPLOYMENT" \
    --query "[?properties.provisioningState=='Failed'].properties.statusMessage" -o json 2>/dev/null || true)"
  if grep -q SkuNotAvailable <<<"$failures$(cat "$WORK_TMP/error.txt")"; then
    echo "  zone ${zone:-any}: ${PG_SKU} not available to this subscription (SkuNotAvailable)"
    wait_for_failed_server_cleanup
    continue
  fi
  echo >&2
  echo "Deployment failed (not a capacity error):" >&2
  cat "$WORK_TMP/error.txt" >&2
  echo "Operation details:" >&2
  printf '%s\n' "$failures" >&2
  if [[ $PG_ENTRA_ADMIN == 1 ]] && grep -qi administrators <<<"$failures"; then
    echo "The Entra admin step failed; re-run with PG_ENTRA_ADMIN=0." >&2
  fi
  exit 1
done

if [[ $deployed != 1 ]]; then
  cat >&2 <<EOF

${PG_SKU} isn't available to this subscription in ${LOCATION}, in any of the zones tried (${PG_ZONES}).
No server was created, so nothing is billing. Options, cheapest first:
  1. Request access: portal > Help + support > Create a support request >
     "Service and subscription limits (quotas)" > Azure Database for PostgreSQL
     Flexible Server > region access for ${LOCATION}, Burstable. Quota requests are
     free on every support plan.
  2. Move to a less busy region (e.g. centralus, westus3, northcentralus). The
     VNet must be in the same region, so this means rebuilding phases 1-2
     there; see infra/README.md, "If PostgreSQL isn't available in your region".
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
log "Done"
az postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" \
  --query "{state:state, version:version, sku:sku.name, publicNetworkAccess:network.publicNetworkAccess, fqdn:fullyQualifiedDomainName, backupDays:backup.backupRetentionDays, entraAuth:authConfig.activeDirectoryAuth}" \
  -o json
echo
echo "Next: infra/README.md, 'Verify phase 3'."
