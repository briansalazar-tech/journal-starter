# Azure infrastructure

Phased Azure CLI scripts that deploy the Journal API as two tiers:

- an **app tier**: Azure Container Apps, serving public HTTPS
- a **database tier**: Azure Database for PostgreSQL Flexible Server, reachable only from inside the virtual network

Run one phase at a time and check its results before moving on.

```text
Internet ──HTTPS──► Container Apps env (snet-app 10.20.0.0/24)
                         │ TCP 5432, TLS
                         ▼
                    PostgreSQL Flexible Server (snet-db 10.20.1.0/28, no public access)
                         ▲
                         │ TCP 5432
                    jumpbox VM, no public IP (snet-admin 10.20.2.0/29) ◄── Azure Bastion ◄── you (Azure portal, Entra ID)
```

## Prerequisites

- Azure CLI 2.60 or later, signed in with `az login`, on the subscription you intend to use (check with `az account show`).
- A bash shell: Git Bash on Windows, WSL, the devcontainer, or Azure Cloud Shell.
- Run the scripts from the repository root, for example `./infra/00-budget.sh`.
- **Git Bash only:** before running any of the Verify commands below, run `export MSYS_NO_PATHCONV=1` in that terminal. Otherwise Git Bash rewrites arguments that start with `/`, such as `--scope /subscriptions/...`, into Windows paths, and az fails with `MissingSubscription`. The scripts already set this themselves. Other shells don't need it.

Every script prints the subscription, region and action, then asks before it changes anything. To change a setting, export it before running a script (for example `LOCATION=centralus`). [config.sh](config.sh) lists every setting with its default.

## Phases

| Phase | Script | Creates | Approx. cost |
|---|---|---|---|
| 0 | [00-budget.sh](00-budget.sh) | Resource group, plus a $40/month budget on it with email alerts at 50%, 80% and 100% of actual spend and 100% of forecast | Free |
| 1 | [01-foundation.sh](01-foundation.sh) | Provider registrations, Log Analytics (0.15 GB/day cap), 3 NSGs, VNet and 3 subnets, Postgres private DNS zone | About $0.50/month (the DNS zone) |
| 2 | [02-secrets.sh](02-secrets.sh) | Key Vault (RBAC, with audit logs), the app's managed identity, generated database passwords, AI provider API key | About $0.10/month |
| 3 | [03-database.sh](03-database.sh), [templates/postgres.bicep](templates/postgres.bicep) | PostgreSQL 17 Flexible Server (B1ms, private access only), `career_journal` database, you as Entra admin | About $17.70/month |
| 4 | [04-admin.sh](04-admin.sh), [remote/jumpbox-setup.sh](remote/jumpbox-setup.sh) | Bastion (Developer, free), jumpbox VM with no public IP; schema, least-privilege `journal_app` role, `database-url` secret | About $1.50/month, plus $0.013/hour while the jumpbox runs |
| 5 | [05-registry.sh](05-registry.sh) | Container Registry (Basic, no admin user), pull access for the app's identity; image build, local smoke test, push | About $5/month |
| 6 | [06-app.sh](06-app.sh), [templates/containerapp.bicep](templates/containerapp.bicep) | Container Apps environment in `snet-app`, the API app (public HTTPS, always on), Key Vault references; app identity narrowed to its two secrets | About $4 to $14/month |
| 99 | [99-teardown.sh](99-teardown.sh) | Deletes the resource group and everything in it | — |

Costs are pay-as-you-go prices for Central US, taken from the Azure Retail Prices API in November 2026.

## Phase 0: before provisioning

```bash
./infra/00-budget.sh
```

This budget covers only this project's resource group. Your existing subscription-wide `Labbing-budget` ($50/month, alerts at 75%, 85% and 90%) still covers everything else, including any AI resources. Once this project runs 24/7 (about $26–37/month), it will be close to `Labbing-budget`'s 75% threshold on its own.

## Phase 1: network foundation

```bash
./infra/01-foundation.sh
```

### Verify phase 1

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites

