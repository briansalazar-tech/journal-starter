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
                    jumpbox VM, no public IP (snet-admin 10.20.2.0/29) ◄── Azure Bastion ◄── you (Entra ID)
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
| 2 | [02-secrets.sh](02-secrets.sh) | Key Vault (RBAC, with audit logs), the app's managed identity, generated database passwords, Foundry key | About $0.10/month |
| 3 | [03-database.sh](03-database.sh), [templates/postgres.bicep](templates/postgres.bicep) | PostgreSQL 17 Flexible Server (B1ms, private access only), `career_journal` database, you as Entra admin | About $16/month |
| 4 | *next* | Jumpbox VM and Bastion; schema and least-privilege app role | About $0 to $2.50/month |
| 5 | *planned* | Container Registry; image build | About $5/month |
| 6 | *planned* | Container Apps environment and app | About $4 to $14/month |
| 99 | [99-teardown.sh](99-teardown.sh) | Deletes the resource group and everything in it | — |

Costs are pay-as-you-go prices for East US 2, taken from the Azure Retail Prices API in November 2026.

## Phase 0: before provisioning

```bash
./infra/00-budget.sh
```

This budget covers only this project's resource group. Your existing subscription-wide `Labbing-budget` ($50/month, alerts at 75%, 85% and 90%) still covers everything else, including the Foundry resource. Once this project runs 24/7 (about $26–37/month), it will be close to `Labbing-budget`'s 75% threshold on its own.

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

# Database-tier rules: 5432 from app and admin subnets only, everything else in the VNet denied
az network nsg rule list -g rg-journal-dev --nsg-name nsg-journal-dev-db \
  --query "sort_by([], &priority)[].{priority:priority, name:name, access:access, from:sourceAddressPrefix, port:destinationPortRange}" -o table
```

**Expected results:**
- `snet-app` is delegated to `Microsoft.App/environments`, and `snet-db` to `Microsoft.DBforPostgreSQL/flexibleServers`.
- The database NSG allows 5432 only from `10.20.0.0/24` and `10.20.2.0/29`, and denies the rest of the VNet at priority 4000.
- None of the NSGs allow inbound internet traffic except the app tier, on ports 80 and 443.

## Phase 2: identity and secrets

```bash
./infra/02-secrets.sh
```

The script asks for your Foundry API key at a hidden prompt. The Foundry portal shows it under your resource's **Keys and Endpoint** page. Press Enter to skip; re-run the script to add the key later, or use `ROTATE_OPENAI_KEY=1 ./infra/02-secrets.sh` to replace it.

### Verify phase 2

```bash
export MSYS_NO_PATHCONV=1   # Git Bash only; see Prerequisites

KV=$(az keyvault list -g rg-journal-dev --query "[0].name" -o tsv)

# RBAC on, 7-day soft delete
az keyvault show -n "$KV" \
  --query "{rbac:properties.enableRbacAuthorization, softDeleteDays:properties.softDeleteRetentionInDays}"

# Exactly two role assignments on the vault: you (Officer) and the app identity (User)
az role assignment list --scope "$(az keyvault show -n "$KV" --query id -o tsv)" \
  --query "[].{who:principalName, principalType:principalType, role:roleDefinitionName}" -o table

# The ServicePrincipal row's "who" is the app identity's client ID; this prints the same GUID
az identity show -g rg-journal-dev -n id-journal-dev-app --query clientId -o tsv

# Secret names (no values)
az keyvault secret list --vault-name "$KV" --query "[].name" -o tsv

# Each password is 32 characters. This prints only the length, never the value.
az keyvault secret show --vault-name "$KV" -n pg-admin-password --query "length(value)"
```

**Expected results:**
- `rbac` is `true` and `softDeleteDays` is `7`.
- There are two role assignments:
  - a `User` row: you, shown as your guest name (`...#EXT#@...onmicrosoft.com`), with `Key Vault Secrets Officer`
  - a `ServicePrincipal` row: a GUID that matches the `clientId` command's output, with `Key Vault Secrets User`
- You see three secret names (two if you skipped the Foundry key).
- Each password length prints as `32`.
- Your shell history doesn't contain any of the secret values.

## Phase 3: database tier

```bash
./infra/03-database.sh
```

**Billing starts in this phase: about $16/month until you tear it down.** The deployment takes 5–15 minutes. To watch it, open the portal and go to **rg-journal-dev → Deployments**.

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

If the deployment fails only on the Entra admin step, re-run it with `PG_ENTRA_ADMIN=0 ./infra/03-database.sh`. Phase 4 will then sign in with the password admin instead.

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
   # Change LOCATION="${LOCATION:-eastus2}" in infra/config.sh to the new region,
   # so every later run uses it.
   ./infra/00-budget.sh
   ./infra/01-foundation.sh
   ./infra/02-secrets.sh                     # recovers the soft-deleted vault with its secrets
   ./infra/03-database.sh
   ```

   Run phase 2 within 7 days of the teardown. After that, Azure purges the soft-deleted vault and its secrets.

   The recovered Key Vault stays in its original region. That's fine: the app reaches it over Azure's network using its managed identity, not through the VNet.

## Credentials

- Nothing in `infra/` contains a secret. Passwords and keys are generated into Key Vault (phase 2) and are never passed as command-line arguments, which would end up in shell history.
- `.env` is git-ignored and excluded from the Docker image by `.dockerignore`.
- The gitleaks hook in [.pre-commit-config.yaml](../.pre-commit-config.yaml) blocks commits that contain credentials. To install it, run `uv run pre-commit install` in the devcontainer, or `uvx pre-commit install` on Windows.
- [.gitleaksignore](../.gitleaksignore) lists the two reviewed upstream findings in old commits.

## Tear down

```bash
./infra/99-teardown.sh
```

This deletes the resource group and everything in it, **including all journal data**. You must type the group name to confirm.
