# Overview

This guide walks you through building a Kubernetes homelab on Raspberry Pi hardware — from flashing SD cards to running production-grade services with automatic TLS, DNS, and GitOps deployments.

By the end you will have a 3-node cluster running real services accessible via HTTPS on your local network, fully managed through Git.

## What you will build

```
                        ┌──────────────────────────────────────────────────┐
                        │               Your home network                  │
                        │                                                  │
  Browser request       │    ┌──────────────┐                              │
  https://app.geeklabs.dev   │  Router/DHCP │                              │
        │               │    └──────┬───────┘                              │
        │               │           │                                      │
        ▼               │    ┌──────▼───────┐                              │
   DNS lookup           │    │   Switch     │                              │
   (external-dns        │    └──┬───┬───┬───┘                              │
    → DNS provider)     │       │   │   │                                  │
        │               │  ┌────▼┐ ┌▼────┐ ┌▼────┐                         │
        ▼               │  │ Pi  │ │ Pi  │ │ Pi  │   k3s cluster           │
   A record points to   │  │  1  │ │  2  │ │  3  │   (3 nodes)             │
   LoadBalancer IP      │  │     │ │     │ │     │                         │
        │               │  └──┬──┘ └──┬──┘ └──┬──┘                         │
        │               │     │       │       │                            │
        ▼               │  ┌──▼───────▼───────▼──┐                         │
   10.0.1.240           │  │      MetalLB         │  Assigns LB IPs        │
   (MetalLB)            │  └──────────┬───────────┘                        │
        │               │             │                                    │
        ▼               │  ┌──────────▼───────────┐                        │
   Traefik              │  │    Traefik Ingress   │  TLS termination       │
   (ingress)            │  │    + wildcard cert   │  (*.geeklabs.dev)      │
        │               │  └──────────┬───────────┘                        │
        ▼               │             │                                    │
   Your app             │  ┌──────────▼───────────┐                        │
                        │  │   Service → Pod(s)   │  Your application      │
                        │  └──────────────────────┘                        │
                        └──────────────────────────────────────────────────┘
```

## Guides

The guides are split into three tiers. Each tier builds on the previous one — complete them in order within each tier.

### Tier 1: Core — Get your cluster running

After this tier you have a working 3-node k3s cluster.

| # | Component | What it does | Guide |
|---|-----------|-------------|-------|
| 01 | **Raspberry Pi** | Hardware setup, OS install, network config | [core/01-RASPBERRYPI.md](core/01-RASPBERRYPI.md) |
| 02 | **k3s** | Lightweight Kubernetes cluster | [core/02-K3S.md](core/02-K3S.md) |

### Tier 2: Base — Make the cluster production-ready

After this tier you have a fully functional GitOps-managed cluster with automatic TLS, DNS, and encrypted secrets. Deploying a new service is as simple as adding a YAML file to your Git repo.

| # | Component | What it does | Guide |
|---|-----------|-------------|-------|
| 01 | **MetalLB** | Assigns real IPs to LoadBalancer Services (replaces cloud LB) | [base/01-METALLB.md](base/01-METALLB.md) |
| 02 | **Traefik** | Routes external traffic to your Services based on hostname | [base/02-TRAEFIK.md](base/02-TRAEFIK.md) |
| 03 | **cert-manager** | Automatic TLS certificates from Let's Encrypt | [base/03-CERT-MANAGER.md](base/03-CERT-MANAGER.md) |
| 04 | **external-dns** | Automatic DNS records when you create an Ingress | [base/04-EXTERNAL-DNS.md](base/04-EXTERNAL-DNS.md) |
| 05 | **Traefik TLS** | Default wildcard certificate so every Ingress gets HTTPS | [base/05-TRAEFIK-TLS.md](base/05-TRAEFIK-TLS.md) |
| 06 | **Argo CD** | GitOps — push to Git, cluster updates automatically | [base/06-ARGOCD.md](base/06-ARGOCD.md) |
| 07 | **Sealed Secrets** | Encrypt secrets so they're safe to commit to Git | [base/07-SEALED-SECRETS.md](base/07-SEALED-SECRETS.md) |

