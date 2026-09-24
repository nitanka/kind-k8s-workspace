# Vault path overview: auth, secrets engines, and leases

A general reference for how Vault's paths are organized, grounded in the concrete paths this cluster actually uses.

## Top-level split: `auth/` vs everything else

Vault has exactly two kinds of mounts: **auth methods** (answer "who is this caller") and **secrets engines** (answer "give me a secret"). Everything under `auth/` is the first kind; everything else (`database/`, `kv/`, `pki/`, etc.) is the second.

## `auth/<method>/...` — authentication

| Path | Purpose | What we used it for |
|---|---|---|
| `auth/<method>/config` | Trust setup — *can Vault even verify this identity proof* | `auth/jwt/config`: OIDC discovery URL + SPIRE's CA |
| `auth/<method>/role/<name>` | Authorization — *which identities are accepted, and what do they get* | `auth/jwt/role/spire-workload`: `bound_claims` matching SPIFFE IDs, `token_policies` |
| `auth/<method>/login` | The actual call — present proof, get back a Vault token | `auth/jwt/login jwt=<token> role=spire-workload` |

Reference: 
- [`/vault/api-docs/auth/jwt`](https://developer.hashicorp.com/vault/api-docs/auth/jwt) 
- `POST /auth/jwt/config`: "Configures validation information used across all roles,"
- `POST /auth/jwt/role/:name` "Registers a role," 
- `POST /auth/jwt/login` — "It verifies the JWT signature to authenticate that entity **and then authorizes the entity for the given role**" 

Note: this `config`/`role`/`login` split is a real, confirmed pattern for JWT (and similarly for `kubernetes`, `aws`, `approle`), but there is no single HashiCorp page declaring it a universal law for every auth method — [`/vault/docs/concepts/auth`](https://developer.hashicorp.com/vault/docs/concepts/auth) only documents that methods have their own login endpoints and must be enabled before use, deferring to `vault path-help` for per-method specifics.

**Why both `config` and `role` are required, not just `config`:** `config` only proves a JWT is cryptographically genuine (signed by SPIRE, matches the trust domain). It says nothing about *who is allowed to log in* or *what they get*. Without a role, Vault could verify authenticity but has no basis for an authorization decision — `role` is what restricts which `sub`/`aud` claims are acceptable (`bound_claims`, `bound_audiences`) and what Vault token policies/TTL a successful login produces (`token_policies`, `token_ttl`). `vault write auth/jwt/login` requires a `role` argument; there's no login path without one. This three-part split (`config` = trust, `role` = policy, `login` = the call) is Vault's general pattern across every auth method (`kubernetes`, `aws`, `approle`, etc.), not something specific to this setup.

## `sys/...` — Vault's own control plane

Not a secret store itself — this is where Vault's own configuration lives:
- `sys/auth`, `sys/mounts` — enable/disable/list auth methods and secrets engines (`vault auth enable jwt`, `vault secrets enable database` write here under the hood)
- `sys/policies/acl/<name>` — write/read ACL policies (what gets attached via `token_policies`)
- `sys/leases/*` — lookup/renew/revoke any leased secret (`vault lease revoke <lease_id>`, used to test the in-flight-transaction behavior — see `VAULT-DATABASE-ENGINE.md`)
- `sys/health`, `sys/seal-status` — status (`vault status` reads this)

## Secrets engines — each has its own path conventions

**`database/`** (what this cluster uses):

| Path | Verb | What it does |
|---|---|---|
| `database/config/<name>` | write | Connection details — the admin/"root" credential Vault authenticates with (here: `vaultadmin`) |
| `database/roles/<name>` | write | The recipe — creation/revocation SQL templates, TTLs, which `db_name` config to target |
| `database/creds/<name>` | **read** | Executes the recipe *right now* — mints a brand-new leased credential |
| `database/rotate-root/<name>` | write (no body) | Rotates the config's own admin password, discarding the old one — see `VAULT-DATABASE-ENGINE.md` for why this matters |
| `database/static-roles/<name>` + `database/static-creds/<name>` | — | A different mode, not used here: instead of creating new disposable users, Vault rotates the password of an *existing*, fixed-name DB user on a schedule — useful when an app needs a stable username it can't tolerate changing |

Reference: [`/vault/api-docs/secret/databases`](https://developer.hashicorp.com/vault/api-docs/secret/databases)
- `POST /database/config/:name` "Configures the connection string used to communicate with the desired database," 
- `POST /database/roles/:name` "Creates or updates a role definition," 
- `GET /database/creds/:name` "Generates a new set of dynamic credentials based on the named role," 
- `POST /database/rotate-root/:name` "Used to rotate the 'root' user credentials stored for the database connection," and static roles: "a 1-to-1 mapping of a Vault Role to a user in a database which are automatically rotated"

**Other common engines, for context** (not deployed in this cluster, same underlying pattern):
- **`kv/`** — static secrets you write yourself; no leases, no dynamic generation. `kv/data/<path>` (v2) or `kv/<path>` (v1).
- **`pki/`** — issues X.509 certs on demand: `pki/roles/<name>` (constraints on what can be issued), `pki/issue/<name>` (mint one).
- **`transit/`** — encryption-as-a-service: `transit/encrypt/<name>` / `transit/decrypt/<name>` — Vault never hands back the raw key, only performs the operation.

## The one thread connecting all of it: leases

Anything with a TTL — `database/creds/...`, dynamic PKI certs, etc. — gets a `lease_id` back. `sys/leases/*` manages that independently of which engine issued it: `vault lease renew <id>` extends it (up to `max_ttl`), `vault lease revoke <id>` kills it early. Static things like `kv/` secrets have no lease at all — their lifecycle is entirely yours to manage.
