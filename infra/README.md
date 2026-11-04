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
| 3 | *next* | PostgreSQL Flexible Server (B1ms, private access) | About $16/month |
| 4 | *planned* | Jumpbox VM and Bastion; schema and least-privilege app role | About $0 to $2.50/month |
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
