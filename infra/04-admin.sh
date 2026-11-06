#!/usr/bin/env bash
# Phase 4: administration path, schema, and the app's database role.
#
# Creates:
#   - Azure Bastion, Developer SKU (free): browser-based SSH from the Azure
#     portal, with no public IP on the VM and no SSH port open to the internet
#   - a jumpbox VM in snet-admin with no public IP. Its only login is an SSH key
#     whose private half goes straight into Key Vault (jumpbox-ssh-key)
#   - "Key Vault Secrets User" for the VM's own identity on exactly two
#     secrets, the database passwords, so it can sign in to PostgreSQL
#     without anyone typing or copying a password
# Then, on the jumpbox, through `az vm run-command` (Azure's control plane:
# Entra sign-in + Azure RBAC, audited in the activity log, no inbound port):
#   - applies database_setup.sql
#   - creates the least-privilege journal_app role and checks its permissions
# Finally, stores database-url in Key Vault for the Container App (phase 6).
#
# Requirement #3: no management port is reachable from the internet; every
#                 admin path requires an Entra sign-in; no password is typed,
#                 printed, passed as an argument, or written to the repo.
# Requirement #5: the schema the API expects, and a role that can use it.
#
# The jumpbox is deallocated at the end (set JUMPBOX_KEEP_RUNNING=1 to skip),
# so it costs only its disk (~$1.50/month) until you start it again.
# Safe to re-run.

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$(dirname "$0")/remote/jumpbox-setup.sh"
SCHEMA_SQL="${REPO_ROOT}/database_setup.sql"

# ---------------------------------------------------------------------------
# Prerequisites from phases 1-3
VNET_ID="$(az_tsv network vnet show --resource-group "$RG" --name "$VNET" --query id 2>/dev/null)" \
  || { echo "VNet ${VNET} not found. Run ./infra/01-foundation.sh first." >&2; exit 1; }
SNET_ADMIN_ID="$(az_tsv network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" \
  --name "$SNET_ADMIN" --query id)"
KV_ID="$(az_tsv keyvault show --name "$KEY_VAULT" --query id 2>/dev/null)" \
  || { echo "Key Vault ${KEY_VAULT} not found. Run ./infra/02-secrets.sh first." >&2; exit 1; }
for name in "$SECRET_PG_ADMIN_PASSWORD" "$SECRET_PG_APP_PASSWORD"; do
  secret_exists "$name" || { echo "Secret ${name} not found. Run ./infra/02-secrets.sh first." >&2; exit 1; }
done
PG_STATE="$(az_tsv postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" \
  --query state 2>/dev/null || true)"
if [[ $PG_STATE != Ready ]]; then
  echo "PostgreSQL server ${PG_SERVER} is '${PG_STATE:-missing}', not Ready. Run ./infra/03-database.sh first." >&2
  exit 1
fi
PG_FQDN="$(az_tsv postgres flexible-server show --resource-group "$RG" --name "$PG_SERVER" \
  --query fullyQualifiedDomainName)"
# Without the zone's VNet link, nothing in the VNet can resolve the server's
# name. (A teardown still finishing in the background can delete a new link.)
if [[ $(az_tsv network private-dns link vnet list --resource-group "$RG" --zone-name "$PG_DNS_ZONE" \
      --query "[?virtualNetworkLinkState=='Completed'] | length(@)" 2>/dev/null || echo 0) -eq 0 ]]; then
  echo "Private DNS zone ${PG_DNS_ZONE} isn't linked to ${VNET}, so the VNet can't resolve" >&2
  echo "${PG_FQDN}. Run ./infra/01-foundation.sh to recreate the link, then re-run this script." >&2
  exit 1
fi

echo "Bastion      : ${BASTION} (Developer SKU, free)"
echo "Jumpbox      : ${JUMPBOX_VM} (${JUMPBOX_SIZE}, ${JUMPBOX_IMAGE}, no public IP, subnet ${SNET_ADMIN})"
echo "Database     : schema + role ${PG_APP_USER} on ${PG_FQDN}"
echo "Cost         : ~\$0.013/hour while the jumpbox runs; ~\$1.50/month for its disk when deallocated"
confirm "create Bastion and the jumpbox in ${RG}, then set up the database"