# The budget exists, with four alerts
az rest --method get \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-journal-dev/providers/Microsoft.Consumption/budgets/budget-journal-dev?api-version=2024-08-01" \
  --query "{amount:properties.amount, alerts:properties.notifications.*.[thresholdType, threshold]}"

# Subnets, delegations and NSGs
az network vnet subnet list -g rg-journal-dev --vnet-name vnet-journal-dev \
  --query "[].{name:name, prefix:addressPrefix, delegation:delegations[0].serviceName}" -o table

# The Postgres private DNS zone is linked to the VNet
az network private-dns link vnet list -g rg-journal-dev -z journal-dev.private.postgres.database.azure.com \
  --query "[].{name:name, state:virtualNetworkLinkState}" -o table

# Database-tier rules: 5432 from app and admin subnets only, everything else in the VNet denied
az network nsg rule list -g rg-journal-dev --nsg-name nsg-journal-dev-db \
  --query "sort_by([], &priority)[].{priority:priority, name:name, access:access, from:sourceAddressPrefix, port:destinationPortRange}" -o table
```

**Expected results:**
- `snet-app` is delegated to `Microsoft.App/environments`, and `snet-db` to `Microsoft.DBforPostgreSQL/flexibleServers`.
- The DNS zone has one link, `link-vnet-journal-dev`, in state `Completed`.
- The database NSG allows 5432 only from `10.20.0.0/24` and `10.20.2.0/29`, and denies the rest of the VNet at priority 4000.
- None of the NSGs allow inbound internet traffic except the app tier, on ports 80 and 443.

## Phase 2: identity and secrets

```bash
./infra/02-secrets.sh
```

The script asks for your AI provider's API key at a hidden prompt: an OpenAI key (`sk-...`), or an Azure AI Foundry key from your resource's **Keys and Endpoint** page. The endpoint and model go in `OPENAI_BASE_URL` and `OPENAI_MODEL` in [config.sh](config.sh). Press Enter to skip; re-run the script to add the key later, or use `ROTATE_OPENAI_KEY=1 ./infra/02-secrets.sh` to replace it.

### Verify phase 2

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites

KV=$(az keyvault list -g rg-journal-dev --query "[0].name" -o tsv)

# RBAC on, 7-day soft delete
az keyvault show -n "$KV" \
  --query "{rbac:properties.enableRbacAuthorization, softDeleteDays:properties.softDeleteRetentionInDays}"

# One role assignment on the vault as a whole: you (Officer). The app identity
# gets read access to individual secrets later (phase 6), not to the vault.
az role assignment list --scope "$(az keyvault show -n "$KV" --query id -o tsv)" \
  --query "[].{who:principalName, principalType:principalType, role:roleDefinitionName}" -o table

# Secret names (no values)
az keyvault secret list --vault-name "$KV" --query "[].name" -o tsv

# Each password is 32 characters. This prints only the length, never the value.
az keyvault secret show --vault-name "$KV" -n pg-admin-password --query "length(value)"
```

**Expected results:**
- `rbac` is `true` and `softDeleteDays` is `7`.
- There's one role assignment: a `User` row for you, shown as your guest name (`...#EXT#@...onmicrosoft.com`), with `Key Vault Secrets Officer`.
  - If you set this up before phase 6 existed, you'll also see a `ServicePrincipal` row with `Key Vault Secrets User`. That's the app identity's old vault-wide access, which phase 6 replaces with access to two secrets.
- You see three secret names (two if you skipped the AI key).
- Each password length prints as `32`.
- Your shell history doesn't contain any of the secret values.

## Phase 3: database tier

```bash
./infra/03-database.sh
```

**Billing starts in this phase: about $17.70/month until you tear it down.** The deployment takes 5–15 minutes. To watch it, open the portal and go to **rg-journal-dev → Deployments**.

How the script keeps the admin password private:
- The template's parameters file holds only a reference to the `pg-admin-password` secret. Azure Resource Manager fetches the value from Key Vault itself, so it never passes through your shell.
- The template marks that parameter `@secure()`, which keeps it out of deployment history.
- For the reference to work, the script turns on the vault's "enabled for template deployment" setting.

