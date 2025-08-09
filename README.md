# Proxmox LLDP Discovery Hook

**Auto-enable LLDP network discovery for VMs and LXC containers.**

Mirrors LLDP traffic between physical interfaces and guest networks, solving topology visibility issues in VLAN-aware bridge environments.

[![Proxmox VE 8.x](https://img.shields.io/badge/Proxmox%20VE-8.x-blue.svg)](https://www.proxmox.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

---

## Problem & Solution

**Problem:** VMs/containers on VLAN bridges can't see network topology via LLDP.

**Solution:** 
- **Ingress**: Set `bridge-group-fwd-mask 0x4000` for automatic LLDP forwarding to guests
- **Egress**: TC mirror rules for guest LLDP transmission back to physical network

**Key Requirements:**
- Bridge must have `bridge-group-fwd-mask 0x4000` (LLDP forwarding)
- TC rules handle guest → physical LLDP transmission

---

## Quick Install

```bash
# Install dependencies
apt update && apt install lldpd iproute2
systemctl enable --now lldpd

# Install scripts
wget -O /var/lib/vz/snippets/lldp-launcher-hook.sh \
  https://raw.githubusercontent.com/lavacano/Proxmox-LLDP-Discovery/refs/heads/main/lldp-launcher-hook.sh
wget -O /usr/local/sbin/lldp-mirror-worker.sh \
  https://raw.githubusercontent.com/lavacano/Proxmox-LLDP-Discovery/refs/heads/main/lldp-mirror-worker.sh

chmod +x /var/lib/vz/snippets/lldp-launcher-hook.sh
chmod +x /usr/local/sbin/lldp-mirror-worker.sh
```

## Configuration

### Bridge Setup (Required)
```bash
# Add to /etc/network/interfaces for LLDP-enabled bridges:
auto vmbr11
iface vmbr11 inet manual
        bridge-ports eno1
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094
        bridge-group-fwd-mask 0x4000  # CRITICAL: Enables LLDP forwarding
        mtu 9000
```

### Guest Configuration
Add to VM or LXC config:

### Basic Examples
```bash
# Works with bridge-group-fwd-mask 0x4000:
lldp_mirror_net0=bond0      # Use bond if available
lldp_mirror_net1=vmbr11     # Bridge with LLDP forwarding enabled
lldp_mirror_net0=eno1       # Direct physical interface if no bridge
```

### Full VM Config Example
```bash
# For VM 114
nano /etc/pve/qemu-server/114.conf
hookscript: local:snippets/lldp-launcher-hook.sh
lldp_mirror_net0=bond0
lldp_mirror_net1=eno49,eno50
```

### Full LXC Config Example
```bash
# For LXC 101  
nano /etc/pve/lxc/101.conf
hookscript: local:snippets/lldp-launcher-hook.sh
lldp_mirror_net0=bond0
lldp_mirror_net1=eno1
```

## Interface Selection Guide

| Scenario | Bridge Config | Guest Config | Notes |
|----------|---------------|--------------|-------|
| 1GbE with LACP bond | `bridge-group-fwd-mask 0x4000` | `lldp_mirror_net0=bond0` | Standard setup |
| 1GbE without bond | `bridge-group-fwd-mask 0x4000` | `lldp_mirror_net0=eno1` | Direct physical |
| 10GbE bridge | `bridge-group-fwd-mask 0x4000` | `lldp_mirror_net1=vmbr11` | **Recommended** |
| 10GbE direct | N/A | `lldp_mirror_net1=eno1` | Bypass bridge |

**Recommended:** Use bridge mirroring (`vmbr11`) with proper `group_fwd_mask` for cleaner topology.

## How It Works (v9.0+)

- **Ingress**: Bridge with `group_fwd_mask 0x4000` automatically forwards LLDP to all ports
- **Egress**: TC mirror rule copies guest LLDP transmissions back to physical network  
- **Result**: Full bidirectional LLDP without complex multi-interface logic

## Legacy Multi-Interface Features

Previous versions supported complex multi-interface configurations. With proper bridge forwarding, this complexity is no longer needed - just use `lldp_mirror_net1=vmbr11`.

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
- **Multi-Interface:** Check primary interface rules with `tc filter show dev eno49 ingress`
- **LLDP Config:** Verify secondary TX disabled: `lldpcli show configuration ports eno50`

### Common Issues

- **No LLDP neighbors on multi-interface setup**: Check that secondary interfaces have TX disabled
- **Network storms**: Ensure proper LLDP TX configuration on secondary interfaces
- **Missing topology**: Verify primary interface has LLDP neighbors: `lldpcli show neighbors ports eno49`

---

**MIT License | Made for Proxmox Community**
