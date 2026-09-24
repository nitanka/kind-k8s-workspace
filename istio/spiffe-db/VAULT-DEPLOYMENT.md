## Install Helm

1. Install Helm Chart
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
# List the available releases
helm search repo hashicorp/vault -l
helm install vault hashicorp/vault --version 0.34.1 -n vault --create-namespace
```

<code style="color : red">Note: Installing in Standalone Mode</code>
The pods will be deployed but it will not be in a ready state

2. Get the initialise key
```bash
kubectl get pods -l app.kubernetes.io/name=vault -n vault
kubectl -n vault exec -ti vault-0 -- vault operator init
```

3. Unseal the vault with the keys obtained
```bash
## Unseal the first vault server until it reaches the key threshold
kubectl exec -ti vault-0 -- vault operator unseal # ... Unseal Key 1
kubectl exec -ti vault-0 -- vault operator unseal # ... Unseal Key 2
kubectl exec -ti vault-0 -- vault operator unseal # ... Unseal Key 3
```

4. Verify the vault pods are running
```bash
kubectl get pods -l app.kubernetes.io/name=vault
```

## Bringing Vault into the Istio/SPIRE mesh

**Strategy**

Vault's own listener stays plain HTTP internally — Istio's sidecar already terminates mTLS at the transport layer, same as every other in-mesh workload, so there's no need for a `spiffe-helper` sidecar or TLS listener changes on Vault itself. What SPIRE actually provides here is a way for *services* to authenticate to Vault (JWT-SVID login), not a way to secure Vault's own wire protocol.

**Process**

1. Give `vault-0` a sidecar, using the SPIRE injection template — `manifests/vault-values-istio-spire.yaml`:
   ```bash
   kubectl label namespace vault istio-injection=enabled --overwrite
   helm upgrade vault hashicorp/vault --version 0.34.1 -n vault -f manifests/vault-values-istio-spire.yaml
   ```
   Restarting `vault-0` reseals it — for this PoC we just uninstalled and reinstalled fresh (`helm uninstall vault -n vault`, delete the PVC, reinstall) rather than juggle unseal keys. In a real environment, unseal it after restart instead.

2. Initialize and unseal as in steps 2–3 above.

## Vault validating SPIRE-issued JWT-SVIDs

**Strategy**

Vault Enterprise has a native `spiffe` auth method (validates X.509-SVIDs and JWT-SVIDs directly) — but this Vault is Community Edition (`vault read sys/health` → `enterprise: false`), and `vault auth enable spiffe` fails with `plugin not found in the catalog`. So instead we use Vault CE's built-in `jwt` auth method, pointed at SPIRE's OIDC discovery provider as the trust source. This only covers JWT-SVID login, not X.509 — the OIDC discovery provider's `/keys` endpoint is a standards-compliant JWKS (JWT signing keys only, no X.509 CA certs by spec).

**Why `oidc_discovery_ca_pem` is required, not optional:** Vault validates a JWT by fetching SPIRE's public signing key over HTTPS and checking the JWT's signature against it. If that HTTPS fetch isn't itself authenticated, an attacker doesn't need to break SPIRE's real signing key at all — they just need to get Vault to fetch a *different* key from somewhere else (DNS spoofing, a hijacked Service, a MITM), and Vault would trust anything signed with that attacker-controlled key. The CA pin is what makes the key-discovery step trustworthy — the JWT signature check is only as good as knowing whose key you're checking it against.

**The issuer/address mismatch (the real blocker we hit):** SPIRE's default `jwt_issuer` is `https://oidc-discovery.{trustDomain}` (`https://oidc-discovery.example.org` here) — a logical identity string, not a resolvable address. Vault's OIDC discovery client requires the configured `oidc_discovery_url` to exactly match the `issuer` claim in the discovery document, so pointing Vault at the real Kubernetes Service DNS name fails with `issuer did not match the returned issuer`.

