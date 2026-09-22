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


## Namespace Annotation for istio injection

Namespace-level `istio-injection=enabled` only controls whether a sidecar gets injected at all — it doesn't control which injection template is used. By default it only applies the standard sidecar template (istiod's own Citadel-issued cert).