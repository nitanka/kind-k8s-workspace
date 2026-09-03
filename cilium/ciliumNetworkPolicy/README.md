**Testing Policies**

## Manifest Location
- `cilim/manifests`

## Start the hubble ui
```bash
cilium hubble ui
```

## Apply the manifests
```bash
kubectl apply -f <manifest-file>
```

## Test different connectivity
```bash
#Setting Backend POD Name
BACKEND=$(kubectl get pod -n cilium-test \
  -l app=backend \
  -o jsonpath='{.items[0].metadata.name}')

#Setting Frontend POD Name
FRONTEND=$(kubectl get pod -n cilium-test \
  -l app=frontend \
  -o jsonpath='{.items[0].metadata.name}')

#Setting Database POD Name
DATABASE=$(kubectl get pod -n cilium-test \
  -l app=database \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n cilium-test http://backend -- \
  curl -s --connect-timeout 2 http://database
error: arguments in resource/name form may not have more than one slash

kubectl exec -n cilium-test $BACKEND -- \
  curl -s --connect-timeout 2 http://database
command terminated with exit code 28

kubectl exec -n cilium-test $BACKEND -- \
curl -s --connect-timeout 2 http://database
```
<code style="color : red">
The above snippet are examples, the command will vary depending on the tests
</code>
