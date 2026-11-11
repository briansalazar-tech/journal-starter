# Building the deployment in the Azure portal

This guide rebuilds what the `infra/` scripts create, by hand in the Azure portal. Each phase matches one script. It lists the portal screens and the values to enter, then explains the concept behind them.

It uses the same names as the scripts, so the Verify commands in [README.md](README.md) and `./infra/99-teardown.sh` still work on what you build here.

Portal labels change from time to time. If a field has moved or been renamed, look for the setting by what it does; the values stay the same.

## Before you start

- **Cost:** the full deployment costs about **$1.70–2.00 a day**, mostly from phase 3 onwards. Plan to finish in one or two sittings, then tear down (see the end of this guide). Stop the jumpbox whenever you're not using it.
- **Region:** use **Central US** for everything. East US 2 refused the database size for this subscription.
- **VM size:** use **B1s**. The subscription has no vCPU quota for the newer B-series v2 sizes.
- **Your account is an Entra guest** (`...#EXT#@...`), so Entra sign-in to VMs isn't available. The jumpbox uses an SSH key.
- **Have your OpenAI API key ready.** You'll paste it into Key Vault in phase 2.
- **Keep secrets out of files.** Copy passwords from Key Vault when you need them, and don't save them in the repo, a text file or a chat message.

| Phase | Script | Portal areas |
|---|---|---|
| 0 | `00-budget.sh` | Resource groups, Cost Management budgets |
| 1 | `01-foundation.sh` | Resource providers, Log Analytics, network security groups, virtual network, private DNS zones |
| 2 | `02-secrets.sh` | Key vaults, managed identities |
| 3 | `03-database.sh` | Azure Database for PostgreSQL flexible servers |
| 4 | `04-admin.sh` | Virtual machines, Bastion, a psql session on the jumpbox |
| 5 | `05-registry.sh` | Container registries (the image build still uses Docker) |
| 6 | `06-app.sh` | Container Apps |

---

## Phase 0: resource group and budget

**Create the resource group.** Go to **Resource groups → Create**.

| Field | Value |
|---|---|
| Resource group | `rg-journal-dev` |
| Region | Central US |
| Tags | `project` = `journal`, `env` = `dev`, `managedBy` = `portal` |

**Create the budget.** Open `rg-journal-dev`, then **Cost Management → Budgets → Add**. The budget's scope should show the resource group.

| Field | Value |
|---|---|
| Name | `budget-journal-dev` |
| Reset period | Monthly |
| Expiration date | two years from now |
| Amount | `40` |

Next, add the alert conditions:

| Type | % of budget |
|---|---|
| Actual | 50 |
| Actual | 80 |
| Actual | 100 |
| Forecasted | 100 |

Send them to your email address.

**Concept:** a budget only sends alerts; it never stops or deletes anything. The forecast alert is the useful one, because it warns you partway through the month that you're on track to go over.

---

## Phase 1: network foundation

### Resource providers

Go to **Subscriptions → Labbing → Settings → Resource providers**. Register any of these that aren't already `Registered`:

`Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.Network`, `Microsoft.DBforPostgreSQL`, `Microsoft.ContainerRegistry`, `Microsoft.KeyVault`, `Microsoft.ManagedIdentity`, `Microsoft.Compute`, `Microsoft.DevTestLab`

`Microsoft.DevTestLab` is for the jumpbox's auto-shutdown schedule.

**Concept:** a subscription can only create a type of resource once its provider is registered. Registering is a one-time step and free.

### Log Analytics workspace

Go to **Log Analytics workspaces → Create**. Use name `log-journal-dev`, region Central US.

After it's created, open the workspace and go to **Settings → Usage and estimated costs**:

- **Daily cap:** On, `0.15` GB/day.
- **Data retention:** 30 days (the default).

**Concept:** the first 5 GB a month is free. 0.15 GB a day keeps you under that, so a noisy app can't run up a log bill.

### Network security groups

Go to **Network security groups → Create**. Create three, all in Central US: `nsg-journal-dev-app`, `nsg-journal-dev-db` and `nsg-journal-dev-admin`.

Then open each one and go to **Settings → Inbound security rules → Add**.

**`nsg-journal-dev-app`**

| Priority | Name | Source | Destination | Service / ports | Protocol | Action |
|---|---|---|---|---|---|---|
| 100 | Allow-Web-From-Internet | Service tag `Internet` | IP addresses `10.20.0.0/24` | `80,443` | TCP | Allow |

