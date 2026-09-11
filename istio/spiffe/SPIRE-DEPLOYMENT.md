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