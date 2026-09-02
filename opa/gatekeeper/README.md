# OPA Gatekeeper Policies

This directory contains Kubernetes admission-control policies and
mutations implemented with **OPA Gatekeeper**.

**AI Generated README**

## Compatibility

  Component                  Version / API
  -------------------------- -------------------------------------
  Gatekeeper                 **v3.23.1**
  ConstraintTemplate API     `templates.gatekeeper.sh/v1`
  Constraint API             `constraints.gatekeeper.sh/v1beta1`
  Mutation API               `mutations.gatekeeper.sh/v1`
  Rego in `targets[].rego`   Legacy Gatekeeper Rego syntax

> The API versions above reflect the Gatekeeper setup this repository
> has been developed and tested against. Verify the served CRD versions
> when using a different Gatekeeper release.

Useful checks:

``` bash
kubectl get deployment -n gatekeeper-system gatekeeper-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

kubectl get crd constrainttemplates.templates.gatekeeper.sh \
  -o jsonpath='{.spec.versions[*].name}{"\n"}'
```

## Repository Structure

``` text
.
├── constraints/
│   └── *-constraint.yaml
├── constraint_templates/
│   └── *.yaml
└── mutations/
    └── *.yaml
```

-   **ConstraintTemplates** define reusable policy logic and the
    parameter schema.
-   **Constraints** instantiate a template, select the Kubernetes
    resources to which it applies, and provide parameters.
-   **Mutations** modify matching Kubernetes objects during admission.

## Supported Validation Policies

  -----------------------------------------------------------------------
  Policy                  Purpose                 Typical Resources
  ----------------------- ----------------------- -----------------------
  Missing / Required      Requires configured     Pod, Deployment,
  Labels                  labels such as          Namespace
                          `maintainer`            

  Maximum Replicas        Prevents Deployments    Deployment
                          from exceeding a        
                          configured replica      
                          count                   

  Namespace Name          Enforces namespace      Namespace
                          naming/prefix           
                          conventions             

  Image Repository        Restricts container     Deployment
                          images to approved      
                          registries such as      
                          `docker.io/`,           
                          `quay.io/`, and         
                          `ghcr.io/`              

  NodePort Check          Enforces configured     Service
                          NodePort restrictions   

  Readiness Probe         Requires containers to  Deployment
                          define a readiness      
                          probe                   

  Resource Limits         Requires container      Deployment
                          resource limits such as 
                          CPU and memory          

  Image Tag               Denies container        Deployment, Pod
                          images tagged           
                          `latest`                

  Resource Request/Limit  Requires CPU and        Deployment, Pod
  Ratio                   memory requests and     
                          limits to be set, and   
                          keeps the limit:request 
                          ratio between 1 and 2   

  Security Context        Requires a              Deployment, Pod
                          `securityContext` that  
                          sets                    
                          `allowPrivilegeEscalation:
                          false` and              
                          `runAsNonRoot: true`     
  -----------------------------------------------------------------------

### Gatekeeper validation contract

ConstraintTemplate Rego must expose the Gatekeeper-required `violation`
rule.

Example:

``` rego
violation[{"msg": msg}] {
    container := input.review.object.spec.template.spec.containers[_]
    not container.readinessProbe

    msg := sprintf(
        "Readiness probe missing for container %s",
        [container.name]
    )
}
```

`violation` is not a general Rego keyword, but it is the rule Gatekeeper
expects from a Rego-based ConstraintTemplate.

## Supported Mutations

### AssignMetadata

Used to add metadata such as cluster labels to admitted resources.

API:

``` yaml
apiVersion: mutations.gatekeeper.sh/v1
kind: AssignMetadata
```

Example use cases:

-   Add `cluster=<cluster-name>` to Pods.
-   Add standard labels or annotations to matching resources.
-   Label newly created Namespace objects using a separate
    cluster-scoped mutator.
-   Enable Istio sidecar injection on new Namespaces by setting
    `istio-injection: enabled`.

