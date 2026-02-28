# Argo CD

**GitOps continuous delivery for Kubernetes.**

Argo CD is a declarative GitOps tool that continuously monitors your Git repository and automatically syncs the desired application state to your k3s cluster. Instead of running `kubectl apply` manually, you push changes to Git and Argo CD takes care of the rest.

## Prerequisites

- A running k3s cluster ([02-K3S.md](02-K3S.md))
- MetalLB configured with an available IP pool ([03-METALLB.md](03-METALLB.md))
- Traefik ingress controller installed ([04-TRAEFIK.md](04-TRAEFIK.md))
- cert-manager with a working ClusterIssuer ([05-CERT-MANAGER.md](05-CERT-MANAGER.md))
- Wildcard TLS certificate for `*.geeklabs.dev` ([07-TRAEFIK-TLS.md](07-TRAEFIK-TLS.md))
- Helm 3 installed on your local machine

## 1. Add the Argo CD Helm Repository

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

## 2. Create the Namespace

```bash
kubectl create namespace argocd
```

## 3. Install Argo CD

Install Argo CD using the `argo/argo-cd` Helm chart. The key configuration choices:

- **Server runs in insecure mode** — TLS is terminated at Traefik, so Argo CD does not need to handle its own certificates.
- **Ingress is enabled** — using a standard Kubernetes Ingress so that external-dns automatically creates the DNS record for `argocd.geeklabs.dev`.

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set 'server.extraArgs[0]=--insecure' \
  --set 'configs.cm.url=https://argocd.geeklabs.dev'
```

> The `--insecure` flag tells the Argo CD server to serve over HTTP. This is safe because Traefik handles TLS termination in front of it using the wildcard certificate.

## 4. Expose Argo CD via Ingress

Create a standard Kubernetes Ingress to expose the Argo CD UI at `argocd.geeklabs.dev`. I use a standard Ingress (not a Traefik IngressRoute) because external-dns watches Ingress resources for hostnames and automatically creates the corresponding DNS records in TransIP.

Create the file `k3s/argocd/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - argocd.geeklabs.dev
  rules:
    - host: argocd.geeklabs.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

> The `tls` section without a `secretName` causes Traefik to use the default TLS store, which holds the `*.geeklabs.dev` wildcard certificate. The `ingressClassName: traefik` ensures Traefik picks up this Ingress, and external-dns detects the `host` field to create an A record in TransIP.

Apply it:

```bash
kubectl apply -f k3s/argocd/ingress.yaml
```

## 5. Retrieve the Initial Admin Password

Argo CD generates a random admin password during installation, stored in a Kubernetes secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Use this password to log in with the username `admin`.

## 6. Log In via the CLI (Optional)

If you have the Argo CD CLI installed:

```bash
argocd login argocd.geeklabs.dev --username admin --grpc-web
```

> The `--grpc-web` flag is required because Traefik proxies gRPC over HTTP/2, and grpc-web wraps the protocol so it works through standard HTTPS reverse proxies.

To install the CLI on macOS:

```bash
brew install argocd
```

## 7. Change the Admin Password

After your first login, change the default password:

```bash
argocd account update-password --grpc-web
```

Once you have changed the password, you can delete the initial secret:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## 8. Register Your Git Repository

Point Argo CD at your homelab repository so it can manage deployments:

```bash
argocd repo add https://github.com/<your-user>/homelab.git --grpc-web
```

For private repositories, add credentials:

```bash
argocd repo add https://github.com/<your-user>/homelab.git \
  --username <git-username> \
  --password <personal-access-token> \
  --grpc-web
```

## 9. Repository Structure

Before creating applications, it helps to understand how the repository is organized for Argo CD. This repo uses the **App of Apps** pattern — a single root Application that manages all other Applications.

```
homelab/
├── k3s/
│   ├── argocd/
│   │   ├── ingress.yaml              # Ingress for the Argo CD UI
│   │   ├── project.yaml              # AppProject — scopes permissions
│   │   └── apps/                     # Application manifests (one per service)
│   │       ├── root.yaml             # Root "App of Apps" — manages this directory
│   │       ├── hello-world.yaml      # Points to demo/
│   │       ├── metallb.yaml          # Points to k3s/metallb/
│   │       └── tls.yaml             # Points to k3s/tls/
│   ├── metallb/                      # MetalLB manifests
│   │   ├── ip-address-pool.yaml
│   │   └── l2-advertisement.yaml
│   └── tls/                          # TLS manifests
│       ├── wildcard-certificate.yaml
│       └── default-tlsstore.yaml
├── demo/                             # Demo app manifests
│   └── hello-world.yaml
└── ...
```

