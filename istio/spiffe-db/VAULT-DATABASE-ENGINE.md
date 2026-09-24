## Enable database engine
```bash
export VAULT_TOKEN="hvs...."
kubectl exec vault-0 -n vault -c vault -- env VAULT_TOKEN=$VAULT_TOKEN vault secrets enable database 
kubectl exec vault-0 -n vault -c vault -- env VAULT_TOKEN=$VAULT_TOKEN vault secrets list 2>&1
```

## Deploying Postgres and wiring it to the database engine

**Strategy**

Two distinct users, two distinct jobs — this is the whole point of the setup:

- **`vaultadmin`** — the user *Vault itself* connects as. `LOGIN` + `CREATEROLE`, deliberately not superuser. Its ability to grant the app role comes from holding that role `WITH ADMIN OPTION`, not from elevated privilege — it can create/drop lease-scoped roles and hand out `app_readwrite` membership, nothing else.
- **`app_readwrite`** — a `NOLOGIN` group role carrying the actual data privileges (`SELECT/INSERT/UPDATE/DELETE` + sequence usage, via `ALTER DEFAULT PRIVILEGES` so it also covers tables created later). Every dynamic user Vault mints gets granted into this role — nobody has per-user, per-table grants to manage.

Uses `bitnami/postgresql` directly with a values overlay (`manifests/postgres-values.yaml`) — no bespoke chart. Deployed with the same Istio/SPIRE sidecar injection as every other workload here (`vault-0`, the OIDC discovery provider): the pod carries `sidecar.istio.io/inject: "true"` + `spiffe.io/spire-managed-identity: "true"` as **labels** and `inject.istio.io/templates: "sidecar,spire"` as an annotation — same reasoning as before (webhook `objectSelector` only ever matches labels).

**Process**

1. Bootstrap secret for `vaultadmin`'s password — generated at deploy time, never committed:
   ```bash
   kubectl create namespace postgres
   kubectl create secret generic postgres-vaultadmin -n postgres \
     --from-literal=VAULTADMIN_PASSWORD="$(openssl rand -base64 24)"
   ```

2. Install:
   ```bash
   helm install postgres bitnami/postgresql --version 18.11.6 -n postgres -f manifests/postgres-values.yaml
   ```
   The `postgres` superuser password is left unset — the chart auto-generates one into its own Secret (`postgres-postgresql`), which the init script also reads via `PGPASSWORD` (deterministic secret name, so it can be referenced in the same values file even before first install).

3. Bugs hit and fixed while building the init script (`primary.initdb.scripts` in `manifests/postgres-values.yaml`), worth knowing if this ever needs touching again:
   - `$POSTGRES_USER` doesn't exist in Bitnami's image (that's the Docker-official image's env var name) — the superuser is just the literal username `postgres`.
   - `psql` needs `PGPASSWORD` explicitly — local-socket auth is `md5`, not `trust`, even inside the same pod.
   - `ALTER DEFAULT PRIVILEGES ... ON TABLES` does **not** cover sequences — `serial`/identity columns need `ON SEQUENCES` granted separately, or every `INSERT` from a dynamic user fails with `permission denied for sequence ...`.
   - Any values change to `initdb.scripts` only takes effect on a **fresh** data directory — `helm uninstall` + delete the PVC + reinstall, since initdb scripts only run once.

**Wiring Vault's database secrets engine**

```bash
export VAULT_TOKEN="hvs...."
VAULTADMIN_PW="<the password from the Secret created in step 1>"

vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-readwrite" \
  connection_url="postgresql://{{username}}:{{password}}@postgres-postgresql.postgres.svc.cluster.local:5432/appdb?sslmode=disable" \
  username="vaultadmin" \
  password="$VAULTADMIN_PW"

vault write database/roles/app-readwrite \
  db_name="postgres" \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"'; GRANT app_readwrite TO "{{name}}";' \
  revocation_statements='DROP ROLE IF EXISTS "{{name}}";' \
  default_ttl="15m" \
  max_ttl="1h"
```

**Immediately rotate the root credential — the K8s Secret is a one-time bootstrap only, not the live password:**
```bash
vault write -f database/rotate-root/postgres
```
"Root" here is Vault terminology for whatever credential is configured in `database/config/<name>` — in this setup that's `vaultadmin` itself (still just `LOGIN` + `CREATEROLE` + `app_readwrite` membership, not the Postgres superuser; Vault is never given the real superuser credential). This connects once with the bootstrap password from `postgres-vaultadmin`, then runs `ALTER ROLE vaultadmin WITH PASSWORD '<new-random>'` and keeps the new password only in Vault's own storage. After this, the `postgres-vaultadmin` K8s Secret is stale — confirmed by testing it directly against Postgres and getting `password authentication failed`, while `vault read database/creds/app-readwrite` keeps working using Vault's internally-rotated password. The Secret is left in place only because the `initdb` script needs *some* value to create the role on first boot; it plays no further role after this point.

**Verification — a real dynamic credential, actually used**

```bash
vault read -format=json database/creds/app-readwrite
# {
#   "lease_id": "database/creds/app-readwrite/...",
#   "data": { "username": "v-root-app-read-...", "password": "..." },
#   "lease_duration": 900
# }
```
Then, with those exact values:
```bash
PGPASSWORD="<password>" psql -h postgres-postgresql.postgres.svc.cluster.local -U "<username>" -d appdb \
  -c "INSERT INTO notes(body) VALUES ('hello'); SELECT * FROM notes;"
```
Confirmed working end-to-end: the returned user is a real Postgres role, a member of `app_readwrite` (checked directly via `pg_auth_members`), and can insert/select against a real table through that membership — no static credential involved anywhere in this path.

