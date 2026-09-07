# Kind + Cilium LoadBalancer Debugging Runbook

## Goal

Expose a Kubernetes `LoadBalancer` Service from a Kind cluster using
`cloud-provider-kind`, and debug the path one layer at a time.

This runbook reflects the validated setup:

``` text
macOS
  |
  | localhost:5678
  v
Docker / OrbStack port mapping
  |
  v
cloud-provider-kind Envoy
  |
  v
Kind NodePort :31976
  |
  v
Cilium
  |
  +--> 10.0.1.9:8080
  +--> 10.0.1.172:8080
```

## 1. Check the LoadBalancer Service

``` bash
kubectl get svc -n test-lb
```

Example:

``` text
NAME          TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)
foo-service   LoadBalancer   10.96.77.113   192.168.97.7   5678:31976/TCP
```

The important values are:

-   Service port: `5678`
-   NodePort: `31976`
-   ClusterIP: `10.96.77.113`
-   LoadBalancer IP: `192.168.97.7`

If `EXTERNAL-IP` remains `<pending>`, verify that `cloud-provider-kind`
is running.

## 2. Run cloud-provider-kind

Install it if required:

``` bash
go install sigs.k8s.io/cloud-provider-kind@latest
```

Run it on the host:

``` bash
sudo "$(go env GOPATH)/bin/cloud-provider-kind"
```

Keep the process running and watch the Service:

``` bash
kubectl get svc -n test-lb foo-service -w
```

## 3. Verify Pods and Endpoints

``` bash
kubectl get pods -n test-lb -o wide
kubectl get endpointslice -n test-lb
```

Validated example:

``` text
foo-app   10.0.1.9
bar-app   10.0.1.172

foo-service endpoints:
10.0.1.9:8080
10.0.1.172:8080
```

The resulting service path is:

``` text
foo-service:5678
       |
       | targetPort 8080
       |
       +--> 10.0.1.9:8080
       +--> 10.0.1.172:8080
```

If the EndpointSlice has no endpoints, compare the Service selector with
pod labels:

``` bash
kubectl describe svc -n test-lb foo-service
kubectl get pods -n test-lb --show-labels
```

## 4. Test the ClusterIP Path

Test from inside Kubernetes:

``` bash
kubectl run curl-test   -n test-lb   --image=curlimages/curl   --rm -it   --restart=Never   -- curl -v http://foo-service:5678
```

A successful `HTTP/1.1 200 OK` proves:

``` text
Pod
 |
 v
Kubernetes DNS
 |
 v
ClusterIP
 |
 v
Cilium service load balancing
 |
 v
Endpoint
 |
 v
Application
```

In the validated setup this returned:

``` text
foo-app
```

## 5. Verify Cilium Service Programming

``` bash
kubectl -n kube-system exec ds/cilium --   cilium-dbg service list
```

Validated entries:

``` text
0.0.0.0:31976/TCP       NodePort
  1 => 10.0.1.9:8080/TCP
  2 => 10.0.1.172:8080/TCP

10.96.77.113:5678/TCP   ClusterIP
  1 => 10.0.1.9:8080/TCP
  2 => 10.0.1.172:8080/TCP
```

This proves Cilium has programmed both the ClusterIP and NodePort
frontends.

Check policies as well:

``` bash
kubectl get cnp -n test-lb
kubectl get cnp -A
```

## 6. Test NodePort Directly

Get the Kind worker IP:

``` bash
docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'   cilium-node-cluster-worker
```

Validated worker IP:

``` text
192.168.97.6
```

Test the NodePort:

``` bash
curl -v http://192.168.97.6:31976
```

A successful response proves:

``` text
Mac
 |
 v
Kind worker :31976
 |
 v
Cilium NodePort
 |
 v
Application Pod :8080
```

If ClusterIP works but NodePort fails, investigate Cilium NodePort
handling before debugging `cloud-provider-kind`.

## 7. Inspect the cloud-provider-kind LoadBalancer