How it works:

1. **`project.yaml`** defines an AppProject called `homelab` that restricts which repos, clusters, and namespaces the Applications can use.
2. **`apps/root.yaml`** is the only Application you apply manually. It points at the `k3s/argocd/apps/` directory, so Argo CD automatically discovers every Application manifest in that folder.
3. **Each file in `apps/`** (e.g. `hello-world.yaml`, `metallb.yaml`) is an Application that points at a directory elsewhere in the repo containing the actual Kubernetes manifests.

To add a new service, you create its manifests in a directory (e.g. `k3s/my-service/`) and add a corresponding Application YAML in `k3s/argocd/apps/`. Push to Git and Argo CD picks it up automatically.

## 10. Create the AppProject

An AppProject scopes what the Applications are allowed to do — which repositories they can pull from, which clusters and namespaces they can deploy to, and which resource types they can create.

Create the file `k3s/argocd/project.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: homelab
  namespace: argocd
spec:
  description: Homelab applications

  sourceRepos:
    - https://github.com/<your-user>/homelab.git

  destinations:
    - name: in-cluster
      server: https://kubernetes.default.svc
      namespace: "*"

  clusterResourceWhitelist:
    - group: "*"
      kind: "*"

  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
```

Apply it:

```bash
kubectl apply -f k3s/argocd/project.yaml
```

| Field | Purpose |
|---|---|
| `sourceRepos` | Git repositories this project is allowed to use |
| `destinations` | Which clusters and namespaces applications can deploy to |
| `clusterResourceWhitelist` | Cluster-scoped resources (Namespaces, ClusterRoles, etc.) that are allowed |
| `namespaceResourceWhitelist` | Namespace-scoped resources that are allowed |

> The wildcards above are permissive — suitable for a homelab. In a shared or production environment you would restrict these to specific namespaces and resource types.

## 11. Create the Root Application (App of Apps)

The root Application watches the `k3s/argocd/apps/` directory. Any Application manifest you add there is automatically picked up and synced.

Create the file `k3s/argocd/apps/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: homelab
  source:
    repoURL: https://github.com/<your-user>/homelab.git
    targetRevision: main
    path: k3s/argocd/apps
  destination:
    name: in-cluster
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

This is the **only** Application you apply manually:

```bash
kubectl apply -f k3s/argocd/apps/root.yaml
```

From this point on, adding a new YAML file to `k3s/argocd/apps/` and pushing to Git is enough — the root Application syncs it into the cluster automatically.

## 12. Add Applications

Each service gets its own Application manifest in `k3s/argocd/apps/`. Below are examples for the services already in this repository.

### hello-world

Create the file `k3s/argocd/apps/hello-world.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-world
  namespace: argocd
spec:
  project: homelab
  source:
    repoURL: https://github.com/<your-user>/homelab.git
    targetRevision: main
    path: demo
  destination:
    name: in-cluster
    namespace: demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### metallb

Create the file `k3s/argocd/apps/metallb.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb-config
  namespace: argocd
spec:
  project: homelab
  source:
    repoURL: https://github.com/<your-user>/homelab.git
    targetRevision: main
    path: k3s/metallb
  destination:
    name: in-cluster
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### tls

Create the file `k3s/argocd/apps/tls.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tls
  namespace: argocd
spec:
  project: homelab
  source:
    repoURL: https://github.com/<your-user>/homelab.git
    targetRevision: main
    path: k3s/tls
  destination:
    name: in-cluster
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Key fields (same for all Applications):

| Field | Purpose |
|---|---|
| `project` | References the `homelab` AppProject created above |
| `source.path` | Directory in the Git repo containing the manifests |
| `destination.name` | References the cluster by its Argo CD registration name |
| `destination.namespace` | Target namespace for the resources |
| `syncPolicy.automated` | Automatically sync when Git changes are detected |
| `prune` | Delete resources removed from Git |
| `selfHeal` | Revert manual cluster changes to match Git |
| `CreateNamespace` | Create the target namespace if it does not exist |

