#!/usr/bin/env bash
# Runs ON the jumpbox, as root, through `az vm run-command invoke`.
# infra/04-admin.sh sends it with the settings it needs prepended as
# variable assignments; it holds no secrets itself.
#
# 1. Installs the PostgreSQL client and two helpers:
#      kv-secret <name>   prints a Key Vault secret, using the VM's managed identity
#      journal-psql       opens psql on the journal database as the server admin
# 2. Applies database_setup.sql (the same schema the devcontainer uses).
# 3. Creates or updates the least-privilege journal_app role. Only a SCRAM hash
#    of its password is sent to the server, so the password itself can't
#    appear in server logs or query statistics.
# 4. Signs in as journal_app and checks what it can and can't do.
#
# Safe to re-run.

# Set by 04-admin.sh:
# shellcheck disable=SC2154  # KEY_VAULT PG_HOST PG_DATABASE PG_ADMIN_USER PG_APP_USER
#                            # SECRET_ADMIN SECRET_APP PG_CLIENT_VERSION SCHEMA_SQL_B64
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/journal-setup.log
CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

step() { printf '\n== %s\n' "$*"; }

# ---------------------------------------------------------------------------
step "PostgreSQL ${PG_CLIENT_VERSION} client"
cloud-init status --wait >/dev/null 2>&1 || true   # first boot still running apt
if psql --version 2>/dev/null | grep -q " ${PG_CLIENT_VERSION}\."; then
  echo "installed"
else
  # Ubuntu 24.04 ships psql 16; the PostgreSQL project's apt repo has 17.
  apt_get() { apt-get -o DPkg::Lock::Timeout=300 -y -q "$@"; }
  if ! {
    apt_get update
    apt_get install postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt_get install "postgresql-client-${PG_CLIENT_VERSION}"
  } >>"$LOG" 2>&1; then
    echo "install failed; last lines of ${LOG}:"
    tail -n 15 "$LOG"
    exit 1
  fi
fi
psql --version

# ---------------------------------------------------------------------------
step "Helpers: kv-secret, journal-psql"
install -d -m 0755 /etc/journal
cat >/etc/journal/db.env <<EOF
KEY_VAULT=${KEY_VAULT}
PG_HOST=${PG_HOST}
PG_DATABASE=${PG_DATABASE}
PG_ADMIN_USER=${PG_ADMIN_USER}
SECRET_ADMIN=${SECRET_ADMIN}
EOF
# Names only, no secrets. Readable by everyone so journal-psql works for the
# Bastion login user, not just root (04-admin.sh runs this with umask 077).
chmod 0644 /etc/journal/db.env

