#!/usr/bin/env bash
# Shared settings and helpers for every infra/ script.
# This file is sourced by the phase scripts; don't run it directly.
#
# Override any setting by exporting it first, for example:
#   LOCATION=centralus ./infra/01-foundation.sh
#
# Runs in Git Bash on Windows, Linux/WSL, the devcontainer, or Azure Cloud Shell.

# Variables here are used by the scripts that source this file.
# shellcheck disable=SC2034

set -euo pipefail

# Git Bash rewrites arguments that look like POSIX paths (for example the
# resource ID "/subscriptions/...") into "C:/Program Files/Git/subscriptions/...".
# Turn that off so az receives arguments unchanged.
export MSYS_NO_PATHCONV=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# az on Windows ends tsv output with "\r\n"; strip the "\r" so values compare
# and concatenate correctly in bash.
az_tsv() { az "$@" -o tsv | tr -d '\r'; }

log() { printf '\n==> %s\n' "$*"; }

# Convert a temp-file path to one az (a native Windows program under Git Bash)
# can open. No-op on Linux and Cloud Shell.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# Show what is about to happen and where, then ask before changing anything.
# Set YES=1 to skip the prompt (for example in CI).
confirm() {
  printf '\nSubscription : %s (%s)\n' "$SUBSCRIPTION_NAME" "$SUBSCRIPTION_ID"
  printf 'Region       : %s\n' "$LOCATION"
  printf 'Action       : %s\n' "$1"
  [[ ${YES:-0} == 1 ]] && return 0
  read -r -p "Continue? [y/N] " reply
  [[ $reply =~ ^[Yy]$ ]] || { echo "Aborted; nothing was changed."; exit 1; }
}

# Grant an Azure role unless the principal already has it at that scope.
assign_role() { # <principal-object-id> <User|ServicePrincipal> <role> <scope> <label>
  local id=$1 type=$2 role=$3 scope=$4 label=$5
  local count
  count="$(az_tsv role assignment list --scope "$scope" \
    --query "[?principalId=='${id}' && roleDefinitionName=='${role}'] | length(@)")"
  if [[ $count -gt 0 ]]; then
    echo "  ${label}: already has ${role}"
    return
  fi
  # --assignee-principal-type skips a directory lookup that can fail for a
  # just-created identity that hasn't replicated yet.
  az role assignment create --assignee-object-id "$id" --assignee-principal-type "$type" \
    --role "$role" --scope "$scope" -o none
  echo "  ${label}: granted ${role}"
}

secret_exists() { # <name>
  [[ $(az_tsv keyvault secret list --vault-name "$KEY_VAULT" \
    --query "[?name=='${1}'] | length(@)") -gt 0 ]]
}

# Store the contents of a file as a secret, then delete the file. The value
# never appears in argv (and so never in shell history or process listings).
store_secret() { # <name> <file> <description>
  az keyvault secret set --vault-name "$KEY_VAULT" --name "$1" \
    --file "$(native_path "$2")" --encoding utf-8 --description "$3" -o none
  rm -f "$2"
}

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------

if ! az account show >/dev/null 2>&1; then
  echo "Not signed in to Azure. Run 'az login' first." >&2
  exit 1
fi

SUBSCRIPTION_ID="$(az_tsv account show --query id)"
SUBSCRIPTION_NAME="$(az_tsv account show --query name)"

PROJECT="${PROJECT:-journal}"
ENV_NAME="${ENV_NAME:-dev}"
LOCATION="${LOCATION:-centralus}"

# Short, stable suffix for names that must be globally unique (Key Vault,
# Container Registry, PostgreSQL). Same subscription + project + env always
# produces the same suffix, so re-running a script targets the same resources.
SUFFIX="${SUFFIX:-$(printf '%s' "$SUBSCRIPTION_ID-$PROJECT-$ENV_NAME" | sha1sum | cut -c1-5)}"

RG="rg-${PROJECT}-${ENV_NAME}"
TAGS=("project=${PROJECT}" "env=${ENV_NAME}" "managedBy=az-cli")

# ---------------------------------------------------------------------------
# Phase 0: cost guardrails
# ---------------------------------------------------------------------------

BUDGET_NAME="budget-${PROJECT}-${ENV_NAME}"
BUDGET_AMOUNT="${BUDGET_AMOUNT:-40}"   # USD per month, for this resource group
# Defaults to the account you signed in with; override to send alerts elsewhere.
BUDGET_EMAIL="${BUDGET_EMAIL:-$(az_tsv account show --query user.name)}"

# ---------------------------------------------------------------------------
# Phase 1: network foundation
# ---------------------------------------------------------------------------
#
#   10.20.0.0/16   vnet
#   ├─ 10.20.0.0/24   snet-app    Container Apps environment (delegated)
#   ├─ 10.20.1.0/28   snet-db     PostgreSQL Flexible Server (delegated)
#   ├─ 10.20.2.0/29   snet-admin  jumpbox VM for database administration
#   └─ 10.20.3.0/26   (reserved)  AzureBastionSubnet, only if Bastion Basic is needed

LOG_WORKSPACE="log-${PROJECT}-${ENV_NAME}"
LOG_RETENTION_DAYS=30       # included in the per-GB price
LOG_DAILY_CAP_GB=0.15       # ~4.5 GB/month, under the 5 GB/month free allowance

VNET="vnet-${PROJECT}-${ENV_NAME}"
VNET_CIDR="10.20.0.0/16"