**`nsg-journal-dev-db`**

| Priority | Name | Source | Destination | Ports | Protocol | Action |
|---|---|---|---|---|---|---|
| 100 | Allow-Postgres-From-App | `10.20.0.0/24` | `10.20.1.0/28` | `5432` | TCP | Allow |
| 110 | Allow-Postgres-From-Admin | `10.20.2.0/29` | `10.20.1.0/28` | `5432` | TCP | Allow |
| 120 | Allow-Within-Db-Subnet | `10.20.1.0/28` | `10.20.1.0/28` | `*` | Any | Allow |
| 130 | Allow-AzureLoadBalancer | Service tag `AzureLoadBalancer` | Any | `*` | Any | Allow |
| 4000 | Deny-Other-VNet-Inbound | Service tag `VirtualNetwork` | Any | `*` | Any | Deny |

**`nsg-journal-dev-admin`**

| Priority | Name | Source | Destination | Ports | Protocol | Action |
|---|---|---|---|---|---|---|
| 130 | Allow-AzureLoadBalancer | Service tag `AzureLoadBalancer` | Any | `*` | Any | Allow |
| 4000 | Deny-Other-VNet-Inbound | Service tag `VirtualNetwork` | Any | `*` | Any | Deny |

**Concept:** rules are checked from the lowest priority number up, and the first match wins. Every NSG also has built-in default rules at 65000 and above, and one of them allows all traffic from inside the VNet. The `Deny-Other-VNet-Inbound` rule at 4000 overrides it. So the database accepts port 5432 only from the app and admin subnets, not from anything else in the VNet. Nothing in these rules lets the internet reach the database or the jumpbox.

### Virtual network

Go to **Virtual networks → Create**.

- **Basics:** name `vnet-journal-dev`, region Central US.
- **IP addresses:** address space `10.20.0.0/16`. Delete the default subnet, then add these three:

| Subnet | Range | Delegate to | Network security group |
|---|---|---|---|
| `snet-app` | `10.20.0.0/24` | `Microsoft.App/environments` | `nsg-journal-dev-app` |
| `snet-db` | `10.20.1.0/28` | `Microsoft.DBforPostgreSQL/flexibleServers` | `nsg-journal-dev-db` |
| `snet-admin` | `10.20.2.0/29` | none | `nsg-journal-dev-admin` |

On each subnet, **uncheck Enable private subnet (no default outbound access)**. The portal checks it by default for new virtual networks. Left checked, nothing in the subnet can reach the internet: the jumpbox can't install psql, and the app can't pull its image or reach OpenAI. The scripts turn it off with `--default-outbound-access true`.

**Concept:** delegating a subnet hands it to one service, which then manages the network setup inside it. Container Apps and PostgreSQL private access both require a delegated subnet of their own.

"Default outbound access" is Azure's built-in route to the internet for VMs without a public IP. Microsoft is retiring it, which is why new subnets now start private. The production replacement is a NAT gateway, at about $32 a month plus its IP. For a lab, default outbound access is free and fine.

### Private DNS zone

Go to **Private DNS zones → Create**. Choose resource group `rg-journal-dev` and enter the name `journal-dev.private.postgres.database.azure.com`.

Then open the zone and go to **DNS Management → Virtual network links → Add**:

| Field | Value |
|---|---|
| Link name | `link-vnet-journal-dev` |
| Virtual network | `vnet-journal-dev` |
| Enable auto registration | off |

**Concept:** PostgreSQL will add its private IP to this zone. The link is what lets resources in the VNet look up names in the zone. Without it, nothing in the VNet can find the database, which is what broke phase 4 the first time around.

For private access, the zone name has to end in `.private.postgres.database.azure.com`. The `privatelink.` zones are for private endpoints, which work differently.

**Check:** run "Verify phase 1" from [README.md](README.md). Confirm that the link's status shows **Completed**.

---

## Phase 2: Key Vault, identity and secrets

### If the old vault is still soft-deleted

The vault from the last teardown, `kv-journal-dev-d5775`, stays soft-deleted until 13 November 2026, and while it does, its name is taken. Go to **Key vaults → Manage deleted vaults**, pick subscription Labbing, and choose one:

- **Purge**, then create a new vault as described below. Purging deletes the old secrets for good, including your OpenAI key. This is the better practice option.
- **Recover**, which brings the vault back in East US 2 with all its secrets. If you choose this, skip to "Access for you" and check what's already there.