Two ways to fix this were considered and rejected before landing on the right one:
- A CoreDNS `rewrite name` rule mapping the logical issuer to the real Service — works on this kind cluster, but **wouldn't survive on EKS's managed CoreDNS add-on**, so it's not a fix that travels to real infra.
- A per-pod `hostAliases` on just `vault-0` — portable, but Vault-specific; every future consumer of this OIDC endpoint would need its own copy.

The actual fix: set SPIRE's `jwtIssuer` to the real, already-cluster-wide-resolvable Service DNS name instead of the synthetic default — `manifests/spire-server-federation-values.yaml`:
```yaml
global:
  spire:
    jwtIssuer: "https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local"
```
This removes the mismatch at the source (both the JWT `iss` claim and the discovery document's `issuer` field come from this one setting) rather than working around it, and it's portable to any cluster.

**Process**

1. Apply the `jwtIssuer` fix and restart both components to pick it up:
   ```bash
   helm upgrade spire spiffe/spire -n spire -f manifests/spire-server-federation-values.yaml
   kubectl rollout restart statefulset/spire-server -n spire
   kubectl rollout restart deployment/spire-spiffe-oidc-discovery-provider -n spire
   ```

2. Enable Vault's `jwt` auth method and point it at the OIDC discovery provider, trusting SPIRE's root CA for the HTTPS fetch:
   ```bash
   vault auth enable jwt

   # SPIRE's root CA — re-fetch if the CA has since rotated:
   kubectl exec -n spire spire-server-0 -c spire-server -- \
     /opt/spire/bin/spire-server bundle show -socketPath /tmp/spire-server/private/api.sock -format pem > /tmp/spire-root-bundle.pem

   vault write auth/jwt/config \
     oidc_discovery_url="https://spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local" \
     oidc_discovery_ca_pem=@/tmp/spire-root-bundle.pem
   ```
   **Caveat:** this pins the CA at the time of writing. If SPIRE's *root* CA is ever rotated (rare/deliberate, unlike the constant ~1h workload SVID rotation, which needs no action here), this config goes stale and JWT-SVID logins to Vault break until someone re-runs this write. Not yet automated — see the open item below.

3. Create a role — any workload in the trust domain, authenticating with `aud=vault`:
   ```bash
   cat <<'EOF' > /tmp/role.json
   {
     "role_type": "jwt",
     "bound_audiences": "vault",
     "user_claim": "sub",
     "bound_claims_type": "glob",
     "bound_claims": {"sub": "spiffe://example.org/ns/*/sa/*"},
     "token_policies": "default",
     "token_ttl": "15m"
   }
   EOF
   vault write auth/jwt/role/spire-workload @/tmp/role.json
   ```

**Verification — a real workload logging in with its own SVID**

A workload fetches its own JWT-SVID from the local Workload API (app-level CSI socket mount, same pattern as `manifests/nginx-test.yaml`), requesting `vault` as the audience, then logs in directly:
```bash
# From a pod with /run/spire/sockets mounted via the csi.spiffe.io driver:
/opt/spire/bin/spire-agent api fetch jwt -audience vault -socketPath /run/spire/sockets/spire-agent.sock

# Then, with the returned token:
vault write auth/jwt/login role=spire-workload jwt="<token>"
# expect: a real Vault token back, token_meta_role: spire-workload
```
Decoding the JWT (base64) shows `sub: spiffe://example.org/ns/<namespace>/sa/<service-account>` and `iss` matching the OIDC discovery provider — Vault's login response having `token_meta_role` set confirms the `bound_claims` glob matched and the login was accepted purely on the SPIRE-issued identity, no static credential involved.

**Open item:** no automated re-sync of `oidc_discovery_ca_pem` on root CA rotation yet. SPIRE already auto-publishes its current bundle to the `spire-bundle` ConfigMap (`BundlePublisher: k8s_configmap` plugin) — a small `CronJob` reading that ConfigMap and re-running the `vault write auth/jwt/config` step on change would close this gap. Not yet built.

## Database secrets engine

Mounted, not yet configured — no database is deployed in this cluster to point at:
```bash
vault secrets enable database
```
Once a real database exists, this is where the short-lived-credential flow described earlier (SPIRE SVID → Vault login → dynamic DB credential) gets wired up: `database/config/<name>` for the connection, then a `database/roles/<name>` creation statement, then `vault read database/creds/<role>` returns a fresh, TTL'd username/password pair per request.


## Namespace Annotation for istio injection

Namespace-level `istio-injection=enabled` only controls whether a sidecar gets injected at all — it doesn't control which injection template is used. By default it only applies the standard sidecar template (istiod's own Citadel-issued cert).

