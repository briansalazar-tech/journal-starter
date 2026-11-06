#!/usr/bin/env bash
# Phase 2: identity and secrets.
#
# Creates:
#   - a Key Vault that uses Azure RBAC (Entra ID) for access, with audit logs
#     sent to the phase 1 Log Analytics workspace
#   - "Key Vault Secrets Officer" for you, on this vault only
#   - a user-assigned managed identity for the API, with "Key Vault Secrets
#     User" (read-only) on this vault only; the Container App uses it in phase 6
#   - secrets:
#       pg-admin-password  generated: PostgreSQL server admin (phase 3)
#       pg-app-password    generated: least-privilege journal_app role (phase 4)
#       openai-api-key     you paste it at a hidden prompt (can skip and re-run later)
#
# Requirement #3: secret values are never printed, never passed as command-line
# arguments (they'd land in shell history), and never written inside the repo.
# They pass through a private temp file that is deleted immediately.
#
# Safe to re-run: existing secrets are kept, never silently rotated (rotating
# a database password here would lock the app out). To replace the Foundry key:
#   ROTATE_OPENAI_KEY=1 ./infra/02-secrets.sh

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

if ! az network vnet show --resource-group "$RG" --name "$VNET" -o none 2>/dev/null; then
  echo "Phase 1 resources not found in ${RG}. Run ./infra/01-foundation.sh first." >&2
  exit 1
fi

echo "Key Vault    : ${KEY_VAULT} (RBAC, ${KV_SOFT_DELETE_DAYS}-day soft delete, audit logs on)"
echo "Identity     : ${APP_IDENTITY} (read-only access to secrets)"
confirm "create Key Vault, managed identity and secrets in ${RG}"

# Private scratch directory for secret values in transit; always removed.
SECRETS_TMP="$(mktemp -d)"
chmod 700 "$SECRETS_TMP"
trap 'rm -rf "$SECRETS_TMP"' EXIT

# ---------------------------------------------------------------------------
log "Key Vault ${KEY_VAULT}"
if az keyvault show --name "$KEY_VAULT" -o none 2>/dev/null; then
  echo "  exists"
elif [[ $(az_tsv keyvault list-deleted --query "[?name=='${KEY_VAULT}'] | length(@)") -gt 0 ]]; then
  # A previous teardown soft-deleted it; the name stays reserved until purged.
  echo "  found soft-deleted from an earlier teardown, recovering it (and its secrets)"
  az keyvault recover --name "$KEY_VAULT" -o none
else
  # RBAC mode: access is granted with Azure role assignments (audited, scoped,
  # tied to Entra identities) instead of legacy per-vault access policies.
  # Purge protection is left off so a lab teardown can free the name; turn it
  # on for anything holding data you can't regenerate.
  az keyvault create --resource-group "$RG" --name "$KEY_VAULT" --location "$LOCATION" \
    --sku standard --enable-rbac-authorization true \
    --retention-days "$KV_SOFT_DELETE_DAYS" --tags "${TAGS[@]}" -o none
  echo "  created"
fi
KV_ID="$(az_tsv keyvault show --name "$KEY_VAULT" --query id)"

# ---------------------------------------------------------------------------
log "Audit logs for ${KEY_VAULT}"
# Records who read or changed which secret, and when, in Log Analytics.
if az monitor diagnostic-settings show --name kv-audit --resource "$KV_ID" -o none 2>/dev/null; then
  echo "  exists"
else
  LAW_ID="$(az_tsv monitor log-analytics workspace show --resource-group "$RG" \
    --workspace-name "$LOG_WORKSPACE" --query id)"
  printf '[{"categoryGroup":"audit","enabled":true}]' >"$SECRETS_TMP/logs.json"
  az monitor diagnostic-settings create --name kv-audit --resource "$KV_ID" \
    --workspace "$LAW_ID" --logs "@$(native_path "$SECRETS_TMP/logs.json")" -o none
  echo "  sending audit events to ${LOG_WORKSPACE}"