Private access is fixed when the server is created and can't be changed later.

### Verify phase 3

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites

PG=$(az postgres flexible-server list -g rg-journal-dev --query "[0].name" -o tsv)
FQDN=$(az postgres flexible-server show -g rg-journal-dev -n "$PG" --query fullyQualifiedDomainName -o tsv)

# Ready, private access only, B1ms, 7-day backups, Entra auth on
az postgres flexible-server show -g rg-journal-dev -n "$PG" \
  --query "{state:state, version:version, sku:sku.name, publicNetworkAccess:network.publicNetworkAccess, backupDays:backup.backupRetentionDays, entraAuth:authConfig.activeDirectoryAuth, passwordAuth:authConfig.passwordAuth}"

# The server's only address is a private IP in snet-db, registered in the private DNS zone
az network private-dns record-set a list -g rg-journal-dev -z journal-dev.private.postgres.database.azure.com \
  --query "[].{name:name, ip:aRecords[0].ipv4Address}" -o table

# TLS is required for every connection
az postgres flexible-server parameter show -g rg-journal-dev -s "$PG" -n require_secure_transport --query value -o tsv

# The app database exists, and you are the Entra admin
az postgres flexible-server db list -g rg-journal-dev -s "$PG" --query "[].name" -o tsv
az postgres flexible-server microsoft-entra-admin list -g rg-journal-dev -s "$PG" --query "[].principalName" -o tsv

# Requirement #2, from your laptop (outside the VNet): no public address, no connection
nslookup "$FQDN"
timeout 5 bash -c "</dev/tcp/$FQDN/5432" 2>/dev/null && echo "REACHABLE from the internet (bad)" || echo "Not reachable from the internet (expected)"
```

**Expected results:**
- The server shows `state` `Ready`, `version` `17`, `sku` `Standard_B1ms`, `publicNetworkAccess` `Disabled`, and `backupDays` `7`. Both `entraAuth` and `passwordAuth` are `Enabled`.
- There's one A record pointing at `10.20.1.x`, which is inside `snet-db`.
- `require_secure_transport` is `on`.
- The database list includes `career_journal`. The others (`postgres`, `azure_maintenance`, `azure_sys`) are created by Azure.
- The Entra admin is your `...#EXT#@...onmicrosoft.com` name.
- `nslookup` returns only an alias ending in `.private.postgres.database.azure.com`, with no public IP address, and the connection test prints "Not reachable from the internet (expected)".

If the deployment fails only on the Entra admin step, re-run it with `PG_ENTRA_ADMIN=0 ./infra/03-database.sh`. Phase 4 doesn't depend on it: it signs in with the password admin, read from Key Vault.

### If PostgreSQL isn't available in your region

The error `SkuNotAvailable: Specified SKU is not supported in this region` means Azure won't allocate that size to *your subscription* in that region right now. This can happen even when `az postgres flexible-server list-skus` lists the size and your quota is fine.

After a failed attempt, Azure deletes the partly created server; the portal shows it as **Dropping**. The name stays reserved until that finishes, which can take several minutes. Trying again before then fails with `ServerNameAlreadyExists`, so the script waits for the name to be released before each new attempt.