cat >/usr/local/bin/kv-secret <<'PY'
#!/usr/bin/env python3
"""Print one Key Vault secret to stdout, using this VM's managed identity.

Usage: kv-secret <secret-name>
The identity can read only the secrets 04-admin.sh granted it.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

def get_json(url, headers):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)

if len(sys.argv) != 2:
    sys.exit("usage: kv-secret <secret-name>")
settings = dict(
    line.strip().split("=", 1)
    for line in open("/etc/journal/db.env", encoding="utf-8")
    if "=" in line
)
try:
    token = get_json(
        "http://169.254.169.254/metadata/identity/oauth2/token"
        "?api-version=2018-02-01&resource=" + urllib.parse.quote("https://vault.azure.net", safe=""),
        {"Metadata": "true"},
    )["access_token"]
    secret = get_json(
        f"https://{settings['KEY_VAULT']}.vault.azure.net/secrets/"
        f"{urllib.parse.quote(sys.argv[1], safe='')}?api-version=7.4",
        {"Authorization": "Bearer " + token},
    )
except urllib.error.HTTPError as error:
    sys.exit(f"kv-secret: {sys.argv[1]}: HTTP {error.code} from Key Vault")
sys.stdout.write(secret["value"])
PY

cat >/usr/local/bin/journal-psql <<'SH'
#!/usr/bin/env bash
# psql on the journal database as the server admin. The password comes from
# Key Vault through this VM's managed identity; it's never shown or stored.
# TLS with full certificate and hostname checks.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/journal/db.env
PGPASSWORD="$(kv-secret "$SECRET_ADMIN")" exec psql \
  "host=${PG_HOST} port=5432 dbname=${PG_DATABASE} user=${PG_ADMIN_USER} sslmode=verify-full sslrootcert=/etc/ssl/certs/ca-certificates.crt" "$@"
SH
chmod 0755 /usr/local/bin/kv-secret /usr/local/bin/journal-psql
echo "installed"

# ---------------------------------------------------------------------------
step "Key Vault access through the VM's identity"
# A role granted moments ago can take a few minutes to take effect.
for attempt in $(seq 1 20); do
  if kv-secret "$SECRET_ADMIN" >/dev/null 2>&1; then
    echo "ready"
    break
  fi
  if (( attempt == 20 )); then
    kv-secret "$SECRET_ADMIN" >/dev/null || true
    echo "still denied after 5 minutes; re-run ./infra/04-admin.sh"
    exit 1
  fi
  sleep 15
done

# ---------------------------------------------------------------------------
step "Schema (database_setup.sql)"
printf '%s' "$SCHEMA_SQL_B64" | base64 -d | journal-psql -X -q -v ON_ERROR_STOP=1 -f -

# ---------------------------------------------------------------------------
step "Role ${PG_APP_USER}"
# SCRAM-SHA-256 verifier, the format PostgreSQL stores passwords in
# (RFC 7677). Sending this instead of the password keeps the password out of
# anything the server records about the statement.
read -r -d '' SCRAM_PY <<'PY' || true
import base64, hashlib, hmac, os, sys
password = sys.stdin.read().encode()
salt, iterations = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", password, salt, iterations)
client_key = hmac.new(salted, b"Client Key", "sha256").digest()
server_key = hmac.new(salted, b"Server Key", "sha256").digest()
b64 = lambda data: base64.b64encode(data).decode()
print(f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(hashlib.sha256(client_key).digest())}:{b64(server_key)}")
PY
APP_VERIFIER="$(kv-secret "$SECRET_APP" | python3 -c "$SCRAM_PY")"
export APP_VERIFIER

journal-psql -X -q -v ON_ERROR_STOP=1 -v app_user="$PG_APP_USER" -v db="$PG_DATABASE" <<'SQL'
\getenv verifier APP_VERIFIER
SELECT NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') AS create_role \gset
\if :create_role
  CREATE ROLE :"app_user" LOGIN;
  \echo created
\else
  \echo exists; password re-applied
\endif
ALTER ROLE :"app_user" WITH LOGIN PASSWORD :'verifier';
-- Exactly what the API needs: connect, and read/write rows in entries.
-- No CREATE on the schema (PostgreSQL 15+ default), no DDL, no other tables.
GRANT CONNECT ON DATABASE :"db" TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE entries TO :"app_user";
SQL
unset APP_VERIFIER

# ---------------------------------------------------------------------------
step "Signing in as ${PG_APP_USER}"
# Same TLS settings as the API's DATABASE_URL.
PGPASSWORD="$(kv-secret "$SECRET_APP")" psql -X -A -t -v ON_ERROR_STOP=1 \
  "host=${PG_HOST} port=5432 dbname=${PG_DATABASE} user=${PG_APP_USER} sslmode=verify-full sslrootcert=${CA_BUNDLE}" <<'SQL'
SELECT 'connected as:            ' || current_user;
SELECT 'TLS:                     ' || version FROM pg_stat_ssl WHERE pid = pg_backend_pid();
SELECT 'entries rows:            ' || count(*) FROM entries;
SELECT 'select/insert/update/delete on entries: '
       || (has_table_privilege('entries', 'SELECT') AND has_table_privilege('entries', 'INSERT')
           AND has_table_privilege('entries', 'UPDATE') AND has_table_privilege('entries', 'DELETE'));
SELECT 'can create tables:       ' || has_schema_privilege('public', 'CREATE');
SELECT 'can create roles or DBs: ' || (rolcreaterole OR rolcreatedb) FROM pg_roles WHERE rolname = current_user;
SELECT 'is a server admin:       ' || pg_has_role(current_user, 'azure_pg_admin', 'MEMBER');
SQL

echo
echo "JUMPBOX-SETUP-OK"
