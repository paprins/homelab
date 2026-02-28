# external-dns with TransIP on k3s

Automatic DNS record management in TransIP for Kubernetes Services and Ingresses.

When you create an Ingress or LoadBalancer Service, external-dns detects it and creates (or updates) the corresponding A record in TransIP — pointing to your LoadBalancer IP. When the resource is deleted, external-dns cleans up the DNS record.

## Prerequisites

- A running k3s cluster with `traefik` ingress controller
- `kubectl` and `helm` installed and configured
- A domain managed by TransIP (e.g. `geeklabs.dev`)
- A TransIP API private key (the same key used for cert-manager works fine)
- TransIP account name (your login username)

## About the TransIP API secret

**Create a separate secret for external-dns.** Using the same private key file is fine (one API key can serve multiple consumers), but each namespace needs its own Secret resource. This also keeps concerns separated: if you ever rotate the key for one component, you control the rollout independently.

## 1. Install external-dns via Helm

```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns
helm repo update
```

Create a namespace and the TransIP API secret:

```bash
kubectl create namespace external-dns

kubectl create secret generic transip-api-key \
  --namespace external-dns \
  --from-file=transip-api-key=transip.key
```

> Use the same `transip.key` file you generated from the TransIP control panel for cert-manager.

Install external-dns:

```bash
helm install external-dns external-dns/external-dns \
  --namespace external-dns \
  --set provider.name=transip \
  --set "extraArgs[0]=--transip-account=YOUR_ACCOUNTNAME" \
  --set "extraArgs[1]=--transip-keyfile=/transip/transip-api-key" \
  --set "domainFilters[0]=geeklabs.dev" \
  --set "extraVolumes[0].name=transip-api-key" \
  --set "extraVolumes[0].secret.secretName=transip-api-key" \
  --set "extraVolumeMounts[0].name=transip-api-key" \
  --set "extraVolumeMounts[0].mountPath=/transip" \
  --set "extraVolumeMounts[0].readOnly=true" \
  --set policy=sync \
  --set "sources[0]=ingress" \
  --set "sources[1]=service" \
  --set txtOwnerId=k3s-homelab
```

> Replace `YOUR_ACCOUNTNAME` with your TransIP login username.

### What these flags do

| Flag | Purpose |
|---|---|
| `provider.name=transip` | Use TransIP as the DNS provider |
| `--transip-account` | Your TransIP username |
| `--transip-keyfile` | Path to the mounted API private key |
| `domainFilters` | Only manage records under `geeklabs.dev` (safety net) |
| `policy=sync` | Full sync — creates **and** deletes records. Use `upsert-only` if you prefer external-dns to never delete records |
| `sources` | Watch both Ingress and Service resources for DNS annotations |
| `txtOwnerId` | Identifier written into TXT ownership records so external-dns knows which records it manages (prevents conflicts if you run multiple instances) |

## 2. Verify the installation

```bash
kubectl get pods -n external-dns
```

Check the logs to confirm it connected to TransIP and is watching resources:

```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns
```

You should see log lines like:

```
All records are already up to date
```

## 3. Create DNS records via Ingress annotations

The most common approach — external-dns reads the `host` field from your Ingress rules:

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

External-dns automatically picks up `demo.geeklabs.dev` from the Ingress `rules[].host` and creates an A record pointing to your traefik LoadBalancer IP.

No extra annotations are needed — external-dns reads the host from the Ingress spec by default.

### Explicit hostname annotation (optional)

If you want to set a hostname that differs from the Ingress `host` field, or add additional records:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: custom.geeklabs.dev
```

### TTL annotation (optional)

Override the default TTL (in seconds, TransIP minimum is 60):

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/ttl: "300"
```

## 4. Create DNS records via Service annotations

For LoadBalancer Services that aren't behind an Ingress:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-service.geeklabs.dev
spec:
  type: LoadBalancer
  selector:
    app: my-service
  ports:
    - port: 80
      targetPort: 80
```

External-dns creates an A record for `my-service.geeklabs.dev` pointing to the Service's external IP.

## 5. Exclude resources from external-dns

To prevent external-dns from managing DNS for a specific Ingress or Service:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/exclude: "true"
```

## How it works with cert-manager

External-dns and cert-manager complement each other — they don't conflict:

| Component | Responsibility | Records managed |
|---|---|---|
| **cert-manager** | TLS certificate issuance via DNS-01 | `TXT` records at `_acme-challenge.*` (temporary, cleaned up after validation) |
| **external-dns** | DNS routing to your cluster | `A` records (and `TXT` ownership records) |

They both use the TransIP API independently with their own credentials. The `_acme-challenge` TXT records that cert-manager creates are ignored by external-dns, and the A records that external-dns creates are ignored by cert-manager.

**Typical flow for a new service:**

1. You deploy a Service/Ingress with a hostname (e.g. `app.geeklabs.dev`)
2. External-dns detects it and creates an `A` record in TransIP → `app.geeklabs.dev → <LoadBalancer IP>`
3. Cert-manager detects the Certificate/Ingress annotation and runs DNS-01 validation
4. Users can reach `https://app.geeklabs.dev` with a valid TLS cert

## Note on `.dev` domains and HTTPS

The `.dev` TLD is on the [HSTS preload list](https://hstspreload.org/) (owned by Google). This means modern browsers will **always** upgrade HTTP requests to HTTPS before they even leave the browser — no server-side redirect is involved. This applies to all `.dev` domains, including `geeklabs.dev`.

In practice this means every Ingress under `geeklabs.dev` needs a valid TLS certificate, otherwise browsers will show a security warning. Since cert-manager is already handling certificate issuance, this shouldn't be a problem — just make sure each Ingress has a `tls` section referencing a valid cert.

## Troubleshooting

**No records being created**

Check external-dns logs for errors:

```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=100
```

Common causes:
- Wrong TransIP account name or API key
- Domain not in your TransIP account
- `domainFilters` doesn't match the hostname
- The Ingress/Service doesn't have a resolvable hostname

**Records created but pointing to wrong IP**

External-dns uses the LoadBalancer IP from the Ingress controller's Service. Verify your traefik Service has the right external IP:

```bash
kubectl get svc -n traefik
```

**Records not being deleted**

If using `policy=upsert-only`, external-dns will never delete records. Switch to `policy=sync` if you want full lifecycle management. Also check that the `txtOwnerId` matches — external-dns only deletes records it owns.

**Duplicate TXT records / ownership errors**

The `txtOwnerId` identifies which external-dns instance owns a record. If you reinstall external-dns with a different owner ID, it won't recognize its old records. Stick with a consistent `txtOwnerId` (I use `k3s-homelab`).

**Verify a record in TransIP**

```bash
dig A app.geeklabs.dev @ns0.transip.net
dig A app.geeklabs.dev @8.8.8.8
```

## Cleanup

To remove external-dns:

```bash
helm uninstall external-dns -n external-dns
kubectl delete namespace external-dns
```

> With `policy=sync`, uninstalling external-dns does **not** delete the DNS records it created. They remain in TransIP until you manually remove them or reinstall external-dns.
