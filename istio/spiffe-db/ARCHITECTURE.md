# Architecture: SPIRE as the identity root for Istio and Vault

This document is the big picture — what exists, why each piece is there, and how identity actually flows end to end. For exact commands, see the component docs it links to; this file explains the *why* and the *how they connect*.

## The problem this solves

Every workload here — Envoy sidecars, Vault, Postgres — needs to prove who it is to something else, without a static password sitting in a Secret. SPIRE is the single root of trust that issues all of those identities (as SPIFFE IDs, in X.509 or JWT form). Everything downstream — Istio's mTLS, Vault's login, Postgres's dynamic credentials — is built on top of that one root, not independent trust systems bolted together.

## Components and what each one actually does

| Component | Namespace | Role |
|---|---|---|
| SPIRE Server | `spire` | Issues SVIDs (X.509 + JWT), holds the root CA, runs the federation bundle endpoint and OIDC discovery provider |
| SPIRE Agent (DaemonSet) | `spire` | Node-local; attests pods, hands SVIDs to workloads over a Unix socket |
| SPIRE Controller Manager | `spire` (runs inside `spire-server-0`) | Watches `ClusterSPIFFEID` CRs, auto-creates registration entries for matching pods |
| SPIFFE CSI Driver | `spire` | Mounts the SPIRE Agent's Workload API socket into any pod that asks, in any namespace |
| SPIFFE OIDC Discovery Provider | `spire` | Exposes SPIRE's JWT signing keys as a standard OIDC/JWKS endpoint — this is what makes SPIRE's JWT-SVIDs usable by *any* OIDC-aware relying party, not just SPIFFE-native ones |
| Istiod | `istio-system` | Mesh control plane. Delegates workload cert delivery to SPIRE via the `spire` sidecar-injection template — never registers itself with SPIRE, never issues its own workload certs for SPIRE-backed pods |
| Vault | `vault` | Secrets management. Authenticates callers via their SPIRE JWT-SVID (`auth/jwt`), then issues short-lived Postgres credentials (`database` engine) |
| Postgres | `postgres` | The actual data store. Has no idea SPIRE or Vault exist — it only ever sees a Postgres role name and password, created/destroyed by Vault |

**Deliberately excluded from the mesh:** `spire-server`, `spire-agent`, and the CSI driver DaemonSets are never given Istio sidecars. Istio's own mTLS *depends* on SPIRE for certs — wrapping SPIRE's own control plane in Istio would be circular. This is enforced by design: sidecar injection is opt-in per pod (a label + annotation), not namespace-wide, specifically so it never accidentally reaches these three.

## Two independent identity mechanisms, often confused

SPIRE hands out two different kinds of proof, and this system uses both for different jobs:

1. **X.509-SVID, for transport security (Istio mTLS).** Every mesh sidecar (`nginx`, `vault-0`, `postgres-postgresql-0`, the OIDC discovery provider itself) gets a short-lived X.509 cert from SPIRE via the CSI socket. Istio's `PeerAuthentication` (`STRICT`, mesh-wide) means every sidecar-to-sidecar connection is mutually authenticated using these certs. Neither Vault nor Postgres are aware this is happening — it's transparent at the Envoy layer, underneath whatever the application is actually doing.

2. **JWT-SVID, for application-level login (Vault auth).** A workload that wants to authenticate *to Vault itself* fetches its own JWT-SVID from the Workload API (app-level CSI socket mount, e.g. `spire-agent api fetch jwt -audience vault`), then presents that token to `vault write auth/jwt/login`. This is a completely separate credential from the X.509 one above — it's how the *application* proves its identity, not how the *transport* is secured.

These two layers stack, they don't replace each other: the JWT login request to Vault travels *over* an Istio-mTLS-secured connection, but Vault validates the JWT on its own merits regardless of what Envoy did underneath.

## End-to-end flow: a workload getting a database credential

```
                                   ┌─────────────────────────┐
                                   │      SPIRE Server        │
                                   │  (root CA, JWT signing)   │
                                   └────────────┬─────────────┘
                                                │ issues SVIDs via
                                                │ local Workload API
                     ┌──────────────────────────┼──────────────────────────┐
                     │                          │                          │
                     ▼                          ▼                          ▼
          ┌─────────────────────┐   ┌─────────────────────┐   ┌──────────────────────┐
          │   Workload sidecar   │   │  Vault sidecar        │   │ Postgres sidecar      │
          │   (X.509-SVID)       │   │  (X.509-SVID)         │   │ (X.509-SVID)          │
          └──────────┬───────────┘   └───────────┬───────────┘   └───────────┬───────────┘
                     │  Istio STRICT mTLS, transparent, app doesn't see it   │
                     └───────────────────────────┼─────────────────────────┘
                                                  │
     1. Workload fetches its own JWT-SVID         │
        (app-level socket, audience=vault)        │
                     │                            │
                     ▼                            │
     2. vault write auth/jwt/login jwt=<token>    │
        Vault validates signature via SPIRE's     │
        OIDC discovery provider's JWKS ───────────┘
                     │
                     ▼
     3. Vault checks bound_claims (sub matches
        spiffe://example.org/ns/*/sa/*) → issues
        a Vault token with policy "default"
                     │
                     ▼
     4. vault read database/creds/app-readwrite
        Vault connects to Postgres AS "vaultadmin"
        (its own rotated, self-known credential),
        runs CREATE ROLE + GRANT app_readwrite
                     │
                     ▼
     5. Returns a brand-new, TTL'd (15m) Postgres
        username/password to the workload
                     │
                     ▼
     6. Workload connects directly to Postgres
        with that credential — over the same
        Istio-mTLS-secured connection from layer 1
```

