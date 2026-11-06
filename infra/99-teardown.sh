#!/usr/bin/env bash
# Delete everything this project created in Azure by deleting its resource group.
#
# This is permanent and includes the PostgreSQL server and all journal data
# (and the resource-group budget). You must type the group name to confirm.
#
# Not deleted: the subscription-wide budget, any AI resources outside this group, and
# resource provider registrations (they are free).

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

if ! az group show --name "$RG" -o none 2>/dev/null; then
  echo "Resource group ${RG} does not exist; nothing to delete."
  exit 0
fi

echo "Resources in ${RG}:"
az resource list --resource-group "$RG" --query "[].{name:name, type:type}" -o table

printf '\nSubscription: %s\n' "$SUBSCRIPTION_NAME"
read -r -p "Type the resource group name (${RG}) to delete it permanently: " reply
[[ $reply == "$RG" ]] || { echo "Name did not match; nothing was deleted."; exit 1; }

# A deleted Log Analytics workspace is otherwise kept for 14 days, and until
# then a workspace with the same name can only be recreated in its original
# region. Deleting it permanently lets phase 1 rebuild it in any region.
if az monitor log-analytics workspace show --resource-group "$RG" \
     --workspace-name "$LOG_WORKSPACE" -o none 2>/dev/null; then
  log "Permanently deleting Log Analytics workspace ${LOG_WORKSPACE}"
  az monitor log-analytics workspace delete --resource-group "$RG" \
    --workspace-name "$LOG_WORKSPACE" --force true --yes -o none
fi

log "Deleting ${RG} (runs in the background in Azure; takes several minutes)"
az group delete --name "$RG" --yes --no-wait
echo "Wait for it to finish with: az group wait --deleted --resource-group ${RG}"
echo
echo "Key Vault ${KEY_VAULT} stays soft-deleted for ${KV_SOFT_DELETE_DAYS} days, with its secrets."
echo "Re-running ./infra/02-secrets.sh within that time recovers it."
echo "To delete it and its secrets for good instead: az keyvault purge --name ${KEY_VAULT}"
