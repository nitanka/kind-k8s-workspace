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

6. Create a `Service` in front of it. This is required, not optional — without one, cross-pod traffic to the pod's raw IP goes through Istio's `PassthroughCluster`, which originates **plaintext**, not automatic mTLS, so testing against a bare pod IP is meaningless (it'll fail identically whether or not the client is in the mesh). The pod has no `app` label — only `service.istio.io/canonical-name` (auto-added by injection) — so the selector must match that, not `app`:
   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Service
   metadata:
     name: nginx
     namespace: test-deployment
   spec:
     selector:
       service.istio.io/canonical-name: nginx
     ports:
       - port: 80
         targetPort: 80
   EOF
   kubectl get endpoints nginx -n test-deployment
   # expect: nginx   <pod-ip>:80
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

4. Prove STRICT is actually being enforced — a non-mesh client (no sidecar at all) should be reset:
   ```bash
   kubectl run curl-plain --image=curlimages/curl:8.10.1 --restart=Never -n default -- sleep 3600
   # `default` namespace must NOT have istio-injection=enabled, so this pod gets no sidecar
   kubectl exec curl-plain -n default -- curl -m 5 -sv http://<nginx-pod-ip>:80/
   # expect: "Recv failure: Connection reset by peer"
   ```

5. Confirm the *positive* case — an in-mesh client, with the same `spire` template as `nginx`, reaching it through the **Service** (not the raw pod IP — see step 6 above):
   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: curl-mesh
     namespace: test-deployment
     labels:
       spiffe.io/spire-managed-identity: "true"
     annotations:
       inject.istio.io/templates: "sidecar,spire"
   spec:
     containers:
       - name: curl-mesh
         image: curlimages/curl:8.10.1
         command: ["sleep", "3600"]
   EOF
   kubectl exec curl-mesh -n test-deployment -c curl-mesh -- \
     curl -m 5 -sv http://nginx.test-deployment.svc.cluster.local:80/
   # expect: HTTP/1.1 200 OK
   ```
   If `curl-mesh` is created without the `spiffe.io/spire-managed-identity` label/annotation, it gets the **default** sidecar template instead — an istiod/Citadel-issued cert, not a SPIRE one. Since `nginx`'s Envoy only trusts SPIRE's root (`ROOTCA` is `envoy.tls.cert_validator.spiffe` scoped to `example.org`), the handshake fails and looks identical to the non-mesh rejection in step 4. Both sides need the `spire` template to actually test SPIRE-to-SPIRE mTLS.

   **Startup race:** even with the correct label/annotation, a freshly-created pod can fail its first request(s) with the sidecar logging `workload is not authorized for the requested identities`. `kubectl get pod` reporting `2/2 Running` only means both containers started — it does not mean SPIRE's `ClusterSPIFFEID` controller has finished creating the registration entry and the local `spire-agent` has synced it into its cache. Don't fire the test request immediately after apply; wait for the cert to go `ACTIVE` first:
   ```bash
   until istioctl proxy-config secret curl-mesh -n test-deployment 2>/dev/null | grep -q "^default.*ACTIVE"; do
     sleep 2
   done
   ```