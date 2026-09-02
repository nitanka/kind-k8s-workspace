# Cilium Debugging: API Service Timeout During Kind Bootstrap

## Problem

After installing Cilium into a Kind cluster, Cilium failed to initialize and CoreDNS remained `Pending`.

Example:

```text
NAME                               READY   STATUS
cilium-7txdg                       0/1     Init:Error
cilium-9wsmp                       0/1     Init:0/6
cilium-envoy-cx7c5                 1/1     Running
cilium-operator-*                  0/1     Running
coredns-*                          0/1     Pending
```

CoreDNS also reported scheduling failures similar to:

```text
Warning  FailedScheduling
0/2 nodes are available: 2 node(s) had untolerated taint(s).
```

## Important: CoreDNS was not the root cause

The dependency chain was:

```text
Cilium initialization fails
        |
        v
CNI is not initialized
        |
        v
Nodes remain NotReady
        |
        v
node.kubernetes.io/not-ready:NoSchedule
        |
        v
CoreDNS cannot schedule
```

Therefore, manually removing the node taint or modifying CoreDNS would hide the symptom rather than fix the networking problem.

## Cilium error

The significant Cilium error was:

```text
Error: Build config failed: failed to start:
Get "https://10.96.0.1:443/api/v1/namespaces/kube-system":
dial tcp 10.96.0.1:443: i/o timeout
```

## Investigation

### 1. Identify `10.96.0.1`

```bash
kubectl get svc kubernetes
```

Output:

```text
NAME         TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)
kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP
```

Therefore:

```text
10.96.0.1:443
```

is the Kubernetes API **Service VIP**, not the real API-server address.

### 2. Check kube-proxy

```bash
kubectl get ds -n kube-system kube-proxy
```

Result:

```text
Error from server (NotFound):
daemonsets.apps "kube-proxy" not found
```

The Kind cluster was intentionally kube-proxy-free.

### 3. Check the Cilium release values

```bash
helm get values cilium -n kube-system
```

Result:

```text
USER-SUPPLIED VALUES:
null
```

Cilium had not been given a direct API-server bootstrap address.

## Root cause

This produced a bootstrap dependency cycle.

Normally, a Service VIP such as:

```text
10.96.0.1:443
```

requires a Service dataplane implementation:

```text
Service VIP
    |
    +-- kube-proxy -> iptables/IPVS

or

Service VIP
    |
    +-- Cilium -> eBPF
```

In this cluster:

```text
kube-proxy = absent
```

and Cilium was not initialized yet.

Cilium attempted:

```text
Cilium
   |
   | access Kubernetes API
   v
10.96.0.1:443
   |
   X
Service VIP handling requires Cilium
```

This creates a chicken-and-egg problem:

```text
Cilium needs Kubernetes API
        |
        v
Cilium attempts Service VIP
        |
        v
Service VIP needs Cilium eBPF datapath
        |
        v
Cilium has not initialized
```

## Fix

Cilium must bootstrap against the **real Kind API-server endpoint**, bypassing the Kubernetes Service VIP.

### Find the control-plane IP

```bash
docker inspect cilium-node-cluster-control-plane   --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

In this incident it returned:

```text
192.168.97.5
```

The value is specific to the current Kind/Docker network and should be rediscovered after recreating the cluster.

Use:

```text
k8sServiceHost = 192.168.97.5
k8sServicePort = 6443
```

## Helm upgrade attempt and secondary error

The first attempted upgrade was:

```bash
helm upgrade cilium cilium/cilium   -n kube-system   --reuse-values   --set k8sServiceHost=192.168.97.5   --set k8sServicePort=6443
```

Helm rejected it:

```text
UPGRADE FAILED: values don't meet the specifications
of the schema(s) in the following chart(s):

cilium:
- at '/endpointPolicyUpdateTimeoutDuration':
  got null, want string
```

### Why this mattered

The existing release showed:

```text
USER-SUPPLIED VALUES:
null
```

Reusing the release values was therefore undesirable, and the resulting merged values failed the chart's schema validation for `endpointPolicyUpdateTimeoutDuration`.

Rather than trying to repair that unrelated value manually, rebuild the release configuration from the chart defaults.

## Correct upgrade

Use `--reset-values` instead of `--reuse-values`:

```bash
helm upgrade cilium cilium/cilium   --namespace kube-system   --reset-values   --set kubeProxyReplacement=true   --set k8sServiceHost=192.168.97.5   --set k8sServicePort=6443
```

If the release must remain pinned to a specific Cilium 1.18 patch, include the same chart version explicitly:

```bash
helm upgrade cilium cilium/cilium   --namespace kube-system   --version <1.18.x>   --reset-values   --set kubeProxyReplacement=true   --set k8sServiceHost=192.168.97.5   --set k8sServicePort=6443
```

## Expected bootstrap after the fix

```text
Cilium starts
      |
      | direct API connection
      v
192.168.97.5:6443
      |
      v
kube-apiserver
      |
      | watch Service + EndpointSlice
      v
Cilium Agent
      |
      | program eBPF service maps
      v
10.96.0.1:443 becomes functional
```

The direct API endpoint breaks the bootstrap dependency cycle.

## Validate recovery

### Cilium pods

```bash
kubectl get pods -n kube-system
```

### Nodes

```bash
kubectl get nodes
```

Expected:

```text
NotReady
   |
   | Cilium initializes CNI
   v
Ready
```

The `node.kubernetes.io/not-ready` taint should then disappear automatically.

### CoreDNS

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

Expected:

```text
Pending -> Running
```

### Cilium

```bash
cilium status --wait
```

### Connectivity

```bash
cilium connectivity test
```

## Inspect the Service mapping

Once Cilium is healthy:

```bash
kubectl -n kube-system exec ds/cilium --   cilium-dbg service list
```

Look for the Kubernetes Service:

```text
10.96.0.1:443
```

Then inspect the lower-level eBPF load-balancer maps:

```bash
kubectl -n kube-system exec ds/cilium --   cilium-dbg bpf lb list
```

The conceptual mapping is:

```text
10.96.0.1:443
      |
      | eBPF Service load balancing
      v
real kube-apiserver:6443
```

## Debugging checklist

When Cilium fails to initialize in a kube-proxy-free Kind cluster, check in this order:

```bash
kubectl get nodes
kubectl get pods -n kube-system
kubectl describe pod -n kube-system <cilium-pod>
kubectl logs -n kube-system <cilium-pod> --all-containers=true --prefix
kubectl get svc kubernetes
kubectl get ds -n kube-system kube-proxy
helm get values cilium -n kube-system
```

If Cilium is trying to reach the Kubernetes API through the Service ClusterIP before its own Service datapath is available, inspect the direct API-server address and the Cilium Helm values:

```bash
docker inspect cilium-node-cluster-control-plane   --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

helm get values cilium -n kube-system
```

## Key lesson

Do not debug this as a CoreDNS scheduling problem first.

The causal path was:

```text
API Service VIP unreachable
        |
        v
Cilium initialization failure
        |
        v
CNI unavailable
        |
        v
Nodes NotReady
        |
        v
NoSchedule taint
        |
        v
CoreDNS Pending
```

Fixing the earliest failure in that chain restores the downstream components.