WORK_TMP="$(mktemp -d)"
chmod 700 "$WORK_TMP"
trap 'rm -rf "$WORK_TMP"' EXIT

tags_json="$(printf '"%s",' "${TAGS[@]}" | sed -E 's/"([^=]+)=([^"]*)"/"\1": "\2"/g; s/,$//')"

# ---------------------------------------------------------------------------
log "Bastion ${BASTION}"
# Developer SKU uses a shared, Microsoft-managed pool: no AzureBastionSubnet,
# no public IP, no hourly charge. One connection at a time, portal only.
BASTION_URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.Network/bastionHosts/${BASTION}?api-version=2024-05-01"
bastion_state() { az_tsv rest --method get --url "$BASTION_URL" --query properties.provisioningState 2>/dev/null || true; }
if [[ $(bastion_state) == Succeeded ]]; then
  echo "  exists"
else
  cat >"$WORK_TMP/bastion.json" <<EOF
{
  "location": "${LOCATION}",
  "tags": { ${tags_json} },
  "sku": { "name": "Developer" },
  "properties": { "virtualNetwork": { "id": "${VNET_ID}" } }
}
EOF
  az rest --method put --url "$BASTION_URL" --body "@$(native_path "$WORK_TMP/bastion.json")" -o none
  for attempt in $(seq 1 40); do
    state="$(bastion_state)"
    [[ $state == Succeeded ]] && break
    if [[ $state == Failed || $attempt -eq 40 ]]; then
      echo "  Bastion provisioning is '${state}'. Check portal > ${RG} > ${BASTION}." >&2
      exit 1
    fi
    sleep 15
  done
  echo "  created"
fi

# ---------------------------------------------------------------------------
log "Jumpbox ${JUMPBOX_VM}"
vm_power() {
  az_tsv vm get-instance-view --resource-group "$RG" --name "$JUMPBOX_VM" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" 2>/dev/null || true
}
if az vm show --resource-group "$RG" --name "$JUMPBOX_VM" -o none 2>/dev/null; then
  echo "  exists"
  if ! secret_exists "$SECRET_JUMPBOX_SSH_KEY"; then
    echo "  warning: ${SECRET_JUMPBOX_SSH_KEY} is missing from Key Vault, so Bastion can't sign in." >&2
    echo "  Delete the VM (az vm delete -g ${RG} -n ${JUMPBOX_VM} --yes) and re-run to get a new key." >&2
  fi
  if [[ $(vm_power) != PowerState/running ]]; then
    echo "  starting it"
    az vm start --resource-group "$RG" --name "$JUMPBOX_VM" -o none
  fi
else
  # Check the size is offered to this subscription here and fits its vCPU
  # quota, which is set per VM family and is often 0 for newer families.
  # Otherwise az vm create fails with a long traceback.
  # (join puts the values on one line; tsv would print one per line.)
  echo "  checking ${JUMPBOX_SIZE} availability and quota (about a minute)"
  sku_info="$(az_tsv vm list-skus --location "$LOCATION" --resource-type virtualMachines \
    --size "$JUMPBOX_SIZE" \
    --query "[?name=='${JUMPBOX_SIZE}'] | [0].join(' ', [family, capabilities[?name=='vCPUs'].value | [0], to_string(length(restrictions))])")"
  read -r size_family size_vcpus size_restrictions <<<"$sku_info"
  if [[ -z $size_family || $size_restrictions != 0 ]]; then
    echo "  ${JUMPBOX_SIZE} isn't available to this subscription in ${LOCATION}." >&2
    echo "  Re-run with another size, for example JUMPBOX_SIZE=Standard_B1s ./infra/04-admin.sh" >&2
    exit 1
  fi
  read -r quota_used quota_limit <<<"$(az_tsv vm list-usage --location "$LOCATION" \
    --query "[?name.value=='${size_family}'] | [0].join(' ', [to_string(currentValue), to_string(limit)])")"
  if [[ ! $size_vcpus =~ ^[0-9]+$ || ! $quota_used =~ ^[0-9]+$ || ! $quota_limit =~ ^[0-9]+$ ]]; then
    echo "  couldn't read the ${size_family} quota ('${quota_used}'/'${quota_limit}', ${size_vcpus} vCPUs);" >&2
    echo "  check it with: az vm list-usage -l ${LOCATION} -o table" >&2
    exit 1
  fi
  if (( quota_used + size_vcpus > quota_limit )); then
    echo "  ${JUMPBOX_SIZE} needs ${size_vcpus} vCPU(s) of ${size_family} quota in ${LOCATION}," >&2
    echo "  but ${quota_used} of ${quota_limit} are in use. Either:" >&2
    echo "    - re-run with a size from a family you have quota for, listed by:" >&2
    echo "        az vm list-usage -l ${LOCATION} -o table" >&2
    echo "      for example JUMPBOX_SIZE=Standard_B1s ./infra/04-admin.sh (standardBSFamily), or" >&2
    echo "    - request more quota (free): portal > Quotas > Compute > ${size_family}, ${LOCATION}" >&2
    exit 1
  fi
  echo "  ${JUMPBOX_SIZE}: ${size_vcpus} vCPU(s), ${size_family} quota ${quota_used}/${quota_limit} in use"

  # RSA in PEM format, the key type Bastion's Key Vault option accepts. The
  # private key goes into Key Vault and the local copy is deleted; the VM
  # gets only the public half. No password login exists.
  ssh-keygen -q -t rsa -b 4096 -m PEM -N "" -C "${JUMPBOX_ADMIN}@${JUMPBOX_VM}" -f "$WORK_TMP/id_rsa"
  store_secret "$SECRET_JUMPBOX_SSH_KEY" "$WORK_TMP/id_rsa" "ssh-private-key ${JUMPBOX_ADMIN}@${JUMPBOX_VM}"
  echo "  SSH private key stored as ${SECRET_JUMPBOX_SSH_KEY}"

  # --public-ip-address "" and --nsg "": no public IP and no NIC-level NSG;
  # the snet-admin NSG from phase 1 applies.
  az vm create --resource-group "$RG" --name "$JUMPBOX_VM" --location "$LOCATION" \
    --image "$JUMPBOX_IMAGE" --size "$JUMPBOX_SIZE" \
    --subnet "$SNET_ADMIN_ID" --public-ip-address "" --nsg "" \
    --admin-username "$JUMPBOX_ADMIN" --authentication-type ssh \
    --ssh-key-values "$(native_path "$WORK_TMP/id_rsa.pub")" \
    --assign-identity "[system]" \
    --storage-sku Standard_LRS --os-disk-delete-option Delete --nic-delete-option Delete \
    --tags "${TAGS[@]}" -o none
  rm -f "$WORK_TMP/id_rsa.pub"
  echo "  created"
fi

log "Daily auto-shutdown at ${JUMPBOX_SHUTDOWN_UTC} UTC"
# A backstop for when you start the jumpbox for a session and forget it.
az vm auto-shutdown --resource-group "$RG" --name "$JUMPBOX_VM" --time "$JUMPBOX_SHUTDOWN_UTC" -o none
echo "  set"

# ---------------------------------------------------------------------------
log "Key Vault access for the jumpbox (two secrets only)"
VM_PRINCIPAL_ID="$(az_tsv vm show --resource-group "$RG" --name "$JUMPBOX_VM" --query identity.principalId)"
for name in "$SECRET_PG_ADMIN_PASSWORD" "$SECRET_PG_APP_PASSWORD"; do
  assign_role "$VM_PRINCIPAL_ID" ServicePrincipal "Key Vault Secrets User" \
    "${KV_ID}/secrets/${name}" "${JUMPBOX_VM} -> ${name}"
done

# ---------------------------------------------------------------------------
log "Setting up the database from the jumpbox (2-5 minutes)"
# The remote script plus its settings. None of these values are secret; the
# jumpbox fetches the passwords from Key Vault itself.
{
  echo "umask 077"
  echo "cat >/root/journal-setup.sh <<'JOURNAL_SETUP_EOF'"
  echo "#!/usr/bin/env bash"
  printf '%s=%q\n' \
    KEY_VAULT "$KEY_VAULT" \
    PG_HOST "$PG_FQDN" \
    PG_DATABASE "$PG_DATABASE" \
    PG_ADMIN_USER "$PG_ADMIN_USER" \
    PG_APP_USER "$PG_APP_USER" \
    SECRET_ADMIN "$SECRET_PG_ADMIN_PASSWORD" \
    SECRET_APP "$SECRET_PG_APP_PASSWORD" \
    PG_CLIENT_VERSION "$PG_CLIENT_VERSION" \
    SCHEMA_SQL_B64 "$(base64 -w0 "$SCHEMA_SQL")"
  cat "$REMOTE_SCRIPT"
  echo "JOURNAL_SETUP_EOF"
  echo "bash /root/journal-setup.sh"
} >"$WORK_TMP/remote.sh"

az_tsv vm run-command invoke --resource-group "$RG" --name "$JUMPBOX_VM" \
  --command-id RunShellScript --scripts "@$(native_path "$WORK_TMP/remote.sh")" \
  --query "value[0].message" >"$WORK_TMP/remote-output.txt"
# run-command always appends a "[stderr]" heading; drop it when nothing follows.
if [[ -z $(sed -n '/^\[stderr\]$/,$p' "$WORK_TMP/remote-output.txt" | sed '1d' | tr -d '[:space:]') ]]; then
  sed -i '/^\[stderr\]$/,$d' "$WORK_TMP/remote-output.txt"
fi
sed 's/^/  /' "$WORK_TMP/remote-output.txt"
if ! grep -q JUMPBOX-SETUP-OK "$WORK_TMP/remote-output.txt"; then
  echo >&2
  echo "Database setup on the jumpbox failed; see the output above. The jumpbox is left running" >&2
  echo "so you can re-run this script or connect through Bastion to investigate." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
log "Secret ${SECRET_DATABASE_URL}"
# What the API's DATABASE_URL will be in phase 6. TLS with full certificate
# and hostname verification against the image's CA bundle (python:slim
# includes ca-certificates). The password is alphanumeric, so no URL-encoding.
app_password="$(az_tsv keyvault secret show --vault-name "$KEY_VAULT" \
  --name "$SECRET_PG_APP_PASSWORD" --query value)"
printf 'postgresql://%s:%s@%s:5432/%s?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt' \
  "$PG_APP_USER" "$app_password" "$PG_FQDN" "$PG_DATABASE" >"$WORK_TMP/database-url"
unset app_password
current=""
if secret_exists "$SECRET_DATABASE_URL"; then
  current="$(az_tsv keyvault secret show --vault-name "$KEY_VAULT" \
    --name "$SECRET_DATABASE_URL" --query value)"
fi
if [[ $current == "$(cat "$WORK_TMP/database-url")" ]]; then
  rm -f "$WORK_TMP/database-url"
  echo "  up to date"
else
  store_secret "$SECRET_DATABASE_URL" "$WORK_TMP/database-url" "postgresql-url"
  echo "  stored"
fi
unset current

# ---------------------------------------------------------------------------
if [[ ${JUMPBOX_KEEP_RUNNING:-0} == 1 ]]; then
  log "Leaving ${JUMPBOX_VM} running (JUMPBOX_KEEP_RUNNING=1); it auto-shuts down at ${JUMPBOX_SHUTDOWN_UTC} UTC"
else
  log "Deallocating ${JUMPBOX_VM} (stops compute billing; start it again with az vm start)"
  az vm deallocate --resource-group "$RG" --name "$JUMPBOX_VM" -o none
  echo "  deallocated"
fi

log "Done"
echo "Next: infra/README.md, 'Verify phase 4'."
