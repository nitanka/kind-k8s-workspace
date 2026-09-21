## Install Helm

1. Install Helm Chart
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
# List the available releases
helm search repo hashicorp/vault -l
helm install vault hashicorp/vault --version 0.34.1 -n vault --create-namespace
```

<code style="color : red">Note: Installing in Standalone Mode</code>
The pods will be deployed but it will not be in a ready state

2. Get the initialise key
```bash
kubectl get pods -l app.kubernetes.io/name=vault -n vault
kubectl -n vault exec -ti vault-0 -- vault operator init
```

3. Unseal the vault with the keys obtained
```bash
## Unseal the first vault server until it reaches the key threshold
kubectl exec -ti vault-0 -- vault operator unseal # ... Unseal Key 1
kubectl exec -ti vault-0 -- vault operator unseal # ... Unseal Key 2
kubectl exec -ti vault-0 -- vault operator unseal # ... Unseal Key 3
```