### Create the vault

Go to **Key vaults → Create**.

| Tab | Field | Value |
|---|---|---|
| Basics | Name | `kv-journal-dev-d5775` |
| | Region | Central US |
| | Pricing tier | Standard |
| | Days to retain deleted vaults | 7 |
| | Purge protection | Disable |
| Access configuration | Permission model | Azure role-based access control |
| Networking | Public access | All networks |

### Access for you

Open the vault, go to **Access control (IAM) → Add → Add role assignment**, and assign **Key Vault Secrets Officer** to your own account.

**Concept:** being subscription Owner lets you manage the vault (its "control plane"), but not read or write its secrets (its "data plane"). That's a separate role you have to grant explicitly. Until you do, the portal says you're not authorized to view secrets.

### Audit logs

In the vault, go to **Monitoring → Diagnostic settings → Add diagnostic setting**:

| Field | Value |
|---|---|
| Name | `kv-audit` |
| Category groups | `audit` |
| Destination | Send to Log Analytics workspace → `log-journal-dev` |

**Concept:** every secret read and write is now logged with who did it and when. In phase 6, you'll be able to see the app's managed identity reading its secrets.

### Managed identity for the app

Go to **Managed Identities → Create**. Use name `id-journal-dev-app`, region Central US.

Don't give it any roles yet. Phases 5 and 6 grant exactly what it needs.

### Secrets

In the vault, go to **Objects → Secrets → Generate/Import** and create each of these:

| Name | Value |
|---|---|
| `pg-admin-password` | 32 random letters and digits |
| `pg-app-password` | a different 32 random letters and digits |
| `openai-api-key` | your OpenAI API key |

Use your password manager's generator for the two passwords, with letters and digits only. Symbols would need URL-encoding inside the database URL in phase 4. Azure PostgreSQL also requires an uppercase letter, a lowercase letter and a digit.

**Check:** run "Verify phase 2" from [README.md](README.md). The vault should show one role assignment (you), plus the three secrets.

---

## Phase 3: PostgreSQL (database tier)

Billing for real compute starts here, at about $0.60 a day.

Go to **Azure Database for PostgreSQL flexible servers → Create**.

**Basics**

| Field | Value |
|---|---|
| Server name | `psql-journal-dev-d5775` |
| Region | Central US |
| PostgreSQL version | 17 |
| Workload type | Development |
| Compute + storage → Configure server | Burstable, **Standard_B1ms**, storage 32 GiB, storage autogrow off |
| High availability | Disabled |
| Backup retention | 7 days, geo-redundancy off |
| Availability zone | No preference |

**Authentication**

| Field | Value |
|---|---|
| Authentication method | PostgreSQL and Microsoft Entra authentication |
| Microsoft Entra administrator | yourself (your `...#EXT#@...onmicrosoft.com` guest account) |
| Administrator login | `journaladmin` |
| Password | copy `pg-admin-password` from Key Vault |

To copy a secret, go to the vault, then **Secrets → pg-admin-password → current version**, and use the copy button next to **Secret value**.

**Networking**

| Field | Value |
|---|---|
| Connectivity method | **Private access (VNet Integration)** |
| Virtual network / subnet | `vnet-journal-dev` / `snet-db` |
| Private DNS zone | `journal-dev.private.postgres.database.azure.com` (choose the existing one) |

Select **Review + create**. Creating the server takes 5–15 minutes. If it fails with `SkuNotAvailable`, see "If PostgreSQL isn't available in your region" in [README.md](README.md).

**Create the app's database.** Open the server, go to **Settings → Databases → Add**, and enter `career_journal`.

**Concept:** you choose private access when you create the server, and you can't change it later. The server gets an IP in `snet-db` and nothing else. Its public name, `psql-journal-dev-d5775.postgres.database.azure.com`, is only an alias that points at a record in your private zone. From the internet the name leads nowhere, and from inside the VNet it resolves to `10.20.1.x`.

**Check:** run "Verify phase 3" from [README.md](README.md). Also open the private DNS zone: it should now have an A record pointing at `10.20.1.x`.

---

## Phase 4: jumpbox, Bastion and database setup

### Create the jumpbox

Go to **Virtual machines → Create → Azure virtual machine**.

**Basics**

