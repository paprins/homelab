# Setting up Traefik as Ingress Controller

Traefik is installed via Helm into its own namespace, replacing the default k3s bundled Traefik.

## Prerequisites

- A running k3s cluster with the built-in Traefik disabled (`--disable traefik`)
- `kubectl` and `helm` installed and configured

## 1. Install Traefik via Helm

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

Create the namespace and install:

```bash
kubectl create namespace traefik

helm install traefik traefik/traefik \
  --namespace traefik
```

Verify the pods are running:

```bash
kubectl get pods -n traefik
```

Verify the LoadBalancer Service got an external IP (requires MetalLB to be installed and configured — see [03-METALLB.md](03-METALLB.md)):

```bash
kubectl get svc -n traefik
```

## 2. Verify the IngressClass

Traefik's Helm chart registers an IngressClass automatically. Confirm it exists:

```bash
kubectl get ingressclass
```

You should see `traefik` listed. All Ingress resources in this cluster use `ingressClassName: traefik`.

## Next steps

After installing cert-manager ([05-CERT-MANAGER.md](05-CERT-MANAGER.md)) and external-dns ([06-EXTERNAL-DNS.md](06-EXTERNAL-DNS.md)), configure a default wildcard TLS certificate for traefik in [07-TRAEFIK-TLS.md](07-TRAEFIK-TLS.md).

## Troubleshooting

**Traefik pods not starting**

```bash
kubectl describe pods -n traefik
kubectl logs -n traefik -l app.kubernetes.io/name=traefik
```

**No external IP on the LoadBalancer Service**

k3s uses ServiceLB (formerly Klipper) by default. If the external IP stays `<pending>`, check that ServiceLB is enabled:

```bash
kubectl get pods -n kube-system -l app=svclb-traefik
```

**Ingress not routing traffic**

Verify the IngressClass exists and matches:

```bash
kubectl get ingressclass
kubectl describe ingress <name> -n <namespace>
```

Check traefik logs for routing errors:

```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50
```

## Cleanup

To remove Traefik:

```bash
helm uninstall traefik -n traefik
kubectl delete namespace traefik
```
