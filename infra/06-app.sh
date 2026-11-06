#!/usr/bin/env bash
# Phase 6: the app tier.
#
# Creates, from infra/templates/containerapp.bicep:
#   - a Container Apps environment (workload profiles, Consumption) in snet-app,
#     sending app and system logs to the phase 1 Log Analytics workspace
#   - the Journal API container app: public HTTPS ingress, the image from
#     phase 5, and DATABASE_URL / OPENAI_API_KEY as Key Vault references
# And narrows the app identity's Key Vault access to exactly the two secrets
# it uses (database-url, openai-api-key), removing the vault-wide read access
# earlier versions of phase 2 granted.
#
# Requirement #1: HTTPS on <app>.<env>.<region>.azurecontainerapps.io with a
#                 Microsoft-managed, publicly trusted certificate; HTTP redirects.
# Requirement #2: replicas run inside snet-app; the database NSG admits them on
#                 5432, and the database has no public endpoint.
# Requirement #3: no secret value passes through this script, the template, or
#                 the app's configuration; Container Apps reads them from Key
#                 Vault with the app's managed identity.
# Requirement #4: minReplicas 1, so the API runs with nobody signed in; journal
#                 data lives in PostgreSQL, not the container.
# Requirement #5: the phase 5 image, with a live database and the AI provider
#                 settings it needs for /analyze.
#
# Image: the newest tag in the registry, or set IMAGE_TAG=<tag>.
# WHAT_IF=1 previews the deployment and changes nothing.
# Cost: ~$4-14/month (one 0.25 vCPU / 0.5 GiB replica, always on).
# Safe to re-run; re-running with a new image tag rolls out a new revision.

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

TEMPLATE="$(dirname "$0")/templates/containerapp.bicep"
WHAT_IF="${WHAT_IF:-0}"

# ---------------------------------------------------------------------------
# Prerequisites from phases 1-5
SNET_APP_ID="$(az_tsv network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" \
  --name "$SNET_APP" --query id 2>/dev/null)" \
  || { echo "Subnet ${SNET_APP} not found. Run ./infra/01-foundation.sh first." >&2; exit 1; }
az monitor log-analytics workspace show --resource-group "$RG" --workspace-name "$LOG_WORKSPACE" -o none 2>/dev/null \
  || { echo "Log Analytics workspace ${LOG_WORKSPACE} not found. Run ./infra/01-foundation.sh first." >&2; exit 1; }
IDENTITY_ID="$(az_tsv identity show --resource-group "$RG" --name "$APP_IDENTITY" --query id 2>/dev/null)" \
  || { echo "Identity ${APP_IDENTITY} not found. Run ./infra/02-secrets.sh first." >&2; exit 1; }
APP_PRINCIPAL_ID="$(az_tsv identity show --resource-group "$RG" --name "$APP_IDENTITY" --query principalId)"
KV_ID="$(az_tsv keyvault show --name "$KEY_VAULT" --query id)"
KV_URI="$(az_tsv keyvault show --name "$KEY_VAULT" --query properties.vaultUri)"
for name in "$SECRET_DATABASE_URL" "$SECRET_OPENAI_API_KEY"; do
  if ! secret_exists "$name"; then
    case $name in
      "$SECRET_DATABASE_URL")   echo "Secret ${name} not found. Run ./infra/04-admin.sh first." >&2 ;;
      "$SECRET_OPENAI_API_KEY") echo "Secret ${name} not found. Run ./infra/02-secrets.sh and paste your AI provider key." >&2 ;;
    esac
    exit 1
  fi
