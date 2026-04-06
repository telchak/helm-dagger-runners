# helm-dagger-runners

A Helm chart that deploys [Dagger](https://dagger.io) CI engines alongside [GitHub Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) scale sets on an existing Kubernetes cluster.

This chart is the **GitOps-compatible counterpart** of [terraform-dagger-runners](https://github.com/telchak/terraform-dagger-runners). Instead of managing Kubernetes resources imperatively via Terraform, it renders Flux `HelmRelease` CRDs so a GitOps controller (e.g. [Flux CD](https://fluxcd.io)) manages the full lifecycle declaratively.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    This Helm chart                      │
│                                                         │
│  ┌────────────────┐    ┌──────────────────────────────┐ │
│  │  Flux          │    │  ARC AutoscalingRunnerSets   │ │
│  │  HelmRelease   │    │                              │ │
│  │  (per version) │    │  dagger-v0.20.3  (exact)    │ │
│  │                │    │  dagger-v0.20    (minor)     │ │
│  │  dagger-helm   │    │  dagger-latest   (alias)     │ │
│  │  StatefulSet / │◄───│                              │ │
│  │  DaemonSet     │    │  × sizeTemplates             │ │
│  └────────────────┘    └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

Each runner pod is lightweight (~50m CPU / ~256Mi memory). All build work is offloaded to the shared Dagger engine.

## Prerequisites

| Component | Notes |
|---|---|
| Kubernetes cluster | GKE, EKS, AKS, or on-premise |
| [Flux CD](https://fluxcd.io/flux/installation/) | Manages `HelmRelease` CRDs rendered by this chart |
| [ARC controller](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller) | Install separately via its own Helm chart |
| A Flux `HelmRepository` named `dagger` | Pointing to `oci://registry.dagger.io` in the `flux-system` namespace |
| GitHub App | For ARC authentication |

## Caching Strategies

### StatefulSet + PVC (recommended)

One engine per version with a persistent volume. Survives pod restarts and node recycling. Runner pods connect to the engine via the `kube-pod://` protocol using a dedicated `ServiceAccount` and RBAC.

```yaml
engineMode: statefulset
persistentCache:
  size: "100Gi"
  storageClassName: "premium-rwo"  # SSD recommended
```

### DaemonSet + hostPath

One engine per node with ephemeral node-local cache. No RBAC required. Runner pods connect via a Unix socket mounted from the host.

```yaml
engineMode: daemonset
```

### Dagger Cloud (Magicache)

Distributed caching across runners and clusters. Compatible with both engine modes.

```yaml
daggerCloudToken: "dag_..."
```

## Installation

### 1. Install the ARC controller

```sh
helm install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --namespace arc-system \
  --create-namespace
```

### 2. Create a Flux HelmRepository for Dagger

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: dagger
  namespace: flux-system
spec:
  type: oci
  interval: 12h
  url: oci://registry.dagger.io
```

### 3. Install this chart

```sh
helm install dagger-runners . \
  --namespace dagger-runners \
  --create-namespace \
  --set github.configUrl="https://github.com/YOUR_ORG" \
  --set github.app.id="YOUR_APP_ID" \
  --set github.app.installationId="YOUR_INSTALLATION_ID" \
  --set-file github.app.privateKey=path/to/private-key.pem
```

### Using an existing GitHub App secret

If you manage the secret externally (Vault, Sealed Secrets, etc.):

```yaml
github:
  app:
    existingSecretName: "my-gh-app-secret"
```

The secret must contain:

| Key | Value |
|---|---|
| `github_app_id` | GitHub App ID |
| `github_app_installation_id` | Installation ID |
| `github_app_private_key` | PEM-encoded private key |

## Configuration Reference

### Core

| Parameter | Description | Default |
|---|---|---|
| `provider` | CI provider (`github` only currently) | `github` |
| `daggerVersions` | List of Dagger engine versions to deploy | `["0.20.3"]` |
| `engineMode` | `statefulset` or `daemonset` | `statefulset` |

### Dagger Engine

| Parameter | Description | Default |
|---|---|---|
| `engine.image.registry` | Engine image registry | `registry.dagger.io` |
| `engine.resources.requests.cpu` | Engine CPU request | `250m` |
| `engine.resources.requests.memory` | Engine memory request | `8Gi` |
| `engine.annotations` | Annotations added to the engine pod | see values.yaml |
| `daggerCloudToken` | Dagger Cloud token for Magicache | `""` |

### Persistent Cache (StatefulSet mode)

| Parameter | Description | Default |
|---|---|---|
| `persistentCache.size` | PVC size | `100Gi` |
| `persistentCache.storageClassName` | StorageClass (empty = cluster default) | `""` |
| `persistentCache.accessModes` | PVC access modes | `[ReadWriteOnce]` |

### GitHub Provider

| Parameter | Description | Default |
|---|---|---|
| `github.configUrl` | GitHub org or repo URL | `""` |
| `github.app.id` | GitHub App ID | `""` |
| `github.app.installationId` | Installation ID | `""` |
| `github.app.privateKey` | PEM private key | `""` |
| `github.app.existingSecretName` | Use a pre-existing secret | `""` |
| `github.app.secretName` | Name for the auto-created secret | `gh-app-pre-defined-secret` |

### Runner Scale Sets

| Parameter | Description | Default |
|---|---|---|
| `runner.image` | Runner container image | `ghcr.io/actions/actions-runner:latest` |
| `runner.minRunners` | Min runners per exact-version set | `18` |
| `runner.maxRunners` | Max runners per scale set | `18` |
| `runner.aliasMinRunners` | Min runners for alias sets (minor + latest) | `0` |
| `runner.sizeTemplates` | Map of size suffix → resource requests/limits | see values.yaml |

### Runner Labels

For each Dagger version in `daggerVersions`, the chart creates three `AutoscalingRunnerSet` resources:

| Label | Description |
|---|---|
| `dagger-v0.20.3` | Exact version |
| `dagger-v0.20` | Minor alias (points to latest patch in that minor) |
| `dagger-latest` | Always the highest version in the list |

Use these as `runs-on` labels in your GitHub Actions workflows:

```yaml
jobs:
  build:
    runs-on: dagger-latest
```

### Size Templates

Add multiple runner sizes by defining additional keys in `sizeTemplates`. Each key becomes a label suffix:

```yaml
runner:
  sizeTemplates:
    "":         # default, no suffix → dagger-latest
      requests:
        cpu: "50m"
        memory: "256Mi"
    large:      # suffix → dagger-latest-large
      requests:
        cpu: "100m"
        memory: "512Mi"
```

### Pod Cleanup CronJob

ARC may leave `Failed` runner pods behind. The cleanup job removes them on a schedule so ARC can recreate them.

| Parameter | Description | Default |
|---|---|---|
| `podCleanup.enabled` | Enable the cleanup CronJob | `true` |
| `podCleanup.schedule` | Cron schedule | `0 * * * *` |
| `podCleanup.successfulJobsHistoryLimit` | | `1` |
| `podCleanup.failedJobsHistoryLimit` | | `1` |

### Utility Images

| Parameter | Description | Default |
|---|---|---|
| `kubectlImage` | kubectl image for cleanup job and init containers | `bitnami/kubectl:latest` |

## Differences from terraform-dagger-runners

The Helm chart is a GitOps-first implementation of the same design. The table below lists the known feature gaps:

| Feature | Terraform | Helm chart |
|---|---|---|
| Multi-version Dagger engine | Yes | Yes |
| StatefulSet + PVC cache | Yes | Yes |
| DaemonSet + hostPath cache | Yes | Yes |
| Dagger Cloud / Magicache | Yes | Yes |
| Exact / minor / latest runner labels | Yes | Yes |
| Size templates | Yes | Yes |
| GitHub App authentication | Yes | Yes |
| External secret support | Yes | Yes |
| RBAC for kube-pod:// | Yes | Yes |
| Failed pod cleanup CronJob | Yes | Yes |
| **Vertical Pod Autoscaler (VPA)** | Yes | **No** |
| **ARC controller installation** | Yes (manages it) | **No (prerequisite)** |
| **GKE cluster provisioning** | Yes (gke/ module) | **No (out of scope)** |
| **Dual namespace** (arc-systems / arc-runners) | Yes | **No (single namespace)** |
| GitLab / other CI providers | Planned | Planned (`provider` stub exists) |
| GitOps-native (Flux HelmRelease) | No | **Yes** |

The two most impactful missing features are **VPA support** and **ARC controller management** — both are handled as external prerequisites in the Helm workflow.

## How It Works Internally

1. **`dagger-engine.yaml`** — renders one Flux `HelmRelease` per version in `daggerVersions`. Flux then pulls the upstream `dagger-helm` chart from `oci://registry.dagger.io` and deploys the engine as a StatefulSet or DaemonSet.

2. **`runner-scale-sets.yaml`** — renders `AutoscalingRunnerSet` CRs for every combination of version × size template × alias tier (exact, minor, latest). ARC picks these up and scales runner pods on demand.

3. **`rbac-dagger-engine-access.yaml`** — creates a `ServiceAccount`, `Role`, and `RoleBinding` granting runner pods `get`/`list` on pods and `create`/`get` on pod exec — the minimum permissions needed for `kube-pod://` in StatefulSet mode.

4. **`cronjob-pod-cleanup.yaml`** — hourly job that runs `kubectl delete pods --field-selector=status.phase=Failed` to keep the namespace clean.

## License

Apache 2.0 — see [LICENSE](LICENSE).