**Not yet done — the full chain to SPIRE:** this proves Vault → Postgres dynamic credentials work. It does not yet prove a SPIRE-authenticated workload (via `auth/jwt/login`, see `VAULT-DEPLOYMENT.md`) pulling this credential itself — that needs `database/creds/app-readwrite` added to a policy attached to the `spire-workload` JWT role's `token_policies`, which is still just `default` right now.

## Terminology: "Vault role" vs "Postgres role" are not the same thing

Both layers use the word "role," and it means something different at each:

- **`database/roles/<name>`** (Vault) — a config object only. Not credentials, not a database account — just the recipe: which `db_name` connection to use, the `creation_statements`/`revocation_statements` templates, and the TTLs.
- **`database/creds/<name>`** (Vault) — the read that *executes* that recipe. This is the moment `{{name}}`/`{{password}}`/`{{expiration}}` get filled in and the resulting SQL runs against Postgres.
- **The actual Postgres role** (e.g. `v-root-app-read-...`) — created fresh by that SQL, disposable, lease-scoped. Distinct from the Vault config object that shares a similar name.

`{{password}}` and `{{expiration}}` are never supplied by us or by Postgres — both are generated by Vault itself, server-side, at `database/creds/<name>` read time: `{{password}}` from the plugin's random generator (or a configured `password_policy`), `{{expiration}}` as `now + default_ttl`. Postgres only ever sees the fully-substituted literal SQL, never the template.

## Scaling to more than one database (design guidance — not yet applied here)

Only `appdb` exists in this cluster today. The pattern below was worked out in conversation for when a second database is actually needed, but `test`/`vaultadmin_test`/`test_readwrite` do **not** currently exist — this section is guidance, not a record of what's deployed.

**The constraint that drives the design:** Postgres roles are cluster-wide objects — there's only ever one role of a given name in the whole cluster, not one per database. So reusing `vaultadmin`'s literal account for a second database creates a real conflict: each `database/config/<name>` entry stores its *own* independently-rotated password for whatever `username` it's configured with. Two configs both claiming `username="vaultadmin"` would each rotate that one shared account's password independently — whichever rotates last silently invalidates the other's cached credential.

**The fix: one dedicated admin role per database**, not shared:
- A new database needs its own `vaultadmin_<db>` (same scoping as `vaultadmin`: `LOGIN` + `CREATEROLE`, never superuser), bootstrapped the same way (a K8s Secret for the *initial* password only, then `vault write -f database/rotate-root/<config-name>` immediately after configuring, so Vault becomes sole owner of the live password — same as `vaultadmin` today).
- A new `database/config/<db>` entry (connection strings are per-database at the wire-protocol level — one DSN can't serve two databases).
- Either a new group role (`test_readwrite`) or reuse of `app_readwrite`'s *name* across databases — both valid, and this is a separate choice from the admin-user question above. Role *names* are cluster-wide and can be shared; role *membership grants* are also cluster-wide (`GRANT app_readwrite TO ... WITH ADMIN OPTION` works from any database's connection), but the actual table/sequence privileges a role carries are always per-database `GRANT`s — reusing the name doesn't imply reusing the privileges; those still need granting again in the new database's schema.
- A new `database/roles/<name>` pointing `db_name` at the new config — always required, one per (database, permission-scope) combination, regardless of the naming choice above.

**A Postgres-specific gotcha hit while testing this:** `CREATE DATABASE` cannot run in the same `psql -c` statement batch as anything else — it errors with `CREATE DATABASE cannot run inside a transaction block`, because `-c "stmt1; stmt2;"` sends the whole batch as one implicit transaction, and Postgres refuses `CREATE DATABASE` inside any transaction. It needs its own standalone `-c` invocation, before creating any roles or grants that follow.

## Lease expiry and revocation — what actually happens to an in-flight transaction

Tested directly, live, not assumed: opened a session as a dynamic `app-readwrite` credential, confirmed via `pg_stat_activity` (`state: active, query: SELECT pg_sleep(60)`) that it was genuinely mid-transaction, then ran `vault lease revoke <lease_id>` while it was still running.

**Result: the in-flight transaction was not disrupted.** `INSERT` → 60s sleep → a final `SELECT` → `COMMIT` all completed and committed successfully, entirely *after* the revoke ran and dropped the role. Postgres does not force-terminate an already-authenticated, currently-connected backend just because its role gets dropped from a different connection — the session keeps running on its already-established state.

One thing that briefly looked like the opposite: querying `pg_stat_activity WHERE usename='<the dropped role>'` immediately after revoke returned `0 rows`, as if the session had vanished. It hadn't — `usename` in that view is resolved by looking up the backend's role OID against `pg_authid` *at query time*; once the role row is dropped, that lookup returns nothing, so the row appears to disappear from a `usename`-filtered query even though the backend process and its in-flight query are completely unaffected underneath.

**The practical implication:** revocation blocks *future* connection attempts (a fresh login with the now-dropped role fails immediately) — it does not roll back or kill a connection that's already open. An application holding a long-lived connection or a pooled connection across a lease's expiry keeps working on that specific connection until it disconnects; only the *next* reconnect attempt fails. Design retry/reconnect logic around "can't open a new connection," not "existing work gets killed."