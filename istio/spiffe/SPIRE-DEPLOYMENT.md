## Deployment of SPIFFE with SPIRE

**Strategy**

1. We will be deploying using the helm chart.
2. Official helm chart will be used, and I am not going to perform any changes to the default values.
3. We will use the `spire` namespace 

**Process**

1. Install the CRDs
```bash
helm upgrade --install -n spire spire-crds spire --repo https://spiffe.github.io/helm-charts-hardened/ --create-namespace
```

2. Install the server
```bash
helm upgrade --install -n spire spire spire --repo https://spiffe.github.io/helm-charts-hardened/
```

**Reference**
https://artifacthub.io/packages/helm/spiffe/spire#install-instructions

## Using SPIRE as the CA for Istio

**Strategy**

There are two independent integration points, and a pod can use either or both:

1. **App-level identity** — the app process itself calls the SPIRE Workload API directly over the `csi.spiffe.io` CSI socket (e.g. `nginx-test.yaml`, mounted at `/run/spire/sockets`). Used when app code needs to present or verify a SPIFFE ID itself.
2. **Mesh-level mTLS** — the Envoy sidecar gets its mTLS certificate from SPIRE over SDS instead of istiod's own CA. istiod's CA is bypassed entirely for these workloads.

Reference: https://istio.io/latest/docs/ops/integrations/spire/

**Process**

1. SPIRE's `trust_domain` (`example.org`) must match Istio's `meshConfig.trustDomain` — Istio's default is `cluster.local`, so this has to be set explicitly.

2. Layer a values file onto the `istiod` Helm chart (kept separate from the base install so it can be applied as its own `helm.valueFiles` entry, e.g. under ArgoCD) — see `manifests/istiod-values-spire.yaml`:
   - `meshConfig.trustDomain: example.org`
   - a `spire` sidecar-injection template that mounts the `csi.spiffe.io` socket into the `istio-proxy` container at `/run/secrets/workload-spiffe-uds`
   ```bash
   helm upgrade istiod istio/istiod -n istio-system -f manifests/istiod-values-spire.yaml
   ```

3. Register workloads with a `ClusterSPIFFEID` — see `manifests/sidecar-clusterspiffeid.yaml`. It matches any pod labeled `spiffe.io/spire-managed-identity: "true"` (cluster-wide, no namespace restriction) and registers `spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}`.
   ```bash
   kubectl apply -f manifests/sidecar-clusterspiffeid.yaml
   ```

4. On the workload pod, add:
   - the label `spiffe.io/spire-managed-identity: "true"` (to match the `ClusterSPIFFEID` above)
   - the annotation `inject.istio.io/templates: "sidecar,spire"` (adds the `spire` template on top of the default `sidecar` one)
   - the namespace must have `istio-injection=enabled`

   `manifests/nginx-test.yaml` has both this and the app-level CSI mount, so it exercises both integration points at once.

**Verification**

1. Confirm SPIRE auto-registered the pod:
   ```bash
   kubectl exec -n spire spire-server-0 -c spire-server -- \
     /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock
   ```
   Expect an entry for `spiffe://example.org/ns/<namespace>/sa/<service-account>`.

2. Confirm the sidecar's cert actually comes from SPIRE, not istiod:
   ```bash
   istioctl proxy-config secret <pod> -n <namespace> -o json
   ```
   Decode the `tlsCertificate.certificateChain` (base64 PEM) and check:
   - SAN (`openssl x509 -noout -text`) is `spiffe://example.org/ns/<namespace>/sa/<service-account>`
   - Issuer is SPIRE's root (`CN=example.org, O=Example`), not `istio-ca-secret`
   - `ROOTCA` secret's validation context is `envoy.tls.cert_validator.spiffe` with the `example.org` trust domain

**Note:** istiod itself is never registered with SPIRE and has no `CA_PROVIDER`/`CA_ADDR` env vars — SPIRE issues SVIDs directly to each Envoy proxy over SDS, bypassing istiod's CA path entirely. There is no such thing as "SPIRE as istiod's upstream CA" in this integration.