1. **Try other zones.** The script already tries zones 1, 2 and 3 (the `PG_ZONES` setting). Capacity sometimes differs by zone.
2. **Request access (free).** In the portal, go to **Help + support → Create a support request → Service and subscription limits (quotas)**. Choose **Azure Database for PostgreSQL Flexible Server**, then ask for region access to Burstable in your region. Then re-run phase 3.
3. **Move to another region.** The server must be in the same region as the VNet, so phases 0–2 have to be rebuilt there. They're free and take a few minutes.

   First check that the new region will accept the server, using a throwaway one. It costs a few cents. If the create fails with `SkuNotAvailable`, delete the test group and try another region.

   ```bash
   az group create -n rg-pgtest -l centralus -o none
   az postgres flexible-server create -g rg-pgtest -n psql-pgtest-<suffix> -l centralus \
     --tier Burstable --sku-name Standard_B1ms --storage-size 32 --version 17 \
     --public-access None --yes -o none
   az group delete -n rg-pgtest --yes --no-wait
   ```

   Then rebuild:

   ```bash
   ./infra/99-teardown.sh                    # deletes rg-journal-dev
   az group wait --deleted --resource-group rg-journal-dev
   # Change the LOCATION="${LOCATION:-...}" default in infra/config.sh to the new region,
   # so every later run uses it.
   ./infra/00-budget.sh
   ./infra/01-foundation.sh
   ./infra/02-secrets.sh                     # recovers the soft-deleted vault with its secrets
   ./infra/03-database.sh
   ```

   Azure can keep deleting the old resources in the background for several minutes after `az group wait` returns. The old and new resources share the same IDs, so this cleanup can remove new ones; once it removed the new DNS zone link. After rebuilding, run "Verify phase 1" again, and re-run `./infra/01-foundation.sh` if anything is missing. It only creates what's missing.

   Run phase 2 within 7 days of the teardown. After that, Azure purges the soft-deleted vault and its secrets.

   The recovered Key Vault stays in its original region. That's fine: the app reaches it over Azure's network using its managed identity, not through the VNet.

## Phase 4: administration and database setup

```bash
./infra/04-admin.sh
```

This takes about 10 minutes. It creates:

- **Azure Bastion, Developer SKU.** It's free, has no public IP, and opens SSH sessions in the Azure portal, so you sign in with your Entra account first. It allows one session at a time.
- **A jumpbox VM in `snet-admin`** with no public IP and no SSH port open to the internet.
  - It accepts only an SSH key. The script puts the private key straight into Key Vault as `jumpbox-ssh-key` and deletes the local copy.
  - It can't use Entra sign-in, because Microsoft doesn't support that for guest accounts like yours.
- **Read access for the VM's managed identity** to the two database password secrets, and nothing else. This lets it sign in to PostgreSQL without anyone typing or copying a password.

It then sets up the database on the jumpbox through `az vm run-command`. That runs through Azure's control plane, so it needs your Entra sign-in and Azure RBAC, is recorded in the activity log, and needs no inbound port. On the jumpbox, [remote/jumpbox-setup.sh](remote/jumpbox-setup.sh):

1. Installs psql 17 and two helpers:
   - `kv-secret` reads a secret using the VM's identity.
   - `journal-psql` opens psql as the server admin, over TLS with certificate and hostname checks.
2. Applies [database_setup.sql](../database_setup.sql), the same schema the devcontainer uses.
3. Creates the `journal_app` role. It can connect and read, insert, update and delete rows in `entries`, and nothing else. Only a SCRAM hash of its password is sent to the server, so the password can't end up in server logs or query statistics.
4. Signs in as `journal_app` and prints what it can and can't do.

Finally, it stores `database-url` in Key Vault for the Container App in phase 6, and deallocates the jumpbox. A deallocated VM costs only its disk. Set `JUMPBOX_KEEP_RUNNING=1` to leave it running. Either way, it shuts itself down daily at 06:00 UTC.

### Verify phase 4

The script's output should end with a block like this:

```text
connected as:            journal_app
TLS:                     TLSv1.3
select/insert/update/delete on entries: true
can create tables:       false
can create roles or DBs: false
is a server admin:       false
```

Then:

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites
KV=$(az keyvault list -g rg-journal-dev --query "[0].name" -o tsv)
VM=vm-journal-dev-admin

# Private IP only, no NSG on the NIC (the snet-admin NSG applies), SSH key login only
az vm list-ip-addresses -g rg-journal-dev -n $VM \
  --query "[0].virtualMachine.network.{private:privateIpAddresses[0], public:publicIpAddresses}"
az network nic list -g rg-journal-dev --query "[].{nic:name, nsg:networkSecurityGroup.id}" -o table
az vm show -g rg-journal-dev -n $VM --query osProfile.linuxConfiguration.disablePasswordAuthentication