``` bash
docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}'
```

Validated example:

``` text
kindccm-...   envoyproxy/envoy:v1.33.2
0.0.0.0:5678->5678/tcp
0.0.0.0:32769->10000/tcp
```

The `kindccm-*` container is the Envoy LoadBalancer created by
`cloud-provider-kind`.

Useful diagnostics:

``` bash
docker inspect <kindccm-container>
docker logs <kindccm-container>
docker network inspect kind
```

## 8. macOS: Access the LB Through localhost

On macOS, do not assume that the `EXTERNAL-IP` shown by Kubernetes is
the correct host access path.

For this setup:

``` bash
curl http://192.168.97.7:5678
```

did not provide the expected application response.

But Docker showed:

``` text
0.0.0.0:5678->5678/tcp
```

Therefore the correct host test was:

``` bash
curl -v http://localhost:5678
```

This succeeded.

The working path is:

``` text
macOS localhost:5678
       |
       v
Docker / OrbStack host port
       |
       v
cloud-provider-kind Envoy :5678
       |
       v
Kind NodePort :31976
       |
       v
Cilium
       |
       v
Application Pod :8080
```

## 9. Debugging Decision Tree

``` text
LoadBalancer not working
        |
        v
EXTERNAL-IP is <pending>?
        |
    YES +--> Check cloud-provider-kind
        |
        NO
        |
        v
Does in-cluster Service curl work?
        |
     NO +--> Check pods, selectors,
        |     EndpointSlice, targetPort,
        |     application and Cilium policy
        |
       YES
        |
        v
Does NodeIP:NodePort work?
        |
     NO +--> Debug Cilium NodePort
        |
       YES
        |
        v
Does localhost:ServicePort work?
        |
     NO +--> Debug cloud-provider-kind / Envoy
        |
       YES
        |
        v
LoadBalancer path works
```

## 10. What Each Test Proves

  -----------------------------------------------------------------------
  Test                                What it proves
  ----------------------------------- -----------------------------------
  Pod IP + target port                Application is listening

  `foo-service:5678` from a pod       DNS, ClusterIP, Service and backend
                                      work

  `cilium-dbg service list`           Cilium programmed service
                                      frontends/backends

  `NodeIP:31976`                      Cilium NodePort works

  `localhost:5678`                    cloud-provider-kind and host
                                      exposure work
  -----------------------------------------------------------------------

The debugging order should therefore be:

``` text
Application
    ^
Endpoint
    ^
ClusterIP
    ^
NodePort
    ^
cloud-provider-kind
    ^
localhost
```

## 11. Using the Same Setup for Istio Ingress

An Istio ingress gateway exposed as `LoadBalancer` follows the same
lower-level path:

``` text
macOS
 |
 | localhost:80 / localhost:443
 v
cloud-provider-kind
 |
 v
Kind NodePort
 |
 v
Cilium
 |
 v
Istio Ingress Gateway
 |
 | Gateway / VirtualService
 v
Application Service
 |
 v
Application Pod + Istio sidecar
```

When debugging Istio ingress, verify the layers in this order:

1.  Application pod.
2.  Application Kubernetes Service.
3.  Istio ingress gateway pod and Service.
4.  Cilium ClusterIP/NodePort programming.
5.  Ingress gateway NodePort.
6.  `cloud-provider-kind` Envoy container.
7.  `localhost`.
8.  Istio `Gateway` and `VirtualService` routing.

This prevents an Istio configuration issue from being confused with a
Kind, Cilium, NodePort, or macOS container-networking issue.

## Quick Command Reference

``` bash
kubectl get svc -A

kubectl get pods -n test-lb -o wide

kubectl get endpointslice -n test-lb

kubectl describe svc -n test-lb foo-service

kubectl -n kube-system exec ds/cilium --   cilium-dbg service list

kubectl get cnp -A

docker inspect   -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}'   cilium-node-cluster-worker

docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}'

curl -v http://192.168.97.6:31976

curl -v http://localhost:5678
```