fi

# ---------------------------------------------------------------------------
log "Managed identity ${APP_IDENTITY}"
if az identity show --resource-group "$RG" --name "$APP_IDENTITY" -o none 2>/dev/null; then
  echo "  exists"
else
  az identity create --resource-group "$RG" --name "$APP_IDENTITY" --location "$LOCATION" \
    --tags "${TAGS[@]}" -o none
  echo "  created"
fi
APP_PRINCIPAL_ID="$(az_tsv identity show --resource-group "$RG" --name "$APP_IDENTITY" --query principalId)"

log "Key Vault access (scoped to this vault only)"
# Being subscription Owner lets you manage the vault but NOT read or write its
# secrets; under RBAC that is a separate, explicit data-plane role.
ME_ID="$(az_tsv ad signed-in-user show --query id)"
assign_role "$ME_ID"            User             "Key Vault Secrets Officer" "$KV_ID" "you"
assign_role "$APP_PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets User"    "$KV_ID" "$APP_IDENTITY"

# ---------------------------------------------------------------------------
log "Waiting for your Key Vault role to take effect"
# New role assignments can take a few minutes to propagate.
for attempt in $(seq 1 20); do
  if az keyvault secret list --vault-name "$KEY_VAULT" -o none 2>/dev/null; then
    echo "  ready"
    break
  fi
  [[ $attempt -eq 20 ]] && { echo "  still denied after 5 minutes; re-run this script." >&2; exit 1; }
  sleep 15
done

# 32 random letters and digits. Alphanumeric, so it never needs URL-encoding
# inside DATABASE_URL, and it meets Azure PostgreSQL's complexity rules
# (upper, lower and digit; checked below).
generate_password() {
  local LC_ALL=C pw
  while :; do
    # cut reads all of its input, so nothing upstream dies of SIGPIPE.
    pw="$(openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-32)"
    [[ ${#pw} -eq 32 && $pw =~ [A-Z] && $pw =~ [a-z] && $pw =~ [0-9] ]] && break
  done
  printf '%s' "$pw"
}

log "Secrets"
for name in "$SECRET_PG_ADMIN_PASSWORD" "$SECRET_PG_APP_PASSWORD"; do
  if secret_exists "$name"; then
    echo "  ${name}: exists, kept"
  else
    generate_password >"$SECRETS_TMP/value"
    store_secret "$name" "$SECRETS_TMP/value" "password"
    echo "  ${name}: generated and stored"
  fi
done

if secret_exists "$SECRET_OPENAI_API_KEY" && [[ ${ROTATE_OPENAI_KEY:-0} != 1 ]]; then
  echo "  ${SECRET_OPENAI_API_KEY}: exists, kept"
else
  # Hidden prompt: the key is not echoed and not saved in shell history.
  key=""
  if [[ -t 0 ]]; then
    read -r -s -p "  Paste your Foundry API key (input hidden, Enter to skip): " key
    echo
  fi
  if [[ -z $key ]]; then
    echo "  ${SECRET_OPENAI_API_KEY}: skipped; re-run this script before phase 6"
  elif [[ $key =~ [[:space:]] || ${#key} -lt 16 || $key == placeholder ]]; then
    echo "  ${SECRET_OPENAI_API_KEY}: that doesn't look like an API key; not stored" >&2
  else
    printf '%s' "$key" >"$SECRETS_TMP/value"
    store_secret "$SECRET_OPENAI_API_KEY" "$SECRETS_TMP/value" "api-key"
    echo "  ${SECRET_OPENAI_API_KEY}: stored"
  fi
  unset key
fi

# ---------------------------------------------------------------------------
log "Done. Secrets in ${KEY_VAULT} (names only):"
az keyvault secret list --vault-name "$KEY_VAULT" \
  --query "[].{name:name, enabled:attributes.enabled, updated:attributes.updated}" -o table
echo
echo "Next: infra/README.md, 'Verify phase 2'."
