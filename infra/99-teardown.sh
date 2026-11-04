#!/usr/bin/env bash
# Delete everything this project created in Azure by deleting its resource group.
#
# This is permanent and includes the PostgreSQL server and all journal data
# (and the resource-group budget). You must type the group name to confirm.
#
# Not deleted: the subscription-wide budget, your Foundry (AI) resource, and
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

log "Deleting ${RG} (runs in the background in Azure; takes several minutes)"
az group delete --name "$RG" --yes --no-wait
echo "Track progress with: az group show --name ${RG} --query properties.provisioningState -o tsv"
echo
echo "Key Vault (from phase 2) stays soft-deleted for 90 days and keeps its name reserved."
echo "To reuse the name sooner, after deletion finishes: az keyvault purge --name ${KEY_VAULT}"