# Bastion is the free Developer SKU
az rest --method get \
  --url "https://management.azure.com$(az group show -n rg-journal-dev --query id -o tsv)/providers/Microsoft.Network/bastionHosts/bas-journal-dev?api-version=2024-05-01" \
  --query "{sku:sku.name, state:properties.provisioningState}"

# The only inbound rules open to the internet are the app tier's 80 and 443
az network nsg list -g rg-journal-dev \
  --query "[].{nsg:name, openToInternet:securityRules[?direction=='Inbound' && access=='Allow' && (sourceAddressPrefix=='Internet' || sourceAddressPrefix=='*')].destinationPortRanges[]}"

# The jumpbox's identity can read exactly two secrets
az role assignment list --all --assignee "$(az vm show -g rg-journal-dev -n $VM --query identity.principalId -o tsv)" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table

# Secret names, and database-url with its password masked
az keyvault secret list --vault-name "$KV" --query "[].name" -o tsv
az keyvault secret show --vault-name "$KV" -n database-url --query value -o tsv | sed -E 's#://([^:]+):[^@]+@#://\1:****@#'

# Deallocated
az vm get-instance-view -g rg-journal-dev -n $VM --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]"
```

**Expected results:**
- `public` is empty (`[]`), and the private IP is in `10.20.2.0/29`. The jumpbox NIC's `nsg` is empty. `disablePasswordAuthentication` is `true`.
- Bastion shows `sku` `Developer` and `state` `Succeeded`.
- Only `nsg-journal-dev-app` lists ports (`80`, `443`). The `db` and `admin` NSGs list none.
- The jumpbox has two `Key Vault Secrets User` rows, with scopes ending in `/secrets/pg-admin-password` and `/secrets/pg-app-password`.
- The secrets now include `database-url` and `jumpbox-ssh-key`.
- The masked URL is `postgresql://journal_app:****@psql-journal-dev-d5775.postgres.database.azure.com:5432/career_journal?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt`.
- The VM shows `VM deallocated`.

### Connect through Bastion

Use this for interactive database work, and to try the admin path for requirement 3 yourself:

1. Start the jumpbox: `az vm start -g rg-journal-dev -n vm-journal-dev-admin`.
2. In the portal, open **vm-journal-dev-admin → Connect → Connect via Bastion**.
3. For **Authentication Type**, choose **SSH Private Key from Azure Key Vault**. Enter username `journalops`, select vault `kv-journal-dev-d5775` and secret `jumpbox-ssh-key`, then select **Connect**.
4. In the session, run `journal-psql -c '\dt'` and `journal-psql -c '\du journal_app'`, or plain `journal-psql` for an interactive prompt.
5. Close the tab, then deallocate the VM: `az vm deallocate -g rg-journal-dev -n vm-journal-dev-admin`.

If the connection times out, look at the NIC's **Effective security rules**. Bastion Developer reaches the VM over Azure's platform network, which the `snet-admin` NSG's `Allow-AzureLoadBalancer` rule permits.

## Phase 5: container registry and image

Needs Docker running locally (Docker Desktop on Windows).

```bash
BUILD_ONLY=1 ./infra/05-registry.sh   # optional: build and smoke-test locally; changes nothing in Azure
./infra/05-registry.sh
```

The script creates:

- **A container registry**, `acrjournaldevd5775`. It's the Basic tier, about $5/month. Its admin user is off, so the registry has no password.
  - You push with your Entra sign-in: `az acr login` exchanges it for a short-lived token.
  - The app's managed identity gets `AcrPull` on this registry only. Phase 6 uses it to pull the image.

It then builds the image from the repo's [Dockerfile](../Dockerfile) for `linux/amd64` and smoke-tests it locally before pushing. The test runs the image against a throwaway PostgreSQL 17 container. It checks that the API starts as the non-root `app` user, creates an entry, lists it back, and that there's no `.env` in the image. The test containers are removed afterwards. Set `SKIP_SMOKE_TEST=1` to skip it.

Images are tagged with the git commit they were built from:

