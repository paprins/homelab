# Sealed Secrets

**Encrypted secrets safe to store in Git.**

Sealed Secrets bridges the last gap in the GitOps workflow — secrets. Instead of manually running `kubectl create secret`, you encrypt secrets with `kubeseal` and commit the encrypted SealedSecret manifests to Git. ArgoCD syncs them like any other resource, and the Sealed Secrets controller decrypts them in-cluster.

## How It Works

1. The Sealed Secrets controller generates a public/private key pair when first installed
2. `kubeseal` encrypts secrets using the controller's **public key** — anyone can encrypt
3. Only the controller's **private key** (in-cluster) can decrypt them
4. The controller watches for SealedSecret resources and creates the corresponding Secret

```
              kubeseal                  ArgoCD                 Controller
transip.key ──────────► SealedSecret ──────────► Cluster ──────────► Secret
              (encrypt)   (in Git)      (sync)               (decrypt)
```

## Prerequisites

- A running k3s cluster ([02-K3S.md](02-K3S.md))
- ArgoCD installed and configured ([08-ARGOCD.md](08-ARGOCD.md))
- `kubectl` and `helm` installed and configured
- Raw secret files in the gitignored `secrets/` directory

## 1. Install kubeseal CLI

```bash
brew install kubeseal
```

## 2. Install the Sealed Secrets Controller

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

kubectl create namespace sealed-secrets

helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace sealed-secrets \
  --set fullnameOverride=sealed-secrets-controller \
  --set keyrenewperiod=0
```

| Flag | Purpose |
|------|---------|
| `fullnameOverride=sealed-secrets-controller` | Sets the service name to what `kubeseal` expects by default |
| `keyrenewperiod=0` | Disables automatic key rotation (simplifies backup for homelab) |

Verify the controller is running:

```bash
kubectl get pods -n sealed-secrets
```

## 3. Back Up the Sealing Key

This is the **only way** to restore decryption ability if the controller is reinstalled. Without it, all existing SealedSecrets become unreadable.

```bash
kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key.yaml
```

Store `sealed-secrets-master-key.yaml` securely outside Git (Synology NAS, password manager). It is already in `.gitignore`.

## 4. Create SealedSecret Manifests

Each existing secret needs to be encrypted with `kubeseal`. The pattern is: create a regular Secret with `--dry-run=client`, then pipe it through `kubeseal`.

### cert-manager TransIP secret

```bash
kubectl create secret generic transip-secret \
  --namespace cert-manager \
  --from-file=transip.key=secrets/transip.key \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --format yaml > k3s/sealed-secrets/transip-secret.yaml
```

### external-dns TransIP secret

```bash
kubectl create secret generic transip-api-key \
  --namespace external-dns \
  --from-file=transip-api-key=secrets/transip.key \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --format yaml > k3s/sealed-secrets/transip-api-key.yaml
```

> Each SealedSecret includes the target namespace in its metadata. The controller creates the decrypted Secret in that namespace, regardless of where ArgoCD deploys the SealedSecret resource.

## 5. ArgoCD Integration

The ArgoCD Application is already created at `k3s/argocd/apps/sealed-secrets.yaml`. It points at the `k3s/sealed-secrets/` directory and syncs automatically via the App of Apps pattern.

Once the SealedSecret YAML files are committed and pushed, ArgoCD will:

1. Detect the new manifests in `k3s/sealed-secrets/`
2. Apply the SealedSecret resources to the cluster
3. The Sealed Secrets controller decrypts them into regular Secrets
4. cert-manager and external-dns use the Secrets as before

## Adding a New Secret

To add a new secret to the GitOps workflow:

```bash
# 1. Create the secret with --dry-run and pipe through kubeseal
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --from-literal=password=supersecret \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --format yaml > k3s/sealed-secrets/my-secret.yaml

# 2. Commit and push — ArgoCD handles the rest
git add k3s/sealed-secrets/my-secret.yaml
git commit -m "feat: add my-secret SealedSecret"
git push
```

## Updating an Existing Secret

SealedSecrets are immutable by design — you cannot edit the encrypted data. To update a secret, re-run the `kubeseal` command with the new value and overwrite the file:

```bash
kubectl create secret generic transip-secret \
  --namespace cert-manager \
  --from-file=transip.key=secrets/new-transip.key \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  --format yaml > k3s/sealed-secrets/transip-secret.yaml
```

Commit and push — ArgoCD syncs the updated SealedSecret and the controller replaces the decrypted Secret.

## Manifests

| File | Purpose |
|------|---------|
| `k3s/argocd/apps/sealed-secrets.yaml` | ArgoCD Application pointing at `k3s/sealed-secrets/` |
| `k3s/sealed-secrets/transip-secret.yaml` | Encrypted cert-manager TransIP API key |
| `k3s/sealed-secrets/transip-api-key.yaml` | Encrypted external-dns TransIP API key |

## Verification

```bash
# ArgoCD picked up the Application
kubectl get application sealed-secrets -n argocd

# SealedSecrets exist in the cluster
kubectl get sealedsecret -A

# Controller decrypted them into regular Secrets
kubectl get secret transip-secret -n cert-manager
kubectl get secret transip-api-key -n external-dns

# cert-manager still works
kubectl get certificate -n traefik

# external-dns still works
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=20
```

## Troubleshooting

### SealedSecret exists but Secret is not created

Check the controller logs:

```bash
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets --tail=50
```

Common causes:
- The SealedSecret was encrypted with a different key (controller was reinstalled without restoring the backup)
- The target namespace does not exist

### kubeseal fails to connect

`kubeseal` needs to reach the controller's service. Verify it is accessible:

```bash
kubectl get svc -n sealed-secrets
```

If running `kubeseal` from outside the cluster, ensure your kubeconfig is pointing at the right context:

```bash
kubectl config current-context
```

### Restoring the sealing key after reinstall

If the controller is reinstalled (new key pair), restore the backup before applying any existing SealedSecrets:

```bash
kubectl apply -f sealed-secrets-master-key.yaml
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```

The controller picks up the restored key on restart.

## Cleanup

To remove Sealed Secrets entirely:

```bash
# Remove the ArgoCD Application (deletes SealedSecret resources)
kubectl delete application sealed-secrets -n argocd

# Uninstall the controller
helm uninstall sealed-secrets --namespace sealed-secrets
kubectl delete namespace sealed-secrets
```

> After removing the controller, any Secrets it previously decrypted remain in their namespaces. They are now regular Secrets managed by nothing — delete them manually if no longer needed.