### Adding a new service

To deploy a new service through Argo CD:

1. Create its manifests in a directory (e.g. `k3s/my-service/deployment.yaml`)
2. Create an Application manifest at `k3s/argocd/apps/my-service.yaml` pointing to that directory
3. Push to Git — the root Application picks it up automatically

## Verification

Check that all Argo CD pods are running:

```bash
kubectl -n argocd get pods
```

Expected output (all pods should be `Running`):

```
NAME                                               READY   STATUS
argocd-application-controller-0                    1/1     Running
argocd-applicationset-controller-...               1/1     Running
argocd-dex-server-...                              1/1     Running
argocd-notifications-controller-...                1/1     Running
argocd-redis-...                                   1/1     Running
argocd-repo-server-...                             1/1     Running
argocd-server-...                                  1/1     Running
```

Verify the UI is reachable:

```bash
curl -s -o /dev/null -w '%{http_code}' https://argocd.geeklabs.dev
```

Should return `200`.

## Manifests

| File | Purpose |
|---|---|
| `k3s/argocd/ingress.yaml` | Ingress exposing the Argo CD UI at `argocd.geeklabs.dev` |
| `k3s/argocd/project.yaml` | AppProject scoping permissions for homelab applications |
| `k3s/argocd/apps/root.yaml` | Root Application (App of Apps) — manages all other Applications |
| `k3s/argocd/apps/hello-world.yaml` | Application deploying the demo hello-world service |
| `k3s/argocd/apps/metallb.yaml` | Application deploying MetalLB configuration |
| `k3s/argocd/apps/tls.yaml` | Application deploying TLS certificates and default store |

## Troubleshooting

### UI returns 404 or connection refused

Check that the Ingress is correctly applied and the Argo CD server service exists:

```bash
kubectl -n argocd get ingress
kubectl -n argocd get svc argocd-server
```

### Login fails with "tls: protocol version not supported"

This happens when the Argo CD server runs with TLS enabled (the default) behind a TLS-terminating proxy. Verify the server is running with the `--insecure` flag:

```bash
kubectl -n argocd get deploy argocd-server -o yaml | grep -A5 'args:'
```

You should see `--insecure` in the args list.

### DNS not resolving for argocd.geeklabs.dev

external-dns automatically creates the DNS record when it detects the `host` field in the Ingress. If the record is not being created, check external-dns logs:

```bash
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=50
```

Common causes:
- The Ingress resource hasn't been applied yet
- external-dns pod is not running (`kubectl -n external-dns get pods`)
- TransIP API credentials are invalid or expired

### Sync fails with "permission denied"

Make sure the Git repository is accessible. Check the repo connection:

```bash
argocd repo list --grpc-web
```

If the repo shows a connection error, re-add it with correct credentials.

## Enable Kustomize Helm Rendering

By default, Kustomize cannot render Helm charts. If you want to use Kustomize to patch and render Helm charts in your Applications, you need to enable the `--enable-helm` flag globally.

This adds `--enable-helm` to every `kustomize build` that Argo CD runs. It is a global setting — it cannot be configured per Application. See the [Argo CD Kustomize docs](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/#kustomizing-helm-charts) for details.

Update the existing Helm deployment:

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --set 'server.extraArgs[0]=--insecure' \
  --set 'configs.cm.url=https://argocd.geeklabs.dev' \
  --set 'configs.cm.kustomize\.buildOptions=--enable-helm'
```

> When running `helm upgrade`, you must include all previously set values — Helm does not merge with prior `--set` flags. Omitting a value resets it to the chart default.

## Manage ArgoCD with ... ArgoCD

After you have installed argoCD in the cluster manually, you can point argoCD as an Application in the repo with the same configurations. The agent will read up the configuration and start managing it in the next refresh. Since there are no changes it would come up as synced.

I created the `Application` here: [`k3s/argocd/apps/argocd`](../k3s/argocd/apps/argocd.yaml). The actual implementation is [here](../k3s/apps/argocd/).

Because, in the meantime, I already installed [Authentik](../k3s/apps/authentik/) and configured ArgoCD to use Authentik for authn and authz. Read about it [here](https://integrations.goauthentik.io/infrastructure/argocd/).