`AssignMetadata` does not require `applyTo`.

### Assign

Used to modify non-metadata fields on supported Kubernetes resources.

API:

``` yaml
apiVersion: mutations.gatekeeper.sh/v1
kind: Assign
```

Current use case:

-   Set `spec.serviceAccountName` for directly created Pods.
-   Set `spec.template.spec.serviceAccountName` for Deployments.
-   Default `imagePullPolicy` to `Always` for containers on Pods and
    Deployments when not already set.

`Assign` requires `applyTo` so Gatekeeper knows the exact
Group/Version/Kind schema being mutated.

> Mutation changes an admitted object; it does not create a separate
> Kubernetes resource. For example, assigning `serviceAccountName` does
> not create the corresponding ServiceAccount.

## Scope and Matching

Use `scope: Namespaced` for resources such as:

-   Pod
-   Deployment
-   StatefulSet
-   DaemonSet
-   Service

Use `scope: Cluster` for cluster-scoped resources such as:

-   Namespace

Example:

``` yaml
spec:
  match:
    scope: Namespaced
    excludedNamespaces:
      - kube-system
      - kube-public
      - gatekeeper-system
      - kyverno
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
```

Common API groups:

  Resource      API Group
  ------------- -----------
  Pod           `""`
  Service       `""`
  Namespace     `""`
  Deployment    `"apps"`
  StatefulSet   `"apps"`
  DaemonSet     `"apps"`

## Applying Policies

Apply ConstraintTemplates before their Constraints:

``` bash
kubectl apply -f constraint_templates/
kubectl apply -f constraints/
```

Apply mutations separately:

``` bash
kubectl apply -f mutations/
```

Verify templates:

``` bash
kubectl get constrainttemplates
```

A template should report:

``` yaml
status:
  created: true
```

If the generated Constraint CRD is missing, inspect the template:

``` bash
kubectl get constrainttemplate <template-name> -o yaml
```

Look under `status.byPod.errors` for Rego ingestion or schema errors.

List Gatekeeper Constraints:

``` bash
kubectl get constraints
```

Or inspect a specific generated Constraint type:

``` bash
kubectl get <constraint-kind>
```

List mutations:

``` bash
kubectl get assign
kubectl get assignmetadata
```

## Rego Version Note

The ConstraintTemplates in this repository use the `targets[].rego` form
and therefore use the Rego syntax supported by that Gatekeeper ingestion
path.

For example:

``` rego
violation[{"msg": msg}] {
    container := input.review.object.spec.template.spec.containers[_]
    not container.readinessProbe
}
```

Do not replace this blindly with Rego v1 syntax such as:

``` rego
violation contains {"msg": msg} if {
    ...
}
```

unless the ConstraintTemplate is explicitly configured for a Rego
v1-capable policy source.

## Validation and Testing

Do not run:

``` bash
opa test . -v
```

against the repository root when it contains multiple Kubernetes YAML
manifests. OPA may try to load those YAML files as data and produce
merge errors.

For Gatekeeper manifests, validation should cover:

1.  YAML/schema correctness.
2.  Embedded Rego parsing/checking.
3.  ConstraintTemplate ingestion by Gatekeeper.
4.  Generated Constraint CRD creation.
5.  Constraint creation and parameter validation.
6.  Admission behavior in a test cluster.

A Kind cluster with Gatekeeper is recommended for integration testing.

## Important Notes

-   Constraints and ConstraintTemplates are separate resources.
-   A ConstraintTemplate defines the policy type; a Constraint
    configures where and how it applies.
-   Constraint parameters are available to Rego through
    `input.parameters`.
-   The Kubernetes object under evaluation is available through
    `input.review.object`.
-   `excludedNamespaces` can exclude system namespaces from namespaced
    policies.
-   Mutation is admission-time behavior and is not retroactive to
    existing resources.
-   Gatekeeper mutation cannot generate unrelated Kubernetes resources
    such as ResourceQuota, NetworkPolicy, or ServiceAccount objects.
