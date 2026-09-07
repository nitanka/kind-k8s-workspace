## Installation of Istio using Helm**

**Install istio base**

- It will install the CRDs
```bash

helm install istio-base istio/base -n istio-system --create-namespace --wait
```

**Install the istiod control plane**

- It will install the control plane of Istio
```bash
$ helm install istiod istio/istiod --namespace istio-system --set --wait
```

<code style="color : red">Note: Not install in ambient mode</code>

**List the resources**
```bash
helm ls -n istio-system
```

**List gateways**
```bash
kubectl get gateways.networking.istio.io
```

**Enable kind Loadbalancer**
```bash
sudo ~/go/bin/cloud-provider-kind
```

**Nginx Setup**
- We are using the nginx for cdn redirection.
- nginx.conf is present in the nginx directory.
- start the docker process
```bash
docker run \                                
  --name cdn-poc \
  --rm \
  -p 8080:8080 \
-v ./nginx.conf:/etc/nginx/nginx.conf:ro \
nginx:alpine
```