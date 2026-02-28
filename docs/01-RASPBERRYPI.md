# Setting up the Raspberry Pis

This guide covers preparing three Raspberry Pi 5 boards to serve as the nodes for a k3s Kubernetes cluster.

## Hardware

This is the hardware used in this homelab. You can substitute parts, but the guides assume ARM64 Raspberry Pi 5 boards.

| Item | Quantity | Purpose |
|------|----------|---------|
| [Raspberry Pi 5 (8 GB)](https://www.kiwi-electronics.com/nl/raspberry-pi-5-8gb-11580) | 3 | Cluster nodes |
| [Crucial P310 500 GB NVMe SSD](https://www.alternate.nl/Crucial/P310-500-GB-SSD/html/product/100079258) | 3 | Boot + storage (faster and more reliable than SD cards) |
| [GeeekPi DeskPi T0 4U rack](https://shorturl.at/935yF) | 1 | Houses the Pis in a mini rack |
| [GeeekPi 10" 2U rack mount for 4x Pi 5](https://shorturl.at/K6cVp) | 1 | Mounts the Pis side by side |
| [GeeekPi 12-port patch panel 0.5U CAT6](https://shorturl.at/rE2g1) | 1 | Clean cable management |
| [Unifi USW Flex Mini](https://www.coolblue.nl/product/888938/ubiquiti-unifi-usw-flex-mini.html) | 1 | 5-port managed switch for the cluster |
| [Anker Prime 200W 6-in-1 charger](https://www.coolblue.nl/product/963285/anker-prime-6-in-1-oplaadstation-200w.html) | 1 | Powers all three Pis via USB-C |

You also need an NVMe HAT or adapter for each Pi 5 (to connect the SSD), and ethernet cables.

> **Why NVMe instead of microSD?** SD cards are slow and wear out quickly under Kubernetes workloads (etcd writes, container pulls, log rotation). NVMe SSDs are significantly faster and more durable. You can start with SD cards to test, but plan to move to NVMe for anything long-running.

## Operating system

This cluster runs **Raspberry Pi OS Lite (Debian Trixie)** — the 64-bit, headless variant with no desktop environment. "Lite" means no GUI, which is what you want for a server.

> **Why Debian Trixie?** At the time of writing, Trixie is the latest Raspberry Pi OS release based on Debian 13. It ships with a modern kernel (`6.12.x`) that has good support for the Pi 5 hardware. The important thing is that you use a **64-bit (arm64)** image — k3s and most container images require it.

### Flash the OS

Use the [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash each SSD (or SD card):
(I used [this](https://www.amazon.nl/dp/B0FJQFYVNX) to flash each SSD)

1. Open Raspberry Pi Imager
2. Select **Raspberry Pi 5** as the device
3. Select **Raspberry Pi OS Lite (64-bit)** as the operating system
4. Select your SSD/SD card as the storage target
5. Click **Next**, then click **Edit Settings** to pre-configure the image

### Pre-configure in the Imager

The Raspberry Pi Imager lets you set up the most important settings before the first boot. This saves you from having to connect a keyboard and monitor.

**General tab:**
- Set a **hostname** (e.g. `k3s-master` for the first Pi, `k3s-worker-1` and `k3s-worker-2` for the others)
- Set a **username and password** (e.g. `pi` / your password)
- Skip wireless LAN (the Pis will use ethernet)
- Set your **locale and timezone**

**Services tab:**
- **Enable SSH** — select "Use password authentication" (you can switch to key-only later)

Click **Save**, then **Yes** to apply the settings and flash.

Repeat for all three Pis, giving each a unique hostname.

## First boot

1. Insert the SSD (or SD card) into each Pi
2. Connect each Pi to the network switch via ethernet
3. Connect power — the Pis boot automatically

Wait a minute for them to boot, then find their IP addresses. Check your router's DHCP lease table, or scan the network:

```bash
# From your laptop (macOS/Linux)
arp -a | grep -i "raspberry\|dc:a6\|2c:cf"

# Or use nmap if installed
nmap -sn 10.0.1.0/24
```

SSH into each Pi to verify:

```bash
ssh pi@<ip-address>
```

## Configure static IPs

Kubernetes nodes need stable IP addresses. If a node's IP changes, the cluster breaks. You have two options:

1. **DHCP reservations** (recommended) — Configure your router to always assign the same IP to each Pi's MAC address. This way the Pis still use DHCP, but always get the same address.

2. **Static IP on the Pi** — Set a fixed IP directly on each Pi using `nmcli`:

```bash
# Find the ethernet connection name
nmcli connection show

# Set a static IP (adjust for each node)
sudo nmcli connection modify "Wired connection 1" \
  ipv4.addresses 10.0.1.97/24 \
  ipv4.gateway 10.0.1.1 \
  ipv4.dns "10.0.1.1" \
  ipv4.method manual

# Apply the changes
sudo nmcli connection up "Wired connection 1"
```

The IPs used in this cluster:

| Node | Hostname | IP |
|------|----------|-----|
| Server (control-plane) | `k3s-master` | `10.0.1.97` |
| Agent 1 (worker) | `k3s-node1` | `10.0.1.85` |
| Agent 2 (worker) | `k3s-node2` | `10.0.1.70` |

> **Reserve the MetalLB range too.** Later, MetalLB will hand out IPs from `10.0.1.240` through `10.0.1.254` for LoadBalancer Services. Make sure your router's DHCP scope does not include this range, or those IPs will conflict.

## Prepare the Pis for Kubernetes

Run the following steps on **each** Pi.

### Update the system

```bash
sudo apt update && sudo apt upgrade -y
```

### Enable cgroups

k3s needs cgroups v2 enabled for container resource management. On Raspberry Pi OS, add the following to the kernel command line:

```bash
# Check if cgroups are already enabled
cat /proc/cgroups

# Edit the boot config
sudo nano /boot/firmware/cmdline.txt
```

Append to the **end** of the existing line (do not create a new line):

```
cgroup_memory=1 cgroup_enable=memory
```

> **Important:** The entire `cmdline.txt` must be a single line. Do not add a newline.

### Disable swap

Kubernetes expects swap to be off. If swap is active, the kubelet may not start.

```bash
# Check if swap is active
free -h

# Disable swap immediately
sudo swapoff -a

# Prevent swap from coming back after reboot
sudo systemctl disable dphys-swapfile.service
```

### Reboot

```bash
sudo reboot
```

After reboot, SSH back in and verify:

```bash
# cgroups should show "memory" with "enabled=1"
cat /proc/cgroups | grep memory

# Swap should show 0
free -h | grep Swap
```

## Set up SSH key authentication (optional but recommended)

Password-based SSH works, but key-based authentication is more convenient and more secure.

From your laptop:

```bash
# Generate a key pair if you don't have one
ssh-keygen -t ed25519

# Copy your public key to each Pi
ssh-copy-id pi@10.0.1.97
ssh-copy-id pi@10.0.1.85
ssh-copy-id pi@10.0.1.70
```

After this you can SSH without typing a password:

```bash
ssh pi@10.0.1.97
```

Optionally, add entries to your `~/.ssh/config` for convenience:

```
Host k3s-master
  HostName 10.0.1.97
  User pi

Host k3s-node1
  HostName 10.0.1.85
  User pi

Host k3s-node2
  HostName 10.0.1.70
  User pi
```

Now you can just type `ssh k3s-master`.

## Verify

At this point, all three Pis should be:

- Running Raspberry Pi OS Lite (64-bit / arm64)
- Connected to the network with static IPs
- Accessible via SSH
- Updated to the latest packages
- Swap disabled
- cgroups v2 enabled

You are ready to install k3s ([02-K3S.md](02-K3S.md)).
