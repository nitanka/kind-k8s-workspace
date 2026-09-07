**Installation of Istio using Helm**

## Install istio base

- It will install the CRDs
```bash

helm install istio-base istio/base -n istio-system --create-namespace --wait
```

## Install the istiod control plane

- It will install the control plane of Istio
```bash
$ helm install istiod istio/istiod --namespace istio-system --set --wait
```

<code style="color : red">Note: Not install in ambient mode</code>

## List the resources
```bash
helm ls -n istio-system
```

