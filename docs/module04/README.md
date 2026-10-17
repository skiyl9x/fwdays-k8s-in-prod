# Task description

## Module 04 – Service Mesh

1. Встановити Istio service mesh в режимі sidecar.

2. Створити Kyverno policy всі поди з лейблом "person: student" буде запускати з istio-sidecar контейнером

---

# Realisation

The cluster is the same single-node k3s cluster as in [Module 03](../module03/README.md).
Istio is installed with the Flux GitOps setup from Module 03: I added the manifests to
`main`, the GitHub Actions workflow rendered them into a PR to the `production`
branch, and Flux applied them after the merge.

In sidecar mode `istiod` adds an `istio-proxy` (Envoy) container to every pod
that joins the mesh. All traffic to and from the pod goes through this proxy.
A Kyverno policy adds every pod with the label `person: student` to the mesh.

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
policies/
├── base/istio-sidecar-injection/
│   ├── clusterpolicy.yaml           # ClusterPolicy inject-istio-sidecar-for-students
│   └── kustomization.yaml
└── production/istio-sidecar-injection/   # production overlay
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

`istiod` values:

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
    autoInject: disabled
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 256Mi
meshConfig:
  accessLogFile: /dev/stdout
sidecarInjectorWebhook:
  enableNamespacesByDefault: true
  reinvocationPolicy: IfNeeded
```

- `pilot.*` and `global.proxy.resources`: one replica and small requests for the single-node cluster.
- `meshConfig.accessLogFile`: the sidecars write access logs to stdout.
- `sidecarInjectorWebhook` and `global.proxy.autoInject`: every new pod is sent to the
  Istio injector, but it adds the sidecar only to pods marked with
  `sidecar.istio.io/inject: "true"`. Section 2 explains why.

The production overlay
[`infrastructure/production/controllers/istio`](../../infrastructure/production/controllers/istio)
is rendered into `infrastructure/controllers/istio.yaml` on the `production` branch
and applied by the `infra-controllers` Flux Kustomization, next to Kyverno.

Check that Istio is running:

```
flux get helmreleases -n istio-system
kubectl -n istio-system get pods
```

## 2. Kyverno policy: sidecar for students

[`policies/base/istio-sidecar-injection/clusterpolicy.yaml`](../../policies/base/istio-sidecar-injection/clusterpolicy.yaml):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-istio-sidecar-for-students
  annotations:
    pod-policies.kyverno.io/autogen-controllers: none
spec:
  rules:
    - name: add-istio-inject-annotation
      match:
        any:
          - resources:
              kinds: [Pod]
              operations: [CREATE]
              selector:
                matchLabels:
                  person: student
          - resources:
              kinds: [Pod]
              operations: [CREATE]
              namespaces: [student01, student02, student03]
      mutate:
        patchStrategicMerge:
          metadata:
            annotations:
              sidecar.istio.io/inject: "true"
```

When a pod with `person: student` is created, the policy adds the annotation
`sidecar.istio.io/inject: "true"`, and Istio adds the `istio-proxy` container.

The student namespaces are in the match as well because the `person: student`
label itself is added by the `add-person-label` policy from Module 03 in the same
request. Only pods in these namespaces can have the label, so both matches select
the same pods.

How it works together with Istio:

1. Kubernetes calls mutating webhooks in order of their configuration names, so the
   Istio injector (`istio-sidecar-injector`) runs before Kyverno
   (`kyverno-resource-mutating-webhook-cfg`). At that point the pod is not marked
   yet, so Istio doesn't inject.
2. Kyverno adds the `person: student` label and the `sidecar.istio.io/inject` annotation.
3. Because the pod changed, Kubernetes calls the Istio injector again
   (`reinvocationPolicy: IfNeeded`). Now Istio sees the annotation and adds the sidecar.

The Istio webhook is called again only if it handled the pod the first time. That's
why every pod goes to the injector (`enableNamespacesByDefault: true`), and
`autoInject: disabled` stops it from injecting into pods that aren't marked.
Kyverno sets an annotation rather than a label because the Istio webhook that
handles unmarked pods matches only pods without the `sidecar.istio.io/inject` label.

The policy is applied by the `policies` Flux Kustomization, which depends on
`infra-controllers`, so Kyverno and Istio are already installed.

Check the policy:

```
kubectl get clusterpolicy inject-istio-sidecar-for-students
```

Test with a pod in a student namespace:

```
kubectl -n student01 run httpbin --image=docker.io/kong/httpbin --port=80
kubectl -n student01 get pod httpbin --show-labels
kubectl -n student01 get pod httpbin -o jsonpath='{.spec.containers[*].name}'
```

The pod has the label `person=student`, shows `2/2` ready containers (`httpbin` and
`istio-proxy`), and the proxy logs the requests it handles:

```
kubectl -n student01 logs httpbin -c istio-proxy
```

A pod in another namespace, for example `mentor`, starts without the sidecar (`1/1`).

Delete the test pod:

```
kubectl -n student01 delete pod httpbin
```

Other pods can join the mesh by setting the label `sidecar.istio.io/inject=true` themselves.