## Why the trust chain holds together (and where it would break)

- **Istio trusts SPIRE, not the other way round.** `meshConfig.trustDomain: example.org` matches SPIRE's trust domain — this is the single point where the two systems agree on identity namespace. Get this wrong and every SPIFFE ID minted becomes unrecognizable to the mesh.
- **Vault trusts the OIDC discovery provider's TLS cert, which is itself SPIRE-issued.** This is the layer people most often skip and shouldn't: without `oidc_discovery_ca_pem`, Vault would accept a JWKS from *anyone* claiming to be the issuer, defeating the entire point of checking a signature (see `VAULT-DEPLOYMENT.md` for the full reasoning).
- **The OIDC issuer must be a real, reachable address, not SPIRE's default logical name.** `oidc-discovery.example.org` isn't resolvable anywhere; `global.spire.jwtIssuer` was repointed at the actual Kubernetes Service DNS name so the discovery document's `issuer` claim matches what's actually dialable — a fix chosen specifically because it travels to real infra (unlike a CoreDNS rewrite, which wouldn't survive AWS's managed CoreDNS add-on).
- **`vaultadmin` is scoped, not superuser**, and its password is owned by Vault (`rotate-root`), not us. Vault's blast radius on Postgres is bounded by exactly what `vaultadmin` can do: create/drop lease-scoped roles and grant `app_readwrite` membership — nothing else.
- **`app_readwrite` carries the actual data privileges**, so Vault never needs per-user, per-table grants — every dynamic user is just a fresh login wrapped around the same fixed set of permissions.

## What's proven vs. what's still open

**Proven, end to end, with live tests (not just configured):**
- SPIRE-issued X.509 certs secure every sidecar-to-sidecar connection under STRICT mTLS
- A workload's JWT-SVID, validated against SPIRE's OIDC endpoint, logs it into Vault
- Vault mints real, working, TTL'd Postgres credentials via a scoped `vaultadmin` role
- `vaultadmin`'s password is Vault-owned (rotated once, old value confirmed dead)
- Lease revocation drops the Postgres role and blocks future logins, but does **not** kill an already-open, in-flight transaction — confirmed by revoking a lease mid-transaction and watching it complete and commit anyway (see `VAULT-DATABASE-ENGINE.md`)

**Configured but not yet load-bearing:**
- SPIRE's federation bundle endpoint (X.509 + JWT keys, port 8443) is enabled but unused — nothing consumes it yet; it exists for a possible future X.509-SVID-based Vault integration (Enterprise-only `spiffe` auth method, not available on this CE build)

**Explicitly not done:**
- The `spire-workload` JWT role's `token_policies` is still `default` — a SPIRE-authenticated login does not yet automatically carry permission to read `database/creds/app-readwrite`. That link (a Vault policy + attaching it to the role) is the next step to close the loop from "any SPIRE workload can log in" to "any SPIRE workload can get a DB credential."
- Only one database (`appdb`) exists. A design for scaling to more databases (dedicated admin role per database, never a shared `vaultadmin` account — see `VAULT-DATABASE-ENGINE.md` for why) was worked out but not applied; no second database has actually been created.
- No automated re-sync of `oidc_discovery_ca_pem` if SPIRE's root CA is ever rotated (rare/deliberate, unlike the constant SVID rotation) — see the open item in `VAULT-DEPLOYMENT.md`.

## Where to look for the details

- [SPIRE-DEPLOYMENT.md](SPIRE-DEPLOYMENT.md) — SPIRE install, and using it as Istio's CA
- [VAULT-DEPLOYMENT.md](VAULT-DEPLOYMENT.md) — bringing Vault into the mesh, `auth/jwt` setup, the issuer/CA-pinning reasoning
- [VAULT-DATABASE-ENGINE.md](VAULT-DATABASE-ENGINE.md) — Postgres deployment, `vaultadmin`/`app_readwrite` design, the `database` secrets engine wiring, root rotation
- [README.md](README.md) — STRICT mTLS deployment/testing steps, including the raw-pod-IP-vs-Service gotcha