SNET_APP="snet-app"
SNET_APP_CIDR="10.20.0.0/24"
SNET_DB="snet-db"
SNET_DB_CIDR="10.20.1.0/28"
SNET_ADMIN="snet-admin"
SNET_ADMIN_CIDR="10.20.2.0/29"
BASTION_SUBNET_CIDR="10.20.3.0/26"

NSG_APP="nsg-${PROJECT}-${ENV_NAME}-app"
NSG_DB="nsg-${PROJECT}-${ENV_NAME}-db"
NSG_ADMIN="nsg-${PROJECT}-${ENV_NAME}-admin"

# Flexible Server with private access requires a zone ending in
# ".private.postgres.database.azure.com" (privatelink.* is for private endpoints).
PG_DNS_ZONE="${PROJECT}-${ENV_NAME}.private.postgres.database.azure.com"

# ---------------------------------------------------------------------------
# Phase 2: identity and secrets
# ---------------------------------------------------------------------------

KEY_VAULT="kv-${PROJECT}-${ENV_NAME}-${SUFFIX}"
KV_SOFT_DELETE_DAYS=7       # minimum; frees the name a week after teardown
APP_IDENTITY="id-${PROJECT}-${ENV_NAME}-app"

# Secret names in Key Vault. Values are generated or prompted for, never stored here.
SECRET_PG_ADMIN_PASSWORD="pg-admin-password"   # server admin login (phase 3)
SECRET_PG_APP_PASSWORD="pg-app-password"       # least-privilege journal_app role (phase 4)
SECRET_OPENAI_API_KEY="openai-api-key"         # AI provider key for /analyze (phase 6)
SECRET_DATABASE_URL="database-url"             # assembled in phase 4, read by the app

# ---------------------------------------------------------------------------
# Phase 3: database tier
# ---------------------------------------------------------------------------

PG_SERVER="psql-${PROJECT}-${ENV_NAME}-${SUFFIX}"
PG_DATABASE="career_journal"
PG_VERSION="${PG_VERSION:-17}"
PG_SKU="${PG_SKU:-Standard_B1ms}"           # Burstable, 1 vCore, 2 GiB, ~$12.40/month
PG_TIER="${PG_TIER:-Burstable}"
PG_STORAGE_GB="${PG_STORAGE_GB:-32}"        # smallest size, ~$3.70/month
PG_BACKUP_DAYS="${PG_BACKUP_DAYS:-7}"       # point-in-time restore window; storage up to the server size is free
# Availability zones to try, in order, when Azure reports SkuNotAvailable.
# Letting Azure choose failed twice in eastus2, so pin zones explicitly.
# "any" means no preference. The Container App doesn't need to match.
PG_ZONES="${PG_ZONES:-1 2 3}"
PG_ADMIN_USER="journaladmin"                # password-auth server admin (password in Key Vault)
# 1 = make the signed-in Azure user the server's Microsoft Entra admin, so
# phase 4 can sign in with an Entra token instead of the admin password.
PG_ENTRA_ADMIN="${PG_ENTRA_ADMIN:-1}"

# ---------------------------------------------------------------------------
# Phase 4: administration
# ---------------------------------------------------------------------------

BASTION="bas-${PROJECT}-${ENV_NAME}"         # Developer SKU: free, browser sessions from the portal
JUMPBOX_VM="vm-${PROJECT}-${ENV_NAME}-admin"
JUMPBOX_SIZE="${JUMPBOX_SIZE:-Standard_B1s}"  # 1 vCPU, 1 GiB, ~$0.013/hour while running (B-series v1 quota)
JUMPBOX_IMAGE="Ubuntu2404"
JUMPBOX_ADMIN="journalops"                  # Linux login; SSH key only, kept in Key Vault
JUMPBOX_SHUTDOWN_UTC="0600"                 # daily auto-shutdown backstop (around midnight US Central)
PG_CLIENT_VERSION="17"                      # psql version installed on the jumpbox
PG_APP_USER="journal_app"                   # least-privilege role the API connects as
SECRET_JUMPBOX_SSH_KEY="jumpbox-ssh-key"    # private key for Bastion connections

# ---------------------------------------------------------------------------
# Phase 5: container registry and image
# ---------------------------------------------------------------------------

ACR="acr${PROJECT}${ENV_NAME}${SUFFIX}"     # globally unique, letters and digits only
ACR_SKU="Basic"                             # ~$5/month, 10 GB included
IMAGE_REPO="journal-api"
IMAGE_PLATFORM="linux/amd64"                # what Container Apps runs

# ---------------------------------------------------------------------------
# Phase 6: Container Apps
# ---------------------------------------------------------------------------

# AI provider the API calls for /entries/{id}/analyze. Not secret; the key is
# the openai-api-key secret in Key Vault. Defaults match the local .env.
OPENAI_BASE_URL="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
OPENAI_MODEL="${OPENAI_MODEL:-gpt-6-luna}"
ACA_CPU="0.25"                              # vCPU per replica
ACA_MEMORY="0.5Gi"                          # must pair with CPU: 0.25 / 0.5Gi, 0.5 / 1Gi, ...
ACA_MIN_REPLICAS=1                          # requirement #4: always running
ACA_MAX_REPLICAS=3                          # x 10 pooled connections each, within B1ms limits
ACA_ENV="cae-${PROJECT}-${ENV_NAME}"
ACA_APP="ca-${PROJECT}-api"
