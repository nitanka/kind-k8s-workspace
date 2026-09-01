## kind-k8s-workspace
----------------------------------------------------------------------------------
**Goal**
1. To perform local testing of k8s cluster.
2. PoC of various tools.
3. Refining various k8s concepts by doing hands on practices


**Overview**

> This is an workspace containing the configurations to run different kind clusters

**Configuration**

1. Create the cluter configurations for k8s.
2. All the cluster configuration should be present in setup directory.
3. A sample 3 node kind setup is as follows:

```yaml
    kind: Cluster
        apiVersion: kind.x-k8s.io/v1alpha4
        nodes:
        - role: control-plane
        - role: worker
        - role: worker
 ```
4. Create the cluster

```bash
    kind create cluster --name multi-node-cluster --config 3-node.yaml
```

**Guidelines**

1. Each tool should reside in a separate directory.
2. README.md should be present for each tool.
3. Any custom changes should be present in the documentation.
    