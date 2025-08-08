# Proxmox LLDP Discovery Hook

**Auto-enable LLDP network discovery for VMs and LXC containers.**

Mirrors LLDP traffic between physical interfaces and guest networks, solving topology visibility issues in VLAN-aware bridge environments.

[![Proxmox VE 8.x](https://img.shields.io/badge/Proxmox%20VE-8.x-blue.svg)](https://www.proxmox.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

---

## Problem & Solution

**Problem:** VMs/containers on VLAN bridges can't see network topology via LLDP.

**Solution:** Bidirectional mirroring of LLDP frames (0x88cc) between host physical interfaces and guest virtual interfaces.

---

## Quick Install

```bash
# Install dependencies
apt update && apt install lldpd iproute2
systemctl enable --now lldpd

# Install scripts
wget -O /var/lib/vz/snippets/lldp-launcher-hook.sh \
  https://raw.githubusercontent.com/user/repo/main/lldp-launcher-hook.sh
wget -O /usr/local/sbin/lldp-mirror-worker.sh \
  https://raw.githubusercontent.com/user/repo/main/lldp-mirror-worker.sh

chmod +x /var/lib/vz/snippets/lldp-launcher-hook.sh
chmod +x /usr/local/sbin/lldp-mirror-worker.sh
```

## Configuration

Add to VM or LXC config:

```bash
# For VM 114
nano /etc/pve/qemu-server/114.conf
hookscript: local:snippets/lldp-launcher-hook.sh
lldp_mirror_net0=bond0

# For LXC 101  
nano /etc/pve/lxc/101.conf
hookscript: local:snippets/lldp-launcher-hook.sh
lldp_mirror_net0=bond0
```

## Usage

1. Restart VM/container
2. Check logs: `tail -f /var/log/lldp-hook.log`
3. Inside guest: `lldpcli show neighbors`

## Architecture

- **Launcher:** Tiny script called by Proxmox, launches worker in background
- **Worker:** Main logic for guest detection, tc rules, and LLDP mirroring
- **Auto-Config:** Extracts `lldp_mirror_netX` from main config to separate `.lldp` file to avoid Proxmox parsing errors

## Troubleshooting

- **Logs:** `/var/log/lldp-hook.log`
- **TC Rules:** `tc filter show dev bond0 ingress`
- **Guest Packets:** `tcpdump -i eth0 ether proto 0x88cc`

---

**MIT License | Made for Proxmox Community**
