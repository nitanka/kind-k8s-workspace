**How to assign spiffeid**

1. Handled via clusterspiffeid, the default spiffeids are created by the helm chart.
2. We can create our own clusterspiffeid as well.
3. Spiffeid will use selectors for selecting the workload type.

    1. **CRD-matching selectors** — "which pods does this CRD apply to?"
    These are just standard Kubernetes label selectors:

    - podSelector — matchLabels / matchExpressions on the pod's own labels (what we used: matchLabels: {app: nginx-spiffe-test})

    - namespaceSelector — matchLabels / matchExpressions on the namespace's labels (what the Helm default uses: matchExpressions with NotIn [spire, spire-server, spire-system])
    Both are ANDed if we set both — a pod must be in a matching namespace and carry matching pod labels. Neither one has anything to do with SPIFFE itself yet — it's pure "does this CRD govern this pod."

    2. **SPIRE workload-attestor selectors** — "how does the agent recognize the pod at connection time?"

        Selector type	Matches on
        k8s:ns	pod's namespace
        k8s:sa	pod's service account
        k8s:pod-name	pod name
        k8s:pod-uid	pod UID (default, always applied)
        k8s:pod-label:<key>	a specific pod label key/value
        k8s:pod-image	pod-level image (rare)
        k8s:container-name	container name within the pod
        k8s:container-image	container's image reference
        k8s:node-name	the k8s Node the pod is scheduled on

        Example — restrict the identity to only apply when a specific container in the pod is asking (useful if you have a sidecar you don't want to receive the same SVID as the main app):


        workloadSelectorTemplates:
        - "k8s:container-name:my-frontend"

        <code style="color : red">Note:</code>
        * podSelector/namespaceSelector decide whether this CRD's template even runs for a pod; 
        * workloadSelectorTemplates decides how tightly the agent verifies the connecting process before handing out the SVID for that already-selected identity.

## Timeline
    
1. You write a ClusterSPIFFEID CR
        │
        ▼
2. spire-controller-manager watches ALL pods in the cluster
   → for each pod, checks: does it match this CR's
     namespaceSelector + podSelector?
        │  ← this is the CRD SELECTOR — pure Kubernetes-object matching,
        │    happens once, at admission/reconcile time, against pod/ns LABELS
        ▼
3. If matched: controller-manager creates a REGISTRATION ENTRY
   on spire-server, embedding:
     - the rendered SPIFFE ID (from spiffeIDTemplate)
     - a workload-attestor selector, e.g. k8s:pod-uid:<uid>
        │
        ▼
4. Later, at runtime, some process inside that pod
   connects to the Workload API socket
        │
        ▼
5. spire-agent reads the connecting process's peer credentials
   off the Unix socket, walks /proc/<pid>/cgroup to find which
   container/pod actually dialed in, and checks: does THIS
   specific process's runtime identity match the selector on
   any registration entry?
        │  ← this is the WORKLOAD-ATTESTOR SELECTOR — runtime
        │    process-to-kernel verification, happens on EVERY connection
        ▼
6. Match → SVID minted and streamed back. No match → connection refused.

**How the agent gets information**

1. Process connects to the Workload API Unix socket.
2. spire-agent calls SO_PEERCRED on that socket connection — a kernel feature that hands back the real PID/UID/GID of whoever is on the other end, unforgeable by the connecting process itself.
3. Agent reads /proc/<that-pid>/cgroup on the host — gets the cgroup path, extracts the embedded container ID.
4. Agent calls the Kubelet's local API on that node with that container ID, asking "which pod/container does this belong to?" — Kubelet answers with pod UID, namespace, service account, labels, etc. (this is the actual source of truth correlating container ID → k8s object; the cgroup path alone doesn't carry pod metadata, just the container ID).
5. Agent builds the k8s:pod-uid:... (and any other configured) selectors from that answer and matches them against registration entries.