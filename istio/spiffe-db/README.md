## Spiffe Integration for Passwordless Authentication

Setup kubernetes cluster with the SPIRE, with SPIRE as CA authority for Istio. The SPIRE will be used to obtain the credential for authentication and to perform the PoC to evaluate how authorisation is done.

## Deployment

Full SPIRE + Istio-CA setup steps and rationale are in [SPIRE-DEPLOYMENT.md](SPIRE-DEPLOYMENT.md). This section only covers the pieces needed to get to STRICT mTLS:

1. Deploy SPIRE, wire it as Istio's CA (`manifests/istiod-values-spire.yaml`) — see [SPIRE-DEPLOYMENT.md](SPIRE-DEPLOYMENT.md).

2. Install `istio-base` — required for the `PeerAuthentication` CRD (and other Istio CRDs) to exist at all:
   ```bash
   helm install istio-base istio/base -n istio-system --create-namespace --wait
   ```

3. Enforce STRICT mTLS mesh-wide — `manifests/peerauthentication-strict.yaml`:
   ```bash
   kubectl apply -f manifests/peerauthentication-strict.yaml
   kubectl get peerauthentication -A
   # expect: istio-system   default   STRICT
   ```

4. Create/label the test namespace and register the workload:
   ```bash
   kubectl create namespace test-deployment
   kubectl label namespace test-deployment istio-injection=enabled
   kubectl apply -f manifests/sidecar-clusterspiffeid.yaml
   ```

5. Deploy the test pod (already carries the `spiffe.io/spire-managed-identity: "true"` label and `inject.istio.io/templates: "sidecar,spire"` annotation needed to pick up the SPIRE injection template):
   ```bash
   kubectl apply -f manifests/nginx-test.yaml
   kubectl get pod nginx -n test-deployment
   # expect: 2/2 Running (nginx + istio-proxy)
   ```

## Testing the app under STRICT mode

1. Confirm the mesh is actually enforcing STRICT (not just implicit auto-mTLS):
   ```bash
   kubectl get peerauthentication -A
   ```

2. Confirm SPIRE auto-registered the pod:
   ```bash
   kubectl exec -n spire spire-server-0 -c spire-server -- \
     /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock
   ```
   Expect `spiffe://example.org/ns/test-deployment/sa/default`.

3. Pull the sidecar's live cert and confirm it's SPIRE-issued, not istiod's:
   ```bash
   istioctl proxy-config secret nginx -n test-deployment -o json
   ```
   Decode `dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes` (base64 PEM) and check with `openssl x509 -noout -text`:
   - SAN is `URI:spiffe://example.org/ns/test-deployment/sa/default`
   - Issuer is `CN=example.org, O=Example` (SPIRE's root), not `istio-ca-secret`

4. Prove STRICT is actually being enforced, not just present: try reaching the pod's app port with plaintext (no mTLS) from a non-mesh client (a pod with no sidecar, or `kubectl exec` a container without one) — the connection should be refused/reset, since a plaintext client can't complete the mTLS handshake Envoy now requires.

5. To confirm the *positive* case, test in-mesh traffic (sidecar-to-sidecar) still works normally — deploy a second injected pod in the same or another namespace and curl the nginx service from it; it should succeed transparently, with Envoy handling the mTLS handshake on both ends using their SPIRE-issued certs.