| Field | Value |
|---|---|
| Virtual machine name | `vm-journal-dev-admin` |
| Region | Central US |
| Availability options | No infrastructure redundancy required |
| Security type | Trusted launch |
| Image | Ubuntu Server 24.04 LTS (x64, Gen2) |
| Size | **Standard_B1s** |
| Authentication type | SSH public key |
| Username | `journalops` |
| SSH public key source | Generate new key pair (RSA) |
| Public inbound ports | **None** |

**Disks:** OS disk type **Standard HDD (LRS)**, with **Delete with VM** checked.

**Networking**

| Field | Value |
|---|---|
| Virtual network / subnet | `vnet-journal-dev` / `snet-admin` |
| Public IP | **None** |
| NIC network security group | **None** (the subnet's NSG applies) |
| Delete NIC when VM is deleted | checked |

**Management:** turn on **auto-shutdown** at 12:00 AM, Central Time.

Select **Review + create → Create**. When the portal offers it, select **Download private key and create resource**. Move the `.pem` file to `%USERPROFILE%\.ssh\`, outside the repo.

**Concept:** with no public IP and no open port, the jumpbox can't be reached from the internet at all. The only way in is through Bastion, and you have to sign in to the Azure portal to use Bastion.

The scripts keep the private key in Key Vault as `jumpbox-ssh-key`. The portal's secret field can't hold a multi-line key, so this guide keeps it as a local file instead. Both are outside source control.

### Connect through Bastion

Open the VM, go to **Connect → Connect via Bastion**, and choose the free **Developer** option. It deploys in seconds. Then fill in:

| Field | Value |
|---|---|
| Authentication type | SSH Private Key from Local File |
| Username | `journalops` |
| Local file | the `.pem` you downloaded |

A terminal opens in your browser tab.

**Concept:** Bastion Developer runs in a shared Microsoft pool. It needs no subnet, no public IP and has no hourly charge, but it allows only one session at a time. Paid Bastion SKUs need an `AzureBastionSubnet` and a public IP. The scripts reserved `10.20.3.0/26` for that, in case you ever need it.

### Install psql 17

In the Bastion session:

```bash
sudo apt-get update
sudo apt-get install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
sudo apt-get install -y postgresql-client-17
psql --version        # psql (PostgreSQL) 17.x
```

Ubuntu 24.04 ships psql 16. The PostgreSQL project's own apt repository provides 17, to match the server.

If `apt-get` says `Could not connect to azure.archive.ubuntu.com:80 ... connection timed out`, `snet-admin` is a private subnet with no route to the internet. To fix it:

1. Stop (deallocate) the VM.
2. Go to **vnet-journal-dev → Subnets → snet-admin**, uncheck **Enable private subnet**, and select **Save**. Do the same for `snet-app` while you're there.
3. Start the VM and reconnect.

Existing VMs only pick up the change after a deallocate and start. To test before installing, run `curl -sI http://azure.archive.ubuntu.com/ubuntu/ | head -n 1`, which should print `HTTP/1.1 200 OK`.

### Apply the schema as the server admin

```bash
export PGHOST=psql-journal-dev-d5775.postgres.database.azure.com
export PGDATABASE=career_journal
export PGSSLMODE=verify-full
export PGSSLROOTCERT=/etc/ssl/certs/ca-certificates.crt
psql -U journaladmin
```

At the `Password` prompt, paste `pg-admin-password` from Key Vault. The prompt hides what you type.

`verify-full` means psql checks both the server's certificate and its hostname, so it can't be tricked into talking to an impostor.

At the `career_journal=>` prompt, paste the three `CREATE` statements from [database_setup.sql](../database_setup.sql): the `entries` table and its two indexes.

### Create the least-privilege app role

Still in psql, run these one step at a time. Don't paste them as one block: `\password` reads its two prompts from whatever comes next, so pasted lines after it would be taken as the password.

```sql
CREATE ROLE journal_app LOGIN;
```

```sql
\password journal_app
```

At the two `\password` prompts, paste `pg-app-password`. Then:

```sql
GRANT CONNECT ON DATABASE career_journal TO journal_app;
GRANT USAGE ON SCHEMA public TO journal_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE entries TO journal_app;
```

Before you leave psql, check what you created:

```sql
\du journal_app
\dp entries
```

`\du` should list `journal_app` with an empty Attributes column: it can log in, but it isn't a superuser and can't create roles or databases. `\dp` should show `journal_app=arwd/journaladmin` in the access privileges column. Those letters stand for insert (a), select (r), update (w) and delete (d).

Then leave psql with `\q`. Your prompt should change back from `career_journal=>` to the shell's `journalops@vm-journal-dev-admin:~$`.

**Concept:** `\password` hashes the password on your side, using SCRAM-SHA-256, and sends only the hash to the server. The plain password never appears in a SQL statement, server log or query statistics. The scripts do the same thing in [remote/jumpbox-setup.sh](remote/jumpbox-setup.sh).

The role gets exactly what the API needs: connect, and read or change rows in `entries`. It can't create tables, change the schema, or touch any other table.

### Check the role

```bash
psql -U journal_app -c "SELECT current_user,
  has_table_privilege('entries','INSERT') AS can_insert,
  has_schema_privilege('public','CREATE') AS can_create_tables,
  pg_has_role(current_user,'azure_pg_admin','MEMBER') AS is_admin;"
psql -U journal_app -c "CREATE TABLE sneaky (x int);"
```

Run these from the shell prompt, not from inside psql. Paste `pg-app-password` at the prompts.

If nothing at all comes back, you're probably still inside psql. psql treats the pasted `psql -U ...` lines as an unfinished SQL statement and waits for more, with a prompt like `career_journal">` or `career_journal->`. Press **Ctrl+C** to clear it, type `\q`, and run the commands again.

The first command should print `journal_app | t | f | f`. The second should fail with `permission denied for schema public`.

### Store the app's database URL

In Key Vault, go to **Secrets → Generate/Import**, name it `database-url`, and type this into the value field, replacing the placeholder with `pg-app-password`:

```text
postgresql://journal_app:<pg-app-password>@psql-journal-dev-d5775.postgres.database.azure.com:5432/career_journal?sslmode=verify-full&sslrootcert=/etc/ssl/certs/ca-certificates.crt
```

Build it in the portal field. Don't assemble it in a file or a chat.

### Stop the jumpbox

Close the Bastion tab, open the VM and select **Stop**. A stopped VM is deallocated, so you pay only for its disk, about $1.50 a month.

**Check:** see "Verify phase 4" in [README.md](README.md). It's adapted to this guide in two ways: the SSH key is a local file rather than a Key Vault secret, and the jumpbox has no Key Vault role assignments.

---

## Phase 5: container registry and image

### Create the registry

Go to **Container registries → Create**.

| Field | Value |
|---|---|
| Registry name | `acrjournaldevd5775` |
| Location | Central US |
| Pricing plan | Basic |
| Role assignment permissions mode | RBAC Registry Permissions |

After it's created, confirm that **Settings → Access keys → Admin user** is unchecked.

**Concept:** with the admin user off, the registry has no shared password. You push with your Entra sign-in, and the app pulls with its managed identity.

### Let the app pull images

In the registry, go to **Access control (IAM) → Add role assignment** and assign **AcrPull** to the managed identity `id-journal-dev-app`. When asked which members to assign, choose **Managed identity**, then **User-assigned managed identity**.

### Build and push the image

The portal can't build an image from your local code, so this step uses Docker on your machine. The simplest way is the script itself:

```bash
./infra/05-registry.sh
```

It sees that the registry and role assignment already exist and changes neither. It builds the image, smoke-tests it against a throwaway PostgreSQL container, and pushes it.

To do the steps by hand instead:

```bash
docker build --platform linux/amd64 -t acrjournaldevd5775.azurecr.io/journal-api:manual-1 .
az acr login --name acrjournaldevd5775
docker push acrjournaldevd5775.azurecr.io/journal-api:manual-1
```

**Check:** in the registry, **Services → Repositories → journal-api** shows your tag.

---

## Phase 6: the Container App

### Give the app identity its two secrets

Do this first, so the app can read its secrets the moment it starts.

In Key Vault, go to **Secrets → database-url → Access control (IAM) → Add role assignment**. Assign **Key Vault Secrets User** to the managed identity `id-journal-dev-app`. Then do the same for `openai-api-key`.

**Concept:** these role assignments are on single secrets, not on the whole vault. The app can read its own two secrets, but not the database admin password. The scripts made the same change in phase 6.

### Create the app and its environment

Go to **Container Apps → Create → Container App**.

**Basics**

| Field | Value |
|---|---|
| Container app name | `ca-journal-api` |
| Deployment source | Container image |
| Region | Central US |
| Container Apps environment | **Create new** |

In the new environment's settings:

| Tab | Field | Value |
|---|---|---|
| Basics | Environment name | `cae-journal-dev` |
| | Environment type | Workload profiles |
| | Zone redundancy | Disabled |
| Monitoring | Logs destination | Azure Log Analytics → `log-journal-dev` |
| Networking | Use your own virtual network | Yes |
| | Virtual network / infrastructure subnet | `vnet-journal-dev` / `snet-app` |
| | Virtual IP | External |

**Container**

| Field | Value |
|---|---|
| Use quickstart image | unchecked |
| Name | `api` |
| Image source | Azure Container Registry |
| Registry / image / tag | `acrjournaldevd5775` / `journal-api` / your tag |
| Authentication | Managed identity → `id-journal-dev-app` |
| Workload profile | Consumption |
| CPU and memory | 0.25 cores, 0.5 Gi |

Add two environment variables, both entered manually:

| Name | Value |
|---|---|
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` |
| `OPENAI_MODEL` | `gpt-6-luna` |

**Ingress**

| Field | Value |
|---|---|
| Ingress | Enabled |
| Ingress traffic | Accepting traffic from anywhere |
| Ingress type | HTTP |
| Transport | Auto |
| Insecure connections | **unchecked** |
| Target port | `8000` |

Select **Review + create**. Creating the environment in your VNet takes 5–10 minutes.

The first revision will fail to start, because `DATABASE_URL` and `OPENAI_API_KEY` aren't set yet and the app's settings check refuses to start without them. That's expected; the next steps fix it.

### Add the Key Vault references

Open the app, go to **Settings → Secrets → Add**, and create these two:

| Key | Type | Key Vault secret URL | Managed identity |
|---|---|---|---|
| `database-url` | Key Vault reference | `https://kv-journal-dev-d5775.vault.azure.net/secrets/database-url` | `id-journal-dev-app` |
| `openai-api-key` | Key Vault reference | `https://kv-journal-dev-d5775.vault.azure.net/secrets/openai-api-key` | `id-journal-dev-app` |

If the identity isn't in the list, attach it under **Settings → Identity → User assigned** first.

**Concept:** the app stores only these URLs, never the secret values. Container Apps fetches the values with the managed identity and fetches them again every 30 minutes. That means rotating a secret in Key Vault needs no redeploy.

### Finish the container settings and deploy

Go to **Application → Revisions and replicas → Create new revision** (some portal versions call this **Containers → Edit and deploy**). Select the `api` container, then **Edit**.

**Environment variables:** add these two, each with source **Reference a secret**:

| Name | Secret |
|---|---|
| `DATABASE_URL` | `database-url` |
| `OPENAI_API_KEY` | `openai-api-key` |

**Health probes**

| Probe | Type | Path / port | Period | Failure threshold |
|---|---|---|---|---|
| Startup | HTTP GET | `/docs` : 8000 | 3 s | 20 |
| Readiness | HTTP GET | `/docs` : 8000 | 10 s | default |
| Liveness | TCP | 8000 | 15 s | default |

**Scale**

| Field | Value |
|---|---|
| Min replicas | 1 |
| Max replicas | 3 |
| Scale rule | name `http`, type HTTP scaling, 50 concurrent requests |

Save, then select **Create** to deploy the new revision.

**Concept:** every change to the container creates a new revision. The old revision keeps serving traffic until the new one passes its startup probe, so a bad deploy never takes the API down. Min replicas 1 keeps the API running with nobody signed in (requirement 4).

The `ME_cae-journal-dev_...` resource group that appeared holds the environment's load balancer and public IP. Together those cost about $21.90 a month, the largest line on the bill.

**Check:** on the app's **Overview**, open the **Application Url** and add `/docs` to the end. Then work through "Verify phase 6: all five requirements" in [README.md](README.md).

---

## Tear down

Use the script, which works the same for resources created in the portal:

```bash
./infra/99-teardown.sh
```

To do it in the portal instead:

1. Open `log-journal-dev` and select **Delete**, ticking **Delete the workspace permanently**. Otherwise its name stays reserved for 14 days, and a rebuild can fail.
2. Open `rg-journal-dev`, select **Delete resource group**, and type the group's name to confirm.

The Key Vault stays soft-deleted for 7 days. If you build again after that, start from "Create the vault"; within 7 days, use "If the old vault is still soft-deleted".