- **Clean build:** the tag is the commit, for example `eb01feecaa6a`. Re-running with the same commit skips the build.
- **Uncommitted changes:** if anything that goes into the image has uncommitted changes, the tag becomes `<commit>-dirty-<UTC time>`. That covers `api/`, `pyproject.toml`, `uv.lock`, `Dockerfile` and `.dockerignore`. Commit first if you want a tag that maps to an exact commit.

If a starter stub is still active in `api/` (an uncommented `501 Not implemented` or `NotImplementedError`), the script notes which files have one. Those endpoints would fail in Azure too. The leftover `TODO` instruction comments don't count; they stay in place after an exercise is done.

### Verify phase 5

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites
ACR=$(az acr list -g rg-journal-dev --query "[0].name" -o tsv)

# Basic, admin user off, anonymous pull off
az acr show -n "$ACR" --query "{sku:sku.name, adminUser:adminUserEnabled, anonymousPull:anonymousPullEnabled, loginServer:loginServer}"

# Pushed tags, newest first
az acr repository show-tags -n "$ACR" --repository journal-api --orderby time_desc --detail \
  --query "[].{tag:name, created:createdTime}" -o table

# One role assignment on the registry: AcrPull for the app identity
az role assignment list --scope "$(az acr show -n "$ACR" --query id -o tsv)" \
  --query "[].{who:principalName, type:principalType, role:roleDefinitionName}" -o table

# Without a sign-in, the registry refuses to even list tags
curl -sI "https://$ACR.azurecr.io/v2/journal-api/tags/list" | head -n 1

# The image records its commit and runs as a non-root user
TAG=$(az acr repository show-tags -n "$ACR" --repository journal-api --orderby time_desc --top 1 -o tsv)
docker image inspect "$ACR.azurecr.io/journal-api:$TAG" \
  --format 'user={{.Config.User}} revision={{index .Config.Labels "org.opencontainers.image.revision"}}'
```

**Expected results:**
- `sku` is `Basic`, and `adminUser` and `anonymousPull` are both `false`.
- The newest tag is the one the script printed.
- There's one `ServicePrincipal` row with `AcrPull`. Its "who" GUID matches `az identity show -g rg-journal-dev -n id-journal-dev-app --query clientId -o tsv`.
- `curl` prints `HTTP/1.1 401 Unauthorized`.
- The image shows `user=app`, and its revision matches `git rev-parse --short=12 HEAD`.

## Phase 6: the app tier

```bash
WHAT_IF=1 ./infra/06-app.sh   # optional: preview; changes nothing
./infra/06-app.sh
```

This takes 5–10 minutes the first time, mostly creating the environment. It creates:

- **A Container Apps environment**, `cae-journal-dev`, in `snet-app`. It uses workload profiles with the Consumption profile only, so you pay per use with no plan fee. App and system logs go to `log-journal-dev`.
- **The API app**, `ca-journal-api`:
  - It runs the newest image in the registry. Set `IMAGE_TAG=<tag>` to choose a different one.
  - It has one always-on replica of 0.25 vCPU / 0.5 GiB, and scales up to 3 under load.
  - `DATABASE_URL` and `OPENAI_API_KEY` are Key Vault references. Container Apps reads them with the app's managed identity and re-reads them every 30 minutes, so rotating a secret needs no redeploy.
  - `OPENAI_BASE_URL` and `OPENAI_MODEL` are plain settings from [config.sh](config.sh).

It also narrows the app identity's vault access to exactly `database-url` and `openai-api-key`. Earlier versions of phase 2 gave it read access to the whole vault, which includes the admin password and SSH key. The script removes that once the app is running.

Finally, it checks the app from the internet: `/docs` over HTTPS, the certificate, the HTTP redirect, and `GET /entries`.

To deploy a new image later, run phase 5, then this script again. Each new image becomes a new revision, and the old one is replaced once the new one passes its startup probe.

### Verify phase 6: all five requirements

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites
APP=ca-journal-api
URL="https://$(az containerapp show -g rg-journal-dev -n $APP --query properties.configuration.ingress.fqdn -o tsv)"
echo "$URL"
```