### Tier 3: Workloads — Deploy services on the platform

After this tier you have observability and automated dependency updates on top of the platform.

| # | Component | What it does | Guide |
|---|-----------|-------------|-------|
| 01 | **Monitoring** | Prometheus, Grafana, and Alertmanager via kube-prometheus-stack | [workloads/01-MONITORING.md](workloads/01-MONITORING.md) |
| 02 | **Renovate** | Automated dependency updates via GitHub App | [workloads/02-RENOVATE.md](workloads/02-RENOVATE.md) |

## How a request reaches your app

Understanding the full request flow helps when things go wrong:

1. **You create an Ingress** with `host: app.geeklabs.dev` and push it to Git
2. **Argo CD** detects the change and applies the Ingress to the cluster
3. **external-dns** sees the new Ingress and creates an A record in your DNS provider (TransIP in this setup) pointing `app.geeklabs.dev` to `10.0.1.240`
4. **cert-manager** already issued a wildcard certificate for `*.geeklabs.dev` — Traefik serves it automatically
5. **A browser** resolves `app.geeklabs.dev` → `10.0.1.240` via DNS
6. **MetalLB** has assigned `10.0.1.240` to the Traefik Service and responds to ARP requests for that IP
7. **Traefik** terminates TLS using the wildcard cert and routes the request to the correct Service based on the hostname
8. **The Service** forwards the request to your application Pod

## Network layout

The cluster nodes sit on a single flat network (`10.0.1.0/24`). MetalLB reserves a small range of IPs on this same subnet for LoadBalancer Services.

| Role | Hostname | IP |
|------|----------|-----|
| Server (control-plane) | `api.k3s.foobar.ninja` | `10.0.1.97` |
| Agent (worker) | `node1.k3s.foobar.ninja` | `10.0.1.85` |
| Agent (worker) | `node2.k3s.foobar.ninja` | `10.0.1.70` |
| MetalLB pool | — | `10.0.1.240` – `10.0.1.254` |

> Make sure the MetalLB IP range is excluded from your router's DHCP scope so no other device gets assigned one of those addresses.

## About the two domains

You will notice two domain names throughout the guides:

- **`foobar.ninja`** — Used for cluster-internal names (node hostnames like `api.k3s.foobar.ninja`). These are just hostnames, not publicly routed. You can use any domain you own, or even made-up names if you add them to `/etc/hosts`.

- **`geeklabs.dev`** — Used for services you access in your browser (`argocd.geeklabs.dev`, `dash.geeklabs.dev`, etc.). This domain is managed by a DNS provider (TransIP in this setup) where external-dns creates A records and cert-manager validates TLS certificates.

You will need at least one real domain with a DNS provider that has a programmable API. See the next section for details.

## Choosing a DNS provider

Throughout these guides, **TransIP** is used as the DNS provider. Your provider will likely be different — and that is fine. The concepts and architecture are identical; only the provider-specific configuration changes (API keys, webhook solvers, Helm flags).

Two components in this stack talk to your DNS provider's API:

| Component | What it does with DNS | Record types |
|---|---|---|
| **cert-manager** | Creates temporary TXT records for Let's Encrypt DNS-01 challenges to prove you own the domain, then cleans them up | `TXT` at `_acme-challenge.*` |
| **external-dns** | Creates and deletes A records so that hostnames like `app.geeklabs.dev` point to your cluster's LoadBalancer IP | `A` (and `TXT` ownership records) |

Both need **API access** to your DNS provider. When choosing a provider, check that it is supported by **both** cert-manager and external-dns — not all providers are.

### European providers with good support