## Recovering after Vault is wiped (kind cluster stop/restart, PVC deleted, etc.)

Hit this for real: the kind cluster's Docker containers stopped between sessions, and rather than track down the old unseal key, we re-initialized Vault from scratch (`helm uninstall` + delete PVC + reinstall — same acceptable-data-loss approach as the first install). Everything below had to be rebuilt, since a fresh Vault has empty storage even though `spire`/`postgres` survived untouched.

**What survives a Vault wipe, unprompted:** SPIRE, Istio, and Postgres — their own StatefulSets/PVCs are untouched. **What doesn't:** every auth method, secrets engine config, and role Vault had — all of it lived only in Vault's now-deleted storage.

1. Reinstall, init, unseal — same steps as the first-time install above.
2. **Reset `vaultadmin`'s Postgres password** — the old Vault instance had rotated it (see `VAULT-DATABASE-ENGINE.md`) and took that knowledge with it when destroyed; nobody else ever knew the current value. Reset via the superuser:
   ```bash
   kubectl exec postgres-postgresql-0 -n postgres -c postgresql -- psql -h localhost -U postgres -d postgres -c \
     "ALTER ROLE vaultadmin WITH PASSWORD '<newly generated>';"
   ```
3. Re-enable both mounts (empty shells until reconfigured):
   ```bash
   vault auth enable jwt
   vault secrets enable database
   ```
4. Redo `auth/jwt/config`, `auth/jwt/role/spire-workload`, `database/config/postgres`, `database/roles/app-readwrite` — the exact same commands as their first-time setup earlier in this doc and in `VAULT-DATABASE-ENGINE.md`.
5. Immediately `vault write -f database/rotate-root/postgres` again, same reasoning as the first time.

**A real, non-obvious failure hit during this recovery — the OIDC discovery provider's cert lost a SAN entry after restart:** `auth/jwt/config` failed again with the exact same issuer-mismatch-shaped error, even though `jwtIssuer` was already correctly set from before. The actual cause this time was different: the OIDC discovery provider's TLS cert SAN list only had `spire-spiffe-oidc-discovery-provider.spire.svc` (3-label short form) after the controller-manager re-reconciled post-restart — missing the 5-label FQDN (`....svc.cluster.local`) it had before, even though `jwtIssuer` and the connection URL both still used the 5-label form. `autoPopulateDNSNames` is not deterministic across controller-manager restarts — it had genuinely worked correctly before (verified with real TLS validation, not skipped), and then didn't after a restart, seemingly depending on Service/EndpointSlice visibility timing at reconcile time.

**The fix:** stop relying on `autoPopulateDNSNames` for this critical hostname — add it as an explicit, static entry in `spire-server.controllerManager.identities.clusterSPIFFEIDs.oidc-discovery-provider.dnsNameTemplates` (see `manifests/spire-server-federation-values.yaml`), so it's a fixed config value instead of something that can silently vary:
```yaml
spire-server:
  controllerManager:
    identities:
      clusterSPIFFEIDs:
        oidc-discovery-provider:
          dnsNameTemplates:
            - "oidc-discovery.{{ .TrustDomain }}"
            - "spire-spiffe-oidc-discovery-provider.spire.svc.cluster.local"
```
Apply, then `kubectl rollout restart deployment/spire-spiffe-oidc-discovery-provider -n spire` to force a fresh registration entry with the explicit DNS name included.

See `VAULT-CONCEPTS.md` for what each of these paths (`auth/*/config` vs `role` vs `login`, `database/config` vs `roles` vs `creds`) actually means and why both halves are required.