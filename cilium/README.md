# Kind + Cilium 1.18 Lab

This lab creates a local Kubernetes cluster with **Kind** and installs **Cilium 1.18** as the primary CNI. The cluster is intentionally created without Kind's default CNI and without `kube-proxy`, so Cilium also provides Kubernetes Service handling through eBPF.

## Architecture

```text
Kind nodes
   |
   +-- Cilium CNI
   |     +-- Pod networking
   |     +-- L3/L4 NetworkPolicy
   |     +-- eBPF datapath
   |
   +-- Cilium kube-proxy replacement
         +-- ClusterIP handling
         +-- Service -> Endpoint load balancing
```

A Kubernetes Service ClusterIP is a virtual IP. With kube-proxy replacement enabled, Cilium watches Services and EndpointSlices and programs the corresponding eBPF service/load-balancer maps.

## Prerequisites

Install:

- Docker
- Kind
- kubectl
- Helm
- Cilium CLI (recommended for validation)

On macOS with Homebrew:

```bash
brew install kind kubectl helm cilium-cli
```

## 1. Create the Kind cluster

Example `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4

nodes:
  - role: control-plane
  - role: worker

networking:
  disableDefaultCNI: true
  kubeProxyMode: "none"
```

Create the cluster:

```bash
kind create cluster   --name cilium-node-cluster   --config kind-config.yaml
```

Before Cilium starts, the nodes can remain `NotReady` because no CNI has initialized pod networking yet.

```bash
kubectl get nodes
```

## 2. Add the Cilium Helm repository

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

List available 1.18 releases:

```bash
helm search repo cilium/cilium --versions | grep '1.18'
```

Pin the desired 1.18 patch release rather than relying on an unpinned chart.

## 3. Find the real Kind API-server address

Because this cluster has no kube-proxy, Cilium must be able to contact the API server before Cilium's own Service datapath is initialized.

Find the control-plane container:

```bash
docker ps --format '{{.Names}}' | grep cilium-node-cluster-control-plane
```

Get its IP:

```bash
docker inspect cilium-node-cluster-control-plane   --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

Example:

```text
192.168.97.5
```

The exact address is environment-specific and can change when the Kind cluster is recreated.

## 4. Install Cilium with Helm

Set the API-server address returned above:

```bash
helm install cilium cilium/cilium   --namespace kube-system   --version <1.18.x>   --set kubeProxyReplacement=true   --set k8sServiceHost=192.168.97.5   --set k8sServicePort=6443
```

Replace `<1.18.x>` with the patch version selected from the Helm repository and replace `192.168.97.5` with the current Kind control-plane IP.

## 5. Verify Cilium

```bash
kubectl get pods -n kube-system
```

Expected core components include:

```text
cilium-*            Running
cilium-envoy-*      Running
cilium-operator-*   Running
coredns-*           Running
```

Check the DaemonSet:

```bash
kubectl get ds -n kube-system cilium
```

Check Cilium:

```bash
cilium status --wait
```

Run the connectivity suite:

```bash
cilium connectivity test
```

## 6. Verify kube-proxy replacement

There should be no kube-proxy DaemonSet:

```bash
kubectl get ds -n kube-system kube-proxy
```

For this lab, `NotFound` is expected.

Inspect the Cilium agent:

```bash
kubectl -n kube-system exec ds/cilium --   cilium-dbg status --verbose
```

## 7. Inspect Kubernetes Service handling

Check the Kubernetes API Service:

```bash
kubectl get svc kubernetes
```

Typical output:

```text
NAME         TYPE        CLUSTER-IP   PORT(S)
kubernetes   ClusterIP   10.96.0.1    443/TCP
```

`10.96.0.1` is a Service VIP; it is not the IP of the API-server container.

Inspect Cilium's Service view:

```bash
kubectl -n kube-system exec ds/cilium --   cilium-dbg service list
```

Inspect the eBPF load-balancer maps:

```bash
kubectl -n kube-system exec ds/cilium --   cilium-dbg bpf lb list
```

Conceptually:

```text
Kubernetes Service
10.96.0.1:443
       |
       | Cilium eBPF service handling
       v
real kube-apiserver:6443
```

For an application Service:

```text
Service + EndpointSlice
          |
          v
     Cilium Agent
          |
          v
       eBPF maps
          |
          v
ClusterIP:port
          |
          v
selected PodIP:targetPort
```

EndpointSlice is control-plane information. Packets do not query EndpointSlice directly; Cilium consumes it and programs the datapath.

## Cilium and Istio

Cilium and Istio solve different problems and can be used together.

```text
Cilium
  -> Primary CNI
  -> Pod networking
  -> L3/L4 policy
  -> eBPF datapath
  -> Service handling when replacing kube-proxy

Istio
  -> Service mesh
  -> mTLS/workload identity
  -> AuthorizationPolicy
  -> L7 traffic management
```

An effective service-to-service connection must satisfy all applicable enforcement layers:

```text
Cilium ALLOW + Istio ALLOW = ALLOW
Cilium DENY  + Istio ALLOW = DENY
Cilium ALLOW + Istio DENY  = DENY
```

NetworkPolicy primarily limits network reachability and blast radius. It does not protect a backend from malicious use of an already-authorized frontend-to-backend path after the frontend itself has been compromised.
