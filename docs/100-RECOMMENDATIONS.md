# Homelab Service Recommendations
> WIP

Recommended services for the k3s homelab cluster, organized by priority phase. The current setup already includes k3s, MetalLB, Traefik, cert-manager, external-dns, and ArgoCD.

## Phase 1 — Quick Wins

These require minimal effort and unlock the rest of the stack.

### NFS StorageClass

Use `nfs-subdir-external-provisioner` to dynamically provision PersistentVolumes on the Synology NAS. This is a prerequisite for all stateful workloads.

```bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=<SYNOLOGY_IP> \
  --set nfs.path=/volume1/k3s \
  --set storageClass.name=nfs-synology
```

### Sealed Secrets
> **Status: DONE**

Encrypt Kubernetes secrets for safe storage in Git. Completes the GitOps workflow with ArgoCD — no more manually applying secrets.

- Install the controller via Helm (`sealed-secrets` by Bitnami)
- Use `kubeseal` CLI to encrypt secrets before committing
- ArgoCD syncs the SealedSecret resources, the controller decrypts them in-cluster

### k3s Secrets Encryption at Rest

Enable with the `--secrets-encryption` flag on the k3s server. Encrypts secrets stored in the embedded etcd database.

### k3s etcd Snapshot Backups

Configure automatic etcd snapshots to the Synology NAS:

```
--etcd-snapshot-schedule-cron="0 */6 * * *"
--etcd-snapshot-dir=/mnt/nas/etcd-snapshots
```

## Phase 2 — Observability

Without monitoring, the cluster is a black box.

### kube-prometheus-stack

Single Helm chart that deploys Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics. Includes pre-built dashboards for Kubernetes.

> **k3s note:** By default, k3s binds control plane metrics to `127.0.0.1`. Add these server flags to enable scraping:
> ```
> --kube-controller-manager-arg bind-address=0.0.0.0
> --kube-scheduler-arg bind-address=0.0.0.0
> --kube-proxy-arg metrics-bind-address=0.0.0.0
> ```

### Loki + Promtail

Log aggregation that pairs with Grafana. Promtail runs as a DaemonSet and ships container logs to Loki. Much lighter than ELK/EFK.

### Uptime Kuma

Lightweight uptime monitoring with a clean UI and push notifications (Telegram, Discord, Slack, email). Supports HTTP, TCP, DNS, and ping checks.

## Phase 3 — Security & Access

### Authelia

[Authelia](https://www.authelia.com/) Lightweight SSO and MFA proxy that integrates natively with Traefik via ForwardAuth middleware. Provides a single login for all services behind the ingress. Supports TOTP, WebAuthn/Passkeys, and OIDC.

Alternative: **Authentik** if a full identity platform with user management and SAML is needed.

### Authentik
> **Status: DONE**

[Authentik](https://goauthentik.io/) is an IdP (Identity Provider) and SSO (Single Sign On) platform that is built with security at the forefront of every piece of code, every feature, with an emphasis on flexibility and versatility.

### CrowdSec
> https://www.crowdsec.net/
> Basically, it's a WAF !!

Crowdsourced intrusion prevention engine. Detects and blocks attacks using community threat intelligence. Integrates with Traefik as a bouncer plugin.

### Vaultwarden

Lightweight, self-hosted Bitwarden-compatible password manager. Extremely low resource usage (~64MB RAM). Provides browser extensions, mobile apps, and CLI access.

## Phase 5 — Advanced

### Longhorn

Distributed block storage by Rancher. Provides replicated storage across the 3 Pi nodes with built-in snapshots and backups. ARM64 supported since v1.6.

### Velero

Kubernetes resource and volume backup/restore. Backs up to S3-compatible storage (MinIO on Synology). Works with Longhorn CSI snapshots for full cluster recovery.

### Tailscale Subnet Router

Deploy a Tailscale subnet router as a k3s pod to expose the entire homelab network over a WireGuard mesh without per-device configuration. Cleaner alternative to raw WireGuard.

Alternative: **Headscale** for a fully self-hosted Tailscale control server.

