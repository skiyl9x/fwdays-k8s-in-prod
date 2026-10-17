# Task description

## Module 04 – Service Mesh

1. Встановити Istio service mesh в режимі sidecar.

---

# Realisation

The cluster is the same single-node k3s cluster as in [Module 03](../module03/README.md).
Istio is installed with the Flux GitOps setup from Module 03: I added the manifests to
`main`, the GitHub Actions workflow rendered them into a PR to the `production`
branch, and Flux applied them after the merge.

In sidecar mode `istiod` adds an `istio-proxy` (Envoy) container to every pod
that joins the mesh. All traffic to and from the pod goes through this proxy.

## Repository layout

```
infrastructure/
├── base/controllers/istio/
│   ├── namespace.yaml               # istio-system
│   ├── helmrepo.yaml                # HelmRepository with the official Istio charts
│   ├── helmrelease-base.yaml        # HelmRelease istio-base: Istio CRDs
│   ├── helmrelease-istiod.yaml      # HelmRelease istiod: control plane and sidecar injector
│   └── kustomization.yaml
└── production/controllers/istio/    # production overlay
    └── kustomization.yaml
```

## 1. Install Istio

Istio is installed from the official Helm charts
(`https://istio-release.storage.googleapis.com/charts`), version `1.30.6`, as two
Flux `HelmRelease`s in the `istio-system` namespace:

| HelmRelease | Chart | Purpose |
|---|---|---|
| [`istio-base`](../../infrastructure/base/controllers/istio/helmrelease-base.yaml) | `base` | Istio CRDs |
| [`istiod`](../../infrastructure/base/controllers/istio/helmrelease-istiod.yaml) | `istiod` | Control plane and the webhook that injects sidecars |

`istiod` has `dependsOn: istio-base`, so Flux installs it only after the CRDs exist.

`istiod` values for the single-node cluster:

```yaml
pilot:
  autoscaleEnabled: false
  replicaCount: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
global:
  proxy:
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 256Mi
meshConfig:
  accessLogFile: /dev/stdout
```

The production overlay
[`infrastructure/production/controllers/istio`](../../infrastructure/production/controllers/istio)
is rendered into `infrastructure/controllers/istio.yaml` on the `production` branch
and applied by the `infra-controllers` Flux Kustomization, next to Kyverno.

Check that Istio is running:

```
flux get helmreleases -n istio-system
kubectl -n istio-system get pods
```

## 2. Add a workload to the mesh

The sidecar is injected only into pods that opt in. To add a whole namespace to
the mesh, label it:

```
kubectl label namespace <namespace> istio-injection=enabled
```

To add a single pod, give it the label `sidecar.istio.io/inject=true`.

Test pod:

```
kubectl run httpbin --image=docker.io/kong/httpbin --port=80 --labels=sidecar.istio.io/inject=true
kubectl get pod httpbin
kubectl get pod httpbin -o jsonpath='{.spec.containers[*].name}'
```

The pod shows `2/2` ready containers: `httpbin` and `istio-proxy`. The proxy
logs the requests it handles:

```
kubectl logs httpbin -c istio-proxy
```

Delete the test pod:

```
kubectl delete pod httpbin
```