**1. Public HTTPS with a trusted certificate**

```bash
curl -sI "$URL/docs" | head -n 1                                    # HTTP/1.1 200 OK (curl checks the certificate)
curl -sI "${URL/https:/http:}/docs" | grep -i -E "^HTTP|^location"  # a redirect to https://
openssl s_client -connect "${URL#https://}:443" -servername "${URL#https://}" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

**2. PostgreSQL accepts the app tier, not the internet**

```bash
curl -s "$URL/entries" | head -c 300; echo                          # 200 with JSON: the app reaches the database
az containerapp show -g rg-journal-dev -n $APP --query "properties.outboundIpAddresses" -o tsv
PGHOST=$(az postgres flexible-server list -g rg-journal-dev --query "[0].fullyQualifiedDomainName" -o tsv)
timeout 5 bash -c "</dev/tcp/$PGHOST/5432" 2>/dev/null && echo "REACHABLE (bad)" || echo "Not reachable from the internet (expected)"
```

**3. Credentials stay out of source control, config and logs**

```bash
# The app's secrets are Key Vault references; no value in its configuration
az containerapp show -g rg-journal-dev -n $APP \
  --query "{secrets:properties.configuration.secrets[].{name:name, keyVaultUrl:keyVaultUrl}, registries:properties.configuration.registries[].{server:server, identity:identity}}"
az containerapp show -g rg-journal-dev -n $APP --query "properties.template.containers[0].env" -o table

# The app identity: AcrPull on the registry, and read access to exactly two secrets
az role assignment list --all --assignee "$(az identity show -g rg-journal-dev -n id-journal-dev-app --query principalId -o tsv)" \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table

# Nothing secret in the repo: the gitleaks hook, run over every tracked file
uvx pre-commit run gitleaks --all-files      # in the devcontainer: uv run pre-commit run gitleaks --all-files
```

**4. Keeps running after you sign out; data survives restarts**

```bash
az containerapp show -g rg-journal-dev -n $APP --query "properties.template.scale.{min:minReplicas, max:maxReplicas}"

# Write an entry, restart the app, read it back
curl -s -X POST "$URL/entries" -H 'Content-Type: application/json' \
  -d '{"work": "Deployed to Azure", "struggle": "Regional capacity", "intention": "Verify persistence"}'; echo
az containerapp revision restart -g rg-journal-dev -n $APP \
  --revision "$(az containerapp show -g rg-journal-dev -n $APP --query properties.latestRevisionName -o tsv)"
sleep 60
curl -s "$URL/entries" | grep -o '"Deployed to Azure"' && echo "entry survived the restart"
```

Close your terminal, sign out of Azure (`az logout`), and open `$URL/docs` in a browser from your phone. It still answers.

**5. CRUD and live AI analysis**

Open `$URL/docs` and work through each endpoint with **Try it out**: create, list, get by ID, update, delete, and `POST /entries/{entry_id}/analyze`. Each should behave as it does locally. The analyze call reaches your AI provider for real, so it uses a small amount of your API credit.

To ship code changes, run `./infra/05-registry.sh` followed by `./infra/06-app.sh`.

To see the app's logs:

```bash
az containerapp logs show -g rg-journal-dev -n $APP --tail 50 --format text
```

**Expected results:**
1. `/docs` returns `200 OK` over HTTPS. Plain HTTP returns a redirect (`301`) with a `location: https://...` header. The certificate's subject is `*.<environment>.centralus.azurecontainerapps.io`, issued by a Microsoft public CA, and it hasn't expired.
2. `/entries` returns JSON. The database connection test from your machine prints "Not reachable from the internet (expected)".
3. Each secret has a `keyVaultUrl` and no value. `DATABASE_URL` and `OPENAI_API_KEY` show a `secretRef`, not a value. The identity has three rows: `AcrPull` on the registry, and `Key Vault Secrets User` on `.../secrets/database-url` and on `.../secrets/openai-api-key`. Nothing at the vault level. gitleaks prints `Passed`.
4. `min` is `1`. The entry is still there after the restart.
5. Every endpoint matches its local behaviour, and analyze returns a real analysis.

