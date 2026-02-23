# Default wildcard TLS certificate for Traefik

Configure traefik with a default wildcard certificate for `*.geeklabs.dev` so that any Ingress with TLS enabled automatically gets a valid certificate without having to specify a `secretName`.

## Prerequisites

- Traefik installed and running ([04-TRAEFIK.md](04-TRAEFIK.md))
- cert-manager and the TransIP webhook solver installed ([05-CERT-MANAGER.md](05-CERT-MANAGER.md))

## 1. Request the wildcard certificate

```bash
kubectl apply -f k3s/tls/wildcard-certificate.yaml
```

This creates a Certificate resource that uses DNS-01 validation against TransIP. Once issued, the certificate is stored as a Secret (`wildcard-geeklabs-dev-tls`) in the `traefik` namespace.

Wait for the certificate to be issued (DNS-01 validation typically takes 2-10 minutes):

```bash
kubectl get certificate -n traefik -w
```

## 2. Set the wildcard certificate as default

Once the certificate shows `READY=True`, tell traefik to use it as the default certificate for all TLS connections:

```bash
kubectl apply -f k3s/tls/default-tlsstore.yaml
```

This applies a TLSStore resource that references the wildcard secret by name. From this point on, traefik serves the wildcard cert for all matching hosts automatically.

## Ingress usage

Ingresses only need a `tls` section with the host — no `secretName` required:

```yaml
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - app.geeklabs.dev
  rules:
    - host: app.geeklabs.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 80
```

Traefik matches `app.geeklabs.dev` against `*.geeklabs.dev` and serves the wildcard cert automatically.

## Certificate renewal

cert-manager handles renewal automatically (~30 days before expiry). The TLSStore references the Secret by name, so traefik picks up the renewed certificate without any restarts.

## Manifests

| File | Purpose |
|---|---|
| `k3s/tls/wildcard-certificate.yaml` | cert-manager Certificate resource for `*.geeklabs.dev` |
| `k3s/tls/default-tlsstore.yaml` | Traefik TLSStore setting the wildcard cert as default |

## Troubleshooting

**TLS certificate not being served**

Confirm the wildcard certificate is ready and the TLSStore is applied:

```bash
kubectl get certificate -n traefik
kubectl get tlsstore -n traefik
```
