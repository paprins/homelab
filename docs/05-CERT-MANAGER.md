# cert-manager with TransIP DNS-01 on k3s

Automated TLS certificates from Let's Encrypt using DNS-01 validation via the TransIP DNS API.

## Prerequisites

- A running k3s cluster
- `traefik` ingress controller installed
- `kubectl` and `helm` installed and configured
- A domain managed by TransIP (e.g. `geeklabs.dev`)
- A TransIP API private key (generate one in the TransIP control panel under API)

## 1. Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

Verify the pods are running:

```bash
kubectl get pods -n cert-manager
```

## 2. Install the TransIP webhook solver

```bash
helm repo add cert-manager-webhook-transip https://demeester.dev/cert-manager-webhook-transip
helm repo update

helm install cert-manager-webhook-transip \
  cert-manager-webhook-transip/cert-manager-webhook-transip \
  --namespace cert-manager
```

Verify the webhook pod is running:

```bash
kubectl get pods -n cert-manager -l app=cert-manager-webhook-transip
```

## 3. Create the TransIP API secret

Store your TransIP private key as a Kubernetes secret in the `cert-manager` namespace:

```bash
kubectl create secret generic transip-secret \
  --namespace cert-manager \
  --from-file=transip.key=transip.key
```

## 4. Create the ClusterIssuer

Apply `transip-clusterissuer.yaml`:

> Update `YOUR_EMAIL` and `YOUR_ACCOUNTNAME` with your details!

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-issuer-dns01
  namespace: cert-manager
spec:
  acme:
    email: YOUR_EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-issuer-dns01
    solvers:
      - dns01:
          webhook:
            groupName: acme.transip.nl
            solverName: transip
            config:
              accountName: YOUR_ACCOUNTNAME
              ttl: 300
              privateKeySecretRef:
                name: transip-secret
                key: transip.key
```

```bash
kubectl apply -f transip-clusterissuer.yaml
```

Verify it registered with Let's Encrypt:

```bash
kubectl get clusterissuer letsencrypt-issuer-dns01
# STATUS should be Ready=True
```

## 5. Request a Certificate

Create a Certificate resource in whatever namespace needs it. Example (`demo/certificate.yaml`):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-cert
  namespace: demo
spec:
  secretName: demo-tls
  issuerRef:
    name: letsencrypt-issuer-dns01
    kind: ClusterIssuer
  dnsNames:
    - demo.geeklabs.dev
```

```bash
kubectl create namespace demo
kubectl apply -f demo/certificate.yaml
```

## 6. Monitor certificate issuance

The DNS-01 flow creates a TXT record at `_acme-challenge.<domain>` via the TransIP API, waits for it to propagate, then Let's Encrypt validates it. This typically takes 2-10 minutes.

```bash
# Watch certificate status
kubectl get certificate -n demo -w

# Check the ACME order and challenge progress
kubectl get order -n demo
kubectl get challenge -n demo

# Verify the TXT record is propagating
dig TXT _acme-challenge.demo.geeklabs.dev

# Check webhook logs if something seems stuck
kubectl logs -n cert-manager -l app=cert-manager-webhook-transip

# Check cert-manager controller logs
kubectl logs -n cert-manager -l app=cert-manager --tail=50
```

Once `READY` is `True`, the TLS certificate is stored in the secret (e.g. `demo-tls`).

## 7. Test with a demo application (optional)

Deploy a simple whoami app with an Ingress that uses the certificate.

`demo/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:latest
          ports:
            - containerPort: 80
```

`demo/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo
spec:
  selector:
    app: demo-app
  ports:
    - port: 80
      targetPort: 80
```

`demo/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-app
  namespace: demo
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - demo.geeklabs.dev
      secretName: demo-tls
  rules:
    - host: demo.geeklabs.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo-app
                port:
                  number: 80
```

```bash
kubectl apply -f demo/
curl -v https://demo.geeklabs.dev
```

The response should show the whoami output and `curl -v` should confirm a valid Let's Encrypt certificate.

## Wildcard certificates

DNS-01 is the only ACME challenge type that supports wildcard certificates. The TransIP webhook setup works with wildcards out of the box — no changes to the ClusterIssuer needed.