done
[[ $(az_tsv postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" --query state 2>/dev/null) == Ready ]] \
  || { echo "PostgreSQL server ${PG_SERVER} isn't Ready. Check phase 3." >&2; exit 1; }
LOGIN_SERVER="$(az_tsv acr show --name "$ACR" --query loginServer 2>/dev/null)" \
  || { echo "Registry ${ACR} not found. Run ./infra/05-registry.sh first." >&2; exit 1; }
IMAGE_TAG="${IMAGE_TAG:-$(az_tsv acr repository show-tags --name "$ACR" --repository "$IMAGE_REPO" \
  --orderby time_desc --top 1 2>/dev/null || true)}"
if [[ -z $IMAGE_TAG ]] || ! az acr repository show --name "$ACR" --image "${IMAGE_REPO}:${IMAGE_TAG}" -o none 2>/dev/null; then
  echo "Image ${IMAGE_REPO}:${IMAGE_TAG:-<none>} not found in ${ACR}. Run ./infra/05-registry.sh first." >&2
  exit 1
fi
IMAGE="${LOGIN_SERVER}/${IMAGE_REPO}:${IMAGE_TAG}"

echo "Environment  : ${ACA_ENV} (workload profiles, Consumption, subnet ${SNET_APP})"
echo "App          : ${ACA_APP}, public HTTPS, ${ACA_MIN_REPLICAS}-${ACA_MAX_REPLICAS} replicas of ${ACA_CPU} vCPU / ${ACA_MEMORY}"
echo "Image        : ${IMAGE}"
echo "Secrets      : ${SECRET_DATABASE_URL}, ${SECRET_OPENAI_API_KEY} (Key Vault references)"
echo "AI provider  : ${OPENAI_BASE_URL}, model ${OPENAI_MODEL}"
if [[ $WHAT_IF == 1 ]]; then
  echo "Mode         : WHAT_IF=1, preview only; nothing changes"
else
  echo "Cost         : ~\$4-14/month while the app exists (always-on replica)"
  confirm "create the Container Apps environment and app in ${RG} (takes 5-10 minutes)"
fi

WORK_TMP="$(mktemp -d)"
trap 'rm -rf "$WORK_TMP"' EXIT

# HTTP status of a request; the body lands in $WORK_TMP/body. (Git Bash's curl
# is a Windows program and can't write to /dev/null, hence the real file.)
http() { # <curl args>...
  curl -s -o "$(native_path "$WORK_TMP/body")" -w '%{http_code}' "$@" || true
}

tags_json="$(printf '"%s",' "${TAGS[@]}" | sed -E 's/"([^=]+)=([^"]*)"/"\1": "\2"/g; s/,$//')"
cat >"$WORK_TMP/params.json" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location":                  { "value": "${LOCATION}" },
    "tags":                      { "value": { ${tags_json} } },
    "environmentName":           { "value": "${ACA_ENV}" },
    "appName":                   { "value": "${ACA_APP}" },
    "infrastructureSubnetId":    { "value": "${SNET_APP_ID}" },
    "logAnalyticsWorkspaceName": { "value": "${LOG_WORKSPACE}" },
    "identityId":                { "value": "${IDENTITY_ID}" },
    "registryServer":            { "value": "${LOGIN_SERVER}" },
    "image":                     { "value": "${IMAGE}" },
    "keyVaultUri":               { "value": "${KV_URI}" },
    "databaseUrlSecretName":     { "value": "${SECRET_DATABASE_URL}" },
    "openAiKeySecretName":       { "value": "${SECRET_OPENAI_API_KEY}" },
    "openAiBaseUrl":             { "value": "${OPENAI_BASE_URL}" },
    "openAiModel":               { "value": "${OPENAI_MODEL}" },
    "cpu":                       { "value": "${ACA_CPU}" },
    "memory":                    { "value": "${ACA_MEMORY}" },
    "minReplicas":               { "value": ${ACA_MIN_REPLICAS} },
    "maxReplicas":               { "value": ${ACA_MAX_REPLICAS} }
  }
}
EOF

if [[ $WHAT_IF == 1 ]]; then
  log "What-if preview (no changes)"
  az deployment group what-if --resource-group "$RG" \
    --template-file "$(native_path "$TEMPLATE")" \
    --parameters "@$(native_path "$WORK_TMP/params.json")" --no-pretty-print \
    --query "{status:status, error:error, changes:changes[?changeType!='Ignore'].{change:changeType, resource:resourceId}}" -o json \
    | sed -E 's#/subscriptions/[^"]*/providers/##'
  exit 0
fi

# ---------------------------------------------------------------------------
log "Key Vault access for ${APP_IDENTITY} (two secrets only)"
vault_wide_ids() {
  az_tsv role assignment list --scope "$KV_ID" \
    --query "[?principalId=='${APP_PRINCIPAL_ID}' && roleDefinitionName=='Key Vault Secrets User' && ends_with(scope, '/vaults/${KEY_VAULT}')].id"
}
had_vault_wide="$(vault_wide_ids)"
granted=0
for name in "$SECRET_DATABASE_URL" "$SECRET_OPENAI_API_KEY"; do
  scope="${KV_ID}/secrets/${name}"
  if [[ $(az_tsv role assignment list --scope "$scope" \
        --query "[?principalId=='${APP_PRINCIPAL_ID}' && roleDefinitionName=='Key Vault Secrets User'] | length(@)") -eq 0 ]]; then
    granted=1
  fi
  assign_role "$APP_PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets User" "$scope" "${APP_IDENTITY} -> ${name}"
done
if [[ $granted == 1 && -z $had_vault_wide ]]; then
  # Container Apps reads the secrets as soon as the app is created; give new
  # role assignments time to take effect first.
  echo "  waiting 60 seconds for the new access to take effect"
  sleep 60
fi

# ---------------------------------------------------------------------------
log "Deploying ${ACA_ENV} and ${ACA_APP} (5-10 minutes for a new environment)"
DEPLOYMENT="containerapp-$(date -u +%Y%m%d-%H%M%S)"
echo "  deployment ${DEPLOYMENT} (watch: portal > ${RG} > Deployments)"
if ! az deployment group create --resource-group "$RG" --name "$DEPLOYMENT" \
     --template-file "$(native_path "$TEMPLATE")" \
     --parameters "@$(native_path "$WORK_TMP/params.json")" -o none 2>"$WORK_TMP/error.txt"; then
  echo >&2
  echo "Deployment failed:" >&2
  cat "$WORK_TMP/error.txt" >&2
  echo "Failed operations:" >&2
  az deployment operation group list --resource-group "$RG" --name "$DEPLOYMENT" \
    --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, error:properties.statusMessage.error.message}" \
    -o json >&2 2>/dev/null || true
  echo "If a secret couldn't be read, wait a few minutes for role assignments to take effect and re-run." >&2
  exit 1
fi
FQDN="$(az_tsv deployment group show --resource-group "$RG" --name "$DEPLOYMENT" \
  --query properties.outputs.fqdn.value)"
echo "  https://${FQDN}"

# ---------------------------------------------------------------------------
if [[ -n $had_vault_wide ]]; then
  log "Removing ${APP_IDENTITY}'s read access to the whole vault"
  # It now reads only its two secrets, not the database admin password or the
  # jumpbox SSH key.
  while read -r id; do
    [[ -n $id ]] && az role assignment delete --ids "$id" -o none
  done <<<"$had_vault_wide"
  echo "  removed"
fi

# ---------------------------------------------------------------------------
log "Checking https://${FQDN} from the internet"
for attempt in $(seq 1 40); do
  [[ $(http "https://${FQDN}/docs") == 200 ]] && break
  if (( attempt == 40 )); then
    echo "  The API didn't answer within 10 minutes. Recent logs:" >&2
    az containerapp logs show --resource-group "$RG" --name "$ACA_APP" --tail 30 --format text 2>&1 \
      | sed 's/^/    /' >&2 || true
    exit 1
  fi
  sleep 15
done
echo "  /docs: 200 over HTTPS"

openssl s_client -connect "${FQDN}:443" -servername "$FQDN" </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -enddate 2>/dev/null | sed 's/^/  certificate /' || true

redirect="$(curl -s -o "$(native_path "$WORK_TMP/body")" -w '%{http_code} %{redirect_url}' "http://${FQDN}/docs" || true)"
echo "  plain HTTP: ${redirect}"

status="$(http "https://${FQDN}/entries")"
if [[ $status == 200 ]]; then
  echo "  GET /entries: 200 ($(grep -o '"count":[0-9]*' "$WORK_TMP/body" | cut -d: -f2) entries, read from PostgreSQL over the private network)"
else
  echo "  GET /entries returned ${status}; check: az containerapp logs show -g ${RG} -n ${ACA_APP} --tail 50" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
log "Done"
echo "API:  https://${FQDN}"
echo "Docs: https://${FQDN}/docs"
echo
echo "Next: infra/README.md, 'Verify phase 6'."
