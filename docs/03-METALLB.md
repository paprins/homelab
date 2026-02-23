# Setting up MetalLB as LoadBalancer

MetalLB provides LoadBalancer IP allocation for bare-metal Kubernetes clusters. Without it, Services of type `LoadBalancer` stay in `<pending>` state indefinitely.

## Prerequisites

- A running k3s cluster with the built-in ServiceLB (Klipper) disabled (`--disable servicelb`)
- `kubectl` installed and configured
- A range of unused IP addresses on your local network reserved for MetalLB

## 1. Install MetalLB

> The version below (`v0.15.3`) may be outdated. Check https://metallb.universe.tf/installation/ for the latest version.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
```

This creates the `metallb-system` namespace and deploys the MetalLB controller and speaker pods.

Wait for all pods to be running:

```bash
kubectl get pods -n metallb-system -w
```

## 2. Configure an IP address pool

MetalLB needs to know which IP addresses it can hand out to LoadBalancer Services. Create an `IPAddressPool` resource that defines the range:

```bash
kubectl apply -f k3s/metallb/ip-address-pool.yaml
```

This reserves `10.0.1.240-10.0.1.254` for LoadBalancer Services. Make sure this range is excluded from your router's DHCP scope to avoid conflicts.

## 3. Enable L2 advertisement

MetalLB supports two modes for announcing LoadBalancer IPs: BGP and Layer 2 (ARP/NDP). For a homelab, Layer 2 is the simplest — MetalLB responds to ARP requests on the local network, making the IP reachable without any router configuration.

```bash
kubectl apply -f k3s/metallb/l2-advertisement.yaml
```

## 4. Verify

Create a test LoadBalancer Service or check an existing one:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Services should now receive an external IP from the `10.0.1.240-10.0.1.254` range instead of staying `<pending>`.

## Manifests

| File | Purpose |
|---|---|
| `k3s/metallb/ip-address-pool.yaml` | Defines the IP range MetalLB can allocate |
| `k3s/metallb/l2-advertisement.yaml` | Enables Layer 2 (ARP) announcement for allocated IPs |

## Troubleshooting

**Services stuck in `<pending>`**

Check that the MetalLB pods are running and the IPAddressPool exists:

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
```

Check MetalLB controller logs:

```bash
kubectl logs -n metallb-system -l app=metallb,component=controller --tail=50
```

**IP not reachable from the network**

Verify the L2Advertisement is applied:

```bash
kubectl get l2advertisement -n metallb-system
```

Check speaker logs for ARP issues:

```bash
kubectl logs -n metallb-system -l app=metallb,component=speaker --tail=50
```

Make sure the IP range is on the same subnet as your nodes and is not assigned to another device.

**Conflict with k3s ServiceLB (Klipper)**

If k3s was installed without `--disable servicelb`, both ServiceLB and MetalLB will compete for LoadBalancer Services. Disable ServiceLB by adding `--disable servicelb` to your k3s server flags and restarting k3s.

## Cleanup

To remove MetalLB:

```bash
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
```