### Why use wildcards

Per-subdomain certificates each require a DNS-01 challenge, which takes 2-10 minutes to complete. With a wildcard certificate you go through that process once and reuse the same certificate for all subdomains. Renewal happens automatically every ~60 days.

### Trade-offs

| | Wildcard | Per-subdomain |
|---|---|---|
| Issuance wait | Once | Every new subdomain |
| Blast radius | One leaked key exposes all subdomains | Limited to one subdomain |
| Management | Single secret, shared across namespaces | One secret per namespace, automatic |
| Renewal | One renewal to monitor | Many, but cert-manager handles it |

For a homelab the blast radius concern is negligible — the convenience of a single wildcard cert is worth it.

### Subdomain wildcards

Wildcards work at any single level, not just the top. You can issue certificates for:

- `*.geeklabs.dev` — covers `foo.geeklabs.dev`, `bar.geeklabs.dev`, etc.
- `*.foo.geeklabs.dev` — covers `app.foo.geeklabs.dev`, `api.foo.geeklabs.dev`, etc.

Each wildcard triggers its own DNS-01 challenge (TXT record at `_acme-challenge.foo.geeklabs.dev`, etc.).

**Limitation:** wildcards only cover a single level. `*.geeklabs.dev` covers `foo.geeklabs.dev` but **not** `app.foo.geeklabs.dev`. To cover both you need both patterns in the certificate.

### Example wildcard Certificate

A single certificate can combine multiple wildcard patterns:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-geeklabs-dev
  namespace: cert-manager
spec:
  secretName: wildcard-geeklabs-dev-tls
  issuerRef:
    name: letsencrypt-issuer-dns01
    kind: ClusterIssuer
  dnsNames:
    - "*.geeklabs.dev"
    - "*.foo.geeklabs.dev"
    - "*.bar.geeklabs.dev"
```

This issues one cert covering all three patterns, though cert-manager runs a DNS-01 challenge for each entry.

### Sharing the wildcard certificate across namespaces

The wildcard certificate Secret lives in a single namespace. Without extra steps, Ingresses in other namespaces cannot reference it. There are a few approaches:

1. **Traefik default TLSStore (recommended)** — Store the wildcard certificate in the `traefik` namespace and configure a Traefik TLSStore named `default` that references it. Traefik then serves this certificate automatically for any Ingress that has a `tls` section — no `secretName` needed, no cross-namespace copying. This is the approach I use. See [07-TRAEFIK-TLS.md](07-TRAEFIK-TLS.md) for the setup.

2. **Create a Certificate resource in each namespace** — cert-manager issues a separate cert per Certificate resource. Works, but each one triggers its own DNS-01 challenge (2-10 min wait).

3. **Use a secret reflector** like [reflector](https://github.com/emberstack/kubernetes-reflector) to automatically sync the Secret across namespaces. More moving parts than option 1.

For a homelab, option 1 is the simplest by far — one certificate, one TLSStore, and every Ingress just works.

## Troubleshooting

**Challenge stuck in pending / propagation check fails**

The TransIP API may accept the record but DNS propagation can be slow. Check if the TXT record is visible:

```bash
dig TXT _acme-challenge.demo.geeklabs.dev @ns0.transip.net
dig TXT _acme-challenge.demo.geeklabs.dev @8.8.8.8
```

If the record exists at the authoritative NS but cert-manager doesn't see it, it may be a timing issue. cert-manager retries automatically.

**ClusterIssuer not ready**

```bash
kubectl describe clusterissuer letsencrypt-issuer-dns01
```

Common causes: wrong email, TransIP secret not found, webhook not running.

**Webhook logs show errors**

```bash
kubectl logs -n cert-manager -l app=cert-manager-webhook-transip
```

Common causes: invalid TransIP API key, wrong account name, domain not in TransIP account.

## Cleanup

To remove the demo resources:

```bash
kubectl delete -f demo/
kubectl delete namespace demo --force
```

To remove cert-manager entirely:

```bash
helm uninstall cert-manager-webhook-transip -n cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
```