## Credentials

- Nothing in `infra/` contains a secret. Passwords and keys are generated into Key Vault (phases 2 and 4) and are never passed as command-line arguments, which would end up in shell history.
- The container registry has no admin user or password. You push with your Entra sign-in, and the app pulls with its managed identity.
- The jumpbox's SSH private key exists only in Key Vault. The jumpbox reads database passwords with its own managed identity, so nobody types or copies them.
- `.env` is git-ignored and excluded from the Docker image by `.dockerignore`.
- The gitleaks hook in [.pre-commit-config.yaml](../.pre-commit-config.yaml) blocks commits that contain credentials. To install it, run `uv run pre-commit install` in the devcontainer, or `uvx pre-commit install` on Windows.
- [.gitleaksignore](../.gitleaksignore) lists the two reviewed upstream findings in old commits.

## Tear down

```bash
./infra/99-teardown.sh
```

This deletes the resource group and everything in it, **including all journal data**. You must type the group name to confirm. Spending stops once the deletion finishes.

### Before tearing down

1. **Commit everything**, so the repo matches what's deployed.
2. **Export your journal entries if you want to keep them.** Deleted servers can only be restored for a few days, so after a month the data is gone. Save the export outside the repo; it's your personal writing, not code:
   ```bash
   URL="https://$(az containerapp show -g rg-journal-dev -n ca-journal-api --query properties.configuration.ingress.fqdn -o tsv)"
   curl -s "$URL/entries" > ~/journal-entries-backup.json
   ```
3. **Have your AI provider key available for later**: the OpenAI key in your OpenAI dashboard, which stays valid unless you revoke it. Key Vault keeps deleted secrets for only 7 days. After that, phase 2 creates a fresh vault and asks for the key again.

### Redeploy later

Everything is rebuilt from the repo with the same scripts, in order. Plan about an hour, mostly waiting.

```bash
./infra/00-budget.sh
./infra/01-foundation.sh   # then "Verify phase 1"; re-run if the DNS link is missing
./infra/02-secrets.sh      # paste the AI provider key at the prompt
./infra/03-database.sh
./infra/04-admin.sh
./infra/05-registry.sh     # needs Docker running
./infra/06-app.sh
```

Run each phase's Verify section before moving on.

- **Within 7 days of the teardown**, phase 2 recovers the old vault, with its passwords and AI key.
- **After that**, it creates a new vault and generates new passwords. Nothing else depends on the old ones.

What's different after a redeploy:

- **The app's URL changes.** The new environment gets a new random part in `*.azurecontainerapps.io`.
- **The database starts empty.** To bring back exported entries:
  ```bash
  URL="https://$(az containerapp show -g rg-journal-dev -n ca-journal-api --query properties.configuration.ingress.fqdn -o tsv)"
  python -c "import json,sys; [print(json.dumps({k: e[k] for k in ('work','struggle','intention')})) for e in json.load(sys.stdin)['entries']]" \
    < ~/journal-entries-backup.json \
    | while read -r body; do curl -s -X POST "$URL/entries" -H 'Content-Type: application/json' -d "$body" >/dev/null; done
  ```
  Re-created entries get new IDs and today's timestamps; the API sets those itself.
- **Capacity can change.** If phase 3 or 4 hits `SkuNotAvailable` or a quota error again, see "If PostgreSQL isn't available in your region" and the phase 4 notes. You may need to change `LOCATION` or `JUMPBOX_SIZE` in [config.sh](config.sh).
- **Run 01 right after the teardown finishes?** Background cleanup of the old resources can remove new ones with the same IDs. Wait a few minutes after `az group wait --deleted`, or re-run phase 1 if its Verify fails. After a month, this doesn't apply.

Some things outside the resource group stay and cost nothing: the resource provider registrations, your subscription-wide `Labbing-budget`, and the `NetworkWatcherRG` group Azure creates for VNets. The `ME_cae-journal-dev_...` group belongs to the Container Apps environment, and Azure deletes it along with the environment.