| Provider | Country | cert-manager | external-dns | Notes |
|---|---|---|---|---|
| **[TransIP](https://www.transip.nl/)** | NL | Via [webhook](https://github.com/demeester/cert-manager-webhook-transip) | Via [webhook](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/transip.md) | Used in these guides. Popular Dutch registrar. |
| **[Hetzner DNS](https://www.hetzner.com/dns-console)** | DE | Via [webhook](https://github.com/vadimkim/cert-manager-webhook-hetzner) | Via [webhook](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/hetzner.md) | Free DNS hosting. Very popular in the European homelab community. |
| **[OVHcloud](https://www.ovhcloud.com/)** | FR | Via [webhook](https://github.com/baarde/cert-manager-webhook-ovh) | [Built-in](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/ovh.md) | Major European cloud provider. |
| **[Scaleway](https://www.scaleway.com/)** | FR | Via [webhook](https://github.com/scaleway/cert-manager-webhook-scaleway) | [Built-in](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/scaleway.md) | French cloud provider with free DNS hosting. |
| **[deSEC](https://desec.io/)** | DE | Via [webhook](https://github.com/kmorning/cert-manager-webhook-desec) | Via [webhook](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/desec.md) | Free, privacy-focused, non-profit DNS hosting. |

> Most European providers require community **webhook solvers** for cert-manager. This adds one extra Helm install (as shown in [base/03-CERT-MANAGER.md](base/03-CERT-MANAGER.md) for TransIP), but it is straightforward.

### Non-European alternatives

If you do not have a preference for a European provider, **[Cloudflare](https://www.cloudflare.com/)** (US-based) has a free tier and **built-in** support in both cert-manager and external-dns — no webhooks needed. It is the easiest option to set up.

### If your registrar does not offer a DNS API

You do not have to move your domain registration. You can keep your domain at any registrar and **delegate DNS** to a provider that has an API. For example, with Hetzner DNS (free):

1. Create a free [Hetzner DNS Console](https://dns.hetzner.com/) account and add your domain
2. Hetzner gives you three nameservers (e.g. `hydrogen.ns.hetzner.com`)
3. Update the NS records at your registrar to point to Hetzner
4. DNS is now managed by Hetzner while your domain stays registered where it is

This also works with Cloudflare, deSEC, or any other provider that offers DNS hosting.

### What to look for

When picking a provider, keep these things in mind:

- **API key / token authentication** — You will store API credentials as Kubernetes Secrets (encrypted via Sealed Secrets). Make sure the provider supports API keys or tokens, not just username/password login.
- **Rate limits** — cert-manager creates and deletes TXT records during certificate issuance. Providers with very low API rate limits can cause certificate issuance to fail or be slow.
- **Propagation speed** — DNS-01 challenges require the TXT record to be visible to Let's Encrypt's validation servers. Some providers propagate changes in seconds (Hetzner, Cloudflare), others take minutes (TransIP). Slower propagation just means you wait longer for certificates, it does not break anything.
- **Wildcard support** — All providers support wildcard DNS records, but verify that the cert-manager solver for your provider supports wildcard certificates (`*.yourdomain.com`). Most do.

> **Tip:** If you are starting from scratch and want a European provider, **Hetzner DNS** is free and well-supported. If you don't mind a US-based provider, **Cloudflare** (also free) has built-in support in both tools without needing webhooks.

## About this setup

A few things to keep in mind:

- **This is a private homelab.** Nothing is exposed to the internet. Services are only accessible on the local network (and via WireGuard VPN if configured).
- **TransIP is used as the DNS provider.** These guides show TransIP-specific configuration (webhook solver, API keys, Helm flags). If you use a different provider, the architecture and flow are the same — you just swap out the provider-specific parts in [base/03-CERT-MANAGER.md](base/03-CERT-MANAGER.md) and [base/04-EXTERNAL-DNS.md](base/04-EXTERNAL-DNS.md).
- **ARM64 only.** All three nodes are Raspberry Pi 5 boards. Make sure any container images you deploy support `linux/arm64`.
- **Not production.** This is a learning environment. The guides favour simplicity over high availability. For example, there is a single control-plane node rather than three.

## Repository structure

After completing all the guides, your repository will look like this:

```
homelab/
├── demo/                          # Demo app (hello-world)
│   └── hello-world.yaml
├── docs/                          # These guides
├── k3s/
│   ├── argocd/
│   │   ├── apps/                  # ArgoCD Application manifests (one per service)
│   │   │   ├── root.yaml          # Root "App of Apps" — manages this directory
│   │   │   ├── hello-world.yaml
│   │   │   ├── metallb.yaml
│   │   │   ├── monitoring.yaml
│   │   │   ├── tls.yaml
│   │   │   └── sealed-secrets.yaml
│   │   ├── ingress.yaml           # Ingress for the ArgoCD UI
│   │   └── project.yaml           # AppProject — scopes permissions
│   ├── apps/                      # Helm-based apps (managed via Kustomize)
│   │   ├── argocd/
│   │   ├── authentik/
│   │   └── monitoring/
│   ├── metallb/                   # MetalLB configuration
│   │   ├── ip-address-pool.yaml
│   │   └── l2-advertisement.yaml
│   ├── secrets/                   # SealedSecret manifests (encrypted, safe for Git)
│   │   ├── transip-secret.yaml
│   │   └── transip-api-key.yaml
│   └── tls/                       # Wildcard certificate and TLS store
│       ├── wildcard-certificate.yaml
│       └── default-tlsstore.yaml
└── README.md
```

Two patterns are used for deploying services:

1. **Plain manifests** (e.g. `k3s/metallb/`, `k3s/tls/`, `demo/`) — simple YAML files that ArgoCD applies directly.
2. **Kustomize + Helm** (e.g. `k3s/apps/authentik/`) — a `kustomization.yaml` that pulls a Helm chart and overlays values and sealed secrets. Used for more complex applications.

Both patterns are managed by ArgoCD through the App of Apps approach (see [base/06-ARGOCD.md](base/06-ARGOCD.md)).

## What's Next

Ideas for future expansion of the homelab, organized by category.

### Storage

- **NFS StorageClass** — Use `nfs-subdir-external-provisioner` to dynamically provision PersistentVolumes on a Synology NAS. Prerequisite for all stateful workloads.
- **Longhorn** — Distributed block storage by Rancher. Provides replicated storage across the Pi nodes with built-in snapshots and backups. ARM64 supported since v1.6.

### Observability

- **Loki + Promtail** — Log aggregation that pairs with Grafana. Promtail runs as a DaemonSet and ships container logs to Loki. Much lighter than ELK/EFK.
- **Uptime Kuma** — Lightweight uptime monitoring with a clean UI and push notifications. Supports HTTP, TCP, DNS, and ping checks.

### Security & Access

- **Authelia** — Lightweight SSO and MFA proxy that integrates natively with Traefik via ForwardAuth middleware. Supports TOTP, WebAuthn/Passkeys, and OIDC.
- **CrowdSec** — Crowdsourced intrusion prevention engine. Detects and blocks attacks using community threat intelligence. Integrates with Traefik as a bouncer plugin.
- **Vaultwarden** — Lightweight, self-hosted Bitwarden-compatible password manager. Extremely low resource usage (~64MB RAM).
- **k3s Secrets Encryption at Rest** — Enable with the `--secrets-encryption` flag on the k3s server. Encrypts secrets stored in the embedded etcd database.

### Backup & Recovery

- **k3s etcd Snapshot Backups** — Configure automatic etcd snapshots to a NAS for cluster state recovery.
- **Velero** — Kubernetes resource and volume backup/restore. Backs up to S3-compatible storage. Works with Longhorn CSI snapshots for full cluster recovery.

### Networking

- **Tailscale Subnet Router** — Deploy a Tailscale subnet router as a k3s pod to expose the entire homelab network over a WireGuard mesh without per-device configuration.
