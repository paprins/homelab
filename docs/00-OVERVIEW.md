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
    → DNS provider)     │       │   │   │                                   │
        │               │  ┌────▼┐ ┌▼────┐ ┌▼────┐                        │
        ▼               │  │ Pi  │ │ Pi  │ │ Pi  │   k3s cluster          │
   A record points to   │  │  1  │ │  2  │ │  3  │   (3 nodes)           │
   LoadBalancer IP      │  │     │ │     │ │     │                        │
        │               │  └──┬──┘ └──┬──┘ └──┬──┘                        │
        │               │     │       │       │                            │
        ▼               │  ┌──▼───────▼───────▼──┐                        │
   10.0.1.240           │  │      MetalLB         │  Assigns LB IPs       │
   (MetalLB)            │  └──────────┬───────────┘                        │
        │               │             │                                    │
        ▼               │  ┌──────────▼───────────┐                        │
   Traefik              │  │    Traefik Ingress    │  TLS termination      │
   (ingress)            │  │    + wildcard cert    │  (*.geeklabs.dev)     │
        │               │  └──────────┬───────────┘                        │
        ▼               │             │                                    │
   Your app             │  ┌──────────▼───────────┐                        │
                        │  │   Service → Pod(s)    │  Your application     │
                        │  └──────────────────────┘                        │
                        └──────────────────────────────────────────────────┘
```

## Components

Each guide builds on the previous one. Follow them in order.

| # | Component | What it does | Guide |
|---|-----------|-------------|-------|
| 01 | **Raspberry Pi** | Hardware setup, OS install, network config | [01-RASPBERRYPI.md](01-RASPBERRYPI.md) |
| 02 | **k3s** | Lightweight Kubernetes cluster | [02-K3S.md](02-K3S.md) |
| 03 | **MetalLB** | Assigns real IPs to LoadBalancer Services (replaces cloud LB) | [03-METALLB.md](03-METALLB.md) |
| 04 | **Traefik** | Routes external traffic to your Services based on hostname | [04-TRAEFIK.md](04-TRAEFIK.md) |
| 05 | **cert-manager** | Automatic TLS certificates from Let's Encrypt | [05-CERT-MANAGER.md](05-CERT-MANAGER.md) |
| 06 | **external-dns** | Automatic DNS records when you create an Ingress | [06-EXTERNAL-DNS.md](06-EXTERNAL-DNS.md) |
| 07 | **Traefik TLS** | Default wildcard certificate so every Ingress gets HTTPS | [07-TRAEFIK-TLS.md](07-TRAEFIK-TLS.md) |
| 08 | **Argo CD** | GitOps — push to Git, cluster updates automatically | [08-ARGOCD.md](08-ARGOCD.md) |
| 20 | **Sealed Secrets** | Encrypt secrets so they're safe to commit to Git | [20-SEALED-SECRETS.md](20-SEALED-SECRETS.md) |

After completing guides 01 through 08, you have a fully functional GitOps-managed cluster. From that point on, deploying a new service is as simple as adding a YAML file to your Git repo.

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

### Providers with built-in support in both tools

These work out of the box with no extra webhooks or plugins:

- **[Cloudflare](https://www.cloudflare.com/)** — Free tier available. Widely used, excellent API. The easiest choice if you don't have a preference yet.
- **[AWS Route 53](https://aws.amazon.com/route53/)**
- **[Google Cloud DNS](https://cloud.google.com/dns)**
- **[Azure DNS](https://azure.microsoft.com/en-us/products/dns)**
- **[DigitalOcean DNS](https://www.digitalocean.com/products/networking)**

### Providers supported via community webhooks

Many other providers work but require an additional webhook solver for cert-manager and/or a provider plugin for external-dns. This is the case for **TransIP** (used in these guides) — it requires the [cert-manager-webhook-transip](https://github.com/demeester/cert-manager-webhook-transip) solver.

### If your registrar does not offer a DNS API

You do not have to move your domain registration. You can keep your domain at any registrar and **delegate DNS** to a provider that has an API:

1. Sign up for a free Cloudflare account and add your domain
2. Cloudflare gives you two nameservers (e.g. `ada.ns.cloudflare.com`)
3. Update the NS records at your registrar to point to Cloudflare
4. DNS is now managed by Cloudflare while your domain stays registered where it is

### What to look for

When picking a provider, keep these things in mind:

- **API key / token authentication** — You will store API credentials as Kubernetes Secrets (encrypted via Sealed Secrets). Make sure the provider supports API keys or tokens, not just username/password login.
- **Rate limits** — cert-manager creates and deletes TXT records during certificate issuance. Providers with very low API rate limits can cause certificate issuance to fail or be slow.
- **Propagation speed** — DNS-01 challenges require the TXT record to be visible to Let's Encrypt's validation servers. Some providers propagate changes in seconds (Cloudflare), others take minutes (TransIP). Slower propagation just means you wait longer for certificates, it does not break anything.
- **Wildcard support** — All providers support wildcard DNS records, but verify that the cert-manager solver for your provider supports wildcard certificates (`*.yourdomain.com`). Most do.

> **Tip:** If you are starting from scratch and just want things to work, go with **Cloudflare**. It is free, fast, and has first-class support in both cert-manager and external-dns with no extra webhooks needed.

## About this setup

A few things to keep in mind:

- **This is a private homelab.** Nothing is exposed to the internet. Services are only accessible on the local network (and via WireGuard VPN if configured).
- **TransIP is used as the DNS provider.** These guides show TransIP-specific configuration (webhook solver, API keys, Helm flags). If you use a different provider, the architecture and flow are the same — you just swap out the provider-specific parts in [05-CERT-MANAGER.md](05-CERT-MANAGER.md) and [06-EXTERNAL-DNS.md](06-EXTERNAL-DNS.md).
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
│   │   │   ├── tls.yaml
│   │   │   └── sealed-secrets.yaml
│   │   ├── ingress.yaml           # Ingress for the ArgoCD UI
│   │   └── project.yaml           # AppProject — scopes permissions
│   ├── apps/                      # Helm-based apps (managed via Kustomize)
│   │   ├── argocd/
│   │   ├── authentik/
│   │   └── headlamp/
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

Both patterns are managed by ArgoCD through the App of Apps approach (see [08-ARGOCD.md](08-ARGOCD.md)).
