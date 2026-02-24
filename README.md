# Pascal's Homelab

👋 Hi there!

Finally got time to write about my homelab setup. It's not *that* special, but ... it's mine.

## Hardware

This is an overview of the hardware I've used to build my homelab (with the exception of some UTP cables I already had)

* [3x Raspberry Pi 5 (8Gb)](https://www.kiwi-electronics.com/nl/raspberry-pi-5-8gb-11580)
* [GeeekPi DeskPi T0 4U](https://shorturl.at/935yF)
* [GeeekPi 10 inch 2U Rack Mount for 4x Raspberry Pi 5](https://shorturl.at/K6cVp)
* [GeeekPi 12 Port Patch Panel 0.5U CAT6](https://shorturl.at/rE2g1)
* [Corsair P310 500Gb SSD](https://www.alternate.nl/Crucial/P310-500-GB-SSD/html/product/100079258)
* [Unifi USW Flex Mini](https://www.coolblue.nl/product/888938/ubiquiti-unifi-usw-flex-mini.html)
* [Anker Prime Charger 200W](https://www.coolblue.nl/product/963285/anker-prime-6-in-1-oplaadstation-200w.html)

## Software

* Raspberry Pi OS Lite (Debian Trixie)
* [k3s](https://k3s.io/)

I used the [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to create bootable microSD and/or SSD.

## My Situation

* My DNS is hosted at [TransIP](https://www.transip.nl/)
* I might use my Synology NAS to create Persistent Volumes
* My homelab is private and private only! Only accessible on-premise and via WireGuard VPN. 
* (I might decide to use Tailscale later to access my homelab)

## About DNS

Both [cert-manager](docs/05-CERT-MANAGER.md) and [external-dns](docs/06-EXTERNAL-DNS.md) require a DNS provider with a **programmable API** — cert-manager needs it to create TXT records for DNS-01 challenges, external-dns needs it to manage A records automatically. I use TransIP, but you can substitute any provider supported by both tools.

Providers with built-in support in both cert-manager and external-dns: **Cloudflare** (free tier), **AWS Route53**, **Google Cloud DNS**, **Azure DNS**, and **DigitalOcean**. Many others (including TransIP) are supported via community webhooks. If your registrar doesn't offer a DNS API, you can delegate DNS to a provider that does (e.g., point your NS records to Cloudflare).

## Setup Guide

1. [Raspberry Pi](docs/01-RASPBERRYPI.md) — OS install and initial config
2. [k3s](docs/02-K3S.md) — Lightweight Kubernetes cluster
3. [MetalLB](docs/03-METALLB.md) — Bare-metal LoadBalancer
4. [Traefik](docs/04-TRAEFIK.md) — Ingress controller
5. [cert-manager](docs/05-CERT-MANAGER.md) — TLS certificates via DNS-01
6. [external-dns](docs/06-EXTERNAL-DNS.md) — Automatic DNS records
7. [Traefik TLS](docs/07-TRAEFIK-TLS.md) — Default wildcard TLS certificate
8. [Argo CD](docs/08-ARGOCD.md) — GitOps continuous delivery
9. [Sealed Secrets](docs/20-SEALED-SECRETS.md) — Encrypted secrets in Git

[Recommendations](docs/100-RECOMMENDATIONS.md) — Service recommendations for future expansion

## Currently Installed

The following services are currently deployed on my cluster:

* `metallb` - LoadBalancer
* `traefik` - Ingress Controller
* `sealed-secrets` - encrypt your `Secrets` so you can safely push them to Git
* `cert-manager` - X.509 certificate management using `acme-issuer`
* `external-dns` - auto DNS record creation for `Service` resources
* `argocd` - GitOps
* `authentik` - open-source IdP (Identity Provider) and SSO (Single Sign On) platform

I will do my best to update this repository and let it reflect the current state of my homelab. Some of the information only applies to my setup, other information is generic and can be used anywhere.