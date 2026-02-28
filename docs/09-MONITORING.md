# Monitoring (kube-prometheus-stack)

**Cluster observability with Prometheus, Grafana, and Alertmanager.**

The [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm chart deploys a complete monitoring pipeline in a single install: Prometheus for metrics collection, Grafana for dashboards, Alertmanager for alert routing, plus node-exporter and kube-state-metrics for cluster and node metrics.

All components are tuned for Raspberry Pi resource constraints.

## Prerequisites

- A running k3s cluster ([02-K3S.md](02-K3S.md))
- Argo CD with Kustomize Helm rendering enabled ([08-ARGOCD.md](08-ARGOCD.md))
- Traefik ingress controller with wildcard TLS ([07-TRAEFIK-TLS.md](07-TRAEFIK-TLS.md))
- Sealed Secrets controller installed ([20-SEALED-SECRETS.md](20-SEALED-SECRETS.md))
- Authentik configured as IdP (optional, for SSO login to Grafana)

## What gets deployed

The chart installs the following components into the `monitoring` namespace:

| Component | Purpose | Resource budget |
|---|---|---|
| **Prometheus** | Scrapes and stores time-series metrics | 100m CPU, 512Mi–1536Mi memory, 10Gi PVC |
| **Grafana** | Dashboards and visualization | 50m CPU, 128Mi–256Mi memory |
| **Alertmanager** | Alert routing and grouping | 10m CPU, 32Mi–64Mi memory |
| **node-exporter** | Per-node hardware and OS metrics (DaemonSet) | 10m CPU, 16Mi–32Mi memory |
| **kube-state-metrics** | Kubernetes object state metrics | 10m CPU, 32Mi–64Mi memory |

## 1. Directory structure

The monitoring stack follows the same Kustomize + Helm pattern used for other apps:

```
k3s/
├── apps/
│   └── monitoring/
│       ├── kustomization.yaml   # Pulls the Helm chart
│       ├── values.yaml          # Helm values (all config lives here)
│       └── secrets.yaml         # SealedSecrets for Grafana credentials
└── argocd/
    └── apps/
        └── monitoring.yaml      # ArgoCD Application manifest
```

## 2. ArgoCD Application

The monitoring stack is deployed via the App of Apps pattern. The Application manifest at `k3s/argocd/apps/monitoring.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
spec:
  project: homelab
  source:
    repoURL: https://github.com/paprins/homelab.git
    targetRevision: main
    path: k3s/apps/monitoring
  destination:
    name: in-cluster
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

`ServerSideApply` is required because the kube-prometheus-stack CRDs are large and exceed the annotation size limit used by client-side apply.

## 3. Kustomization

The `kustomization.yaml` pulls the Helm chart and injects the sealed secrets:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

resources:
  - secrets.yaml

helmCharts:
  - name: kube-prometheus-stack
    version: 82.4.3
    repo: https://prometheus-community.github.io/helm-charts
    releaseName: kube-prometheus-stack
    includeCRDs: true
    valuesFile: values.yaml
```

## 4. Helm values — k3s adaptations

k3s bundles the control-plane components differently than upstream Kubernetes. The kube-controller-manager, kube-scheduler, kube-proxy, and etcd are either embedded or absent, so their ServiceMonitors must be disabled to avoid scrape target errors:

```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
kubeEtcd:
  enabled: false
```

## 5. Prometheus configuration

Prometheus is configured for a homelab workload — short retention, modest storage, and relaxed scrape intervals to reduce load on the Pi nodes:

```yaml
prometheus:
  prometheusSpec:
    retention: 7d
    retentionSize: "5GB"
    scrapeInterval: 60s
    evaluationInterval: 60s
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
```

### Cross-namespace ServiceMonitor discovery

By default, Prometheus only picks up ServiceMonitors from its own namespace. To discover monitors from other namespaces (e.g. the `trivy-system` namespace for Trivy Operator metrics), the `nilUsesHelmValues` flags are set to `false`:

```yaml
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
```

This tells Prometheus to select all ServiceMonitors, PodMonitors, and PrometheusRules across all namespaces regardless of labels.

## 6. Grafana configuration

### Ingress

Grafana is exposed at `https://grafana.geeklabs.dev` via Traefik, using the wildcard TLS certificate:

```yaml
grafana:
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
      - grafana.geeklabs.dev
    tls:
      - hosts:
          - grafana.geeklabs.dev
```

### Admin credentials

The admin username and password are stored in a SealedSecret called `grafana-admin-credentials` and referenced via `existingSecret`:

```yaml
  admin:
    existingSecret: grafana-admin-credentials
    userKey: admin_user
    passwordKey: admin_password
```

### Authentik OIDC integration

Grafana is configured for single sign-on via Authentik's OAuth2/OIDC provider. Users are automatically redirected to Authentik for login, and roles are assigned based on Authentik group membership:

| Authentik group | Grafana role |
|---|---|
| `Grafana Admins` | Admin |
| `Grafana Editors` | Editor |
| *(any other user)* | Viewer |

The OAuth client ID and secret are stored in a separate SealedSecret (`grafana-oauth-secrets`) and mounted into the Grafana pod as files:

```yaml
  extraSecretMounts:
    - name: grafana-oauth-secrets
      secretName: grafana-oauth-secrets
      defaultMode: 0440
      mountPath: /etc/secrets/grafana-oauth-secrets
      readOnly: true
```

Grafana reads the credentials from the mounted files using the `$__file{...}` syntax:

```yaml
  grafana.ini:
    auth.generic_oauth:
      name: authentik
      enabled: true
      client_id: $__file{/etc/secrets/grafana-oauth-secrets/clientId}
      client_secret: $__file{/etc/secrets/grafana-oauth-secrets/clientSecret}
      scopes: "openid profile email"
      auth_url: "https://auth.geeklabs.dev/application/o/authorize/"
      token_url: "https://auth.geeklabs.dev/application/o/token/"
      api_url: "https://auth.geeklabs.dev/application/o/userinfo/"
      role_attribute_path: "contains(groups, 'Grafana Admins') && 'Admin' || contains(groups, 'Grafana Editors') && 'Editor' || 'Viewer'"
```

> To configure the Authentik side, create an OAuth2/OpenID Provider and Application in Authentik. See the [Authentik Grafana integration docs](https://docs.goauthentik.io/integrations/services/grafana/).

### Dashboard sidecar

The Grafana sidecar watches for ConfigMaps with dashboards across all namespaces. Any service can ship its own dashboard by creating a ConfigMap with the appropriate label:

```yaml
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
```

## 7. Secrets

Two SealedSecrets are defined in `secrets.yaml`:

| Secret name | Keys | Used by |
|---|---|---|
| `grafana-admin-credentials` | `admin_user`, `admin_password` | Grafana admin login |
| `grafana-oauth-secrets` | `clientId`, `clientSecret` | Grafana → Authentik OIDC |

To create or rotate these secrets, encrypt them with `kubeseal` (see [20-SEALED-SECRETS.md](20-SEALED-SECRETS.md)):

```bash
# Example: create the admin credentials secret
kubectl create secret generic grafana-admin-credentials \
  --namespace monitoring \
  --from-literal=admin_user=admin \
  --from-literal=admin_password='<your-password>' \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace kube-system -o yaml
```

Next, paste the result in `k3s/apps/monitoring/secrets.yaml`

## Verification

Check that all monitoring pods are running:

```bash
kubectl -n monitoring get pods
```

Expected output:

```
NAME                                                     READY   STATUS
kube-prometheus-stack-grafana-...                         3/3     Running
kube-prometheus-stack-kube-state-metrics-...              1/1     Running
kube-prometheus-stack-operator-...                        1/1     Running
kube-prometheus-stack-prometheus-node-exporter-...        1/1     Running  (one per node)
alertmanager-kube-prometheus-stack-alertmanager-0         2/2     Running
prometheus-kube-prometheus-stack-prometheus-0             2/2     Running
```

Verify Grafana is reachable:

```bash
curl -s -o /dev/null -w '%{http_code}' https://grafana.geeklabs.dev
```

Should return `200` (or `302` if OAuth redirect is active).

Check Prometheus targets:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Then open http://localhost:9090/targets in your browser
```

All targets should show as `UP`. The disabled k3s components (controller-manager, scheduler, proxy, etcd) will not appear.

## Manifests

| File | Purpose |
|---|---|
| `k3s/apps/monitoring/kustomization.yaml` | Kustomization pulling the Helm chart |
| `k3s/apps/monitoring/values.yaml` | Helm values for all components |
| `k3s/apps/monitoring/secrets.yaml` | SealedSecrets for Grafana credentials |
| `k3s/argocd/apps/monitoring.yaml` | ArgoCD Application manifest |

## Adding custom dashboards

To add a Grafana dashboard for a service, create a ConfigMap with the `grafana_dashboard` label in any namespace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-service-dashboard
  namespace: my-namespace
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    { ... Grafana dashboard JSON ... }
```

The sidecar picks it up automatically — no restart needed.

## Next steps

- **Loki + Promtail** — Add log aggregation alongside metrics. Loki integrates natively with Grafana as a data source. See [100-RECOMMENDATIONS.md](100-RECOMMENDATIONS.md).
- **Alert rules and receivers** — Configure Alertmanager with notification channels (Slack, email, Telegram) and add PrometheusRule resources for alerts.
- **Custom ServiceMonitors** — Expose metrics from your own services and create ServiceMonitor resources for Prometheus to scrape them.
