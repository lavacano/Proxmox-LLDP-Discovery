# Proxmox Universal LLDP Discovery Hook

**Automatically enable LLDP network discovery for both VMs and LXC containers on VLAN-aware bridges.**

A production-ready hookscript that solves LLDP (Link Layer Discovery Protocol) visibility issues in Proxmox VE by intelligently mirroring network discovery traffic. It automatically detects guest types and adapts, supporting both **QEMU/KVM VMs** and **LXC containers** seamlessly.

[![Proxmox VE 8.x](https://img.shields.io/badge/Proxmox%20VE-8.x-blue.svg)](https://www.proxmox.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![VM Support](https://img.shields.io/badge/QEMU%2FKVM-✓-green.svg)](https://www.qemu.org/)
[![LXC Support](https://img.shields.io/badge/LXC-✓-green.svg)](https://linuxcontainers.org/)

---

## 🎯 What Problem Does This Solve?

In virtualized environments using VLAN-aware bridges, both VMs and containers often lose network topology visibility. This script solves that by creating intelligent, bidirectional mirroring of LLDP traffic (EtherType `0x88cc`) between your host's physical bond interfaces and the guest's virtual interfaces.

- ✅ Solves LLDP visibility for guests on tagged VLANs.
- ✅ Enables accurate network mapping in tools like LibreNMS.
- ✅ Works for both QEMU/KVM VMs and LXC containers with the same configuration.
- ✅ Zero impact on regular network performance.

---

## ✨ Architecture: Launcher & Worker

This solution uses a robust two-script architecture to bypass limitations in the Proxmox hookscript execution environment:

1.  **Launcher (`lldp-launcher-hook.sh`):** A tiny script called directly by Proxmox. Its only job is to launch the main worker script in the background, preventing it from blocking VM operations.
2.  **Worker (`lldp-mirror-worker.sh`):** The "brains" of the operation. It runs in a clean shell environment and contains all the logic for guest detection, configuration parsing, `tc` rule management, logging, and service restarts.
```
### File Tree

/ (Proxmox Host Root)
|
|-- etc/
|   `-- pve/
|       |-- qemu-server/
|       |   |-- 100.conf          # Example VM Configuration
|       |
|       `-- lxc/
|           `-- 101.conf          # Example LXC Configuration
|
|-- usr/
|   `-- local/
|       `-- sbin/
|           `-- lldp-mirror-worker.sh  # The main "worker" script
|
`-- var/
    |-- lib/
    |   `-- vz/
    |       `-- snippets/
    |           `-- lldp-launcher-hook.sh # The tiny "launcher" script
    `-- log/
        `-- lldp-hook.log         # The log file created by the worker script
```

---

## 🚀 Quick Start

### 1. Install Dependencies on Proxmox Host
```bash
apt update && apt install lldpd iproute2
systemctl enable --now lldpd
```

### 2. Install the Scripts on Each Proxmox Host
```bash
# Create directories
mkdir -p /var/lib/vz/snippets
mkdir -p /usr/local/sbin

# Download and install the LAUNCHER script (replace with your actual URL)
wget -O /var/lib/vz/snippets/lldp-launcher-hook.sh <URL_TO_YOUR_LAUNCHER_SCRIPT>
chmod +x /var/lib/vz/snippets/lldp-launcher-hook.sh

# Download and install the WORKER script (replace with your actual URL)
wget -O /usr/local/sbin/lldp-mirror-worker.sh <URL_TO_YOUR_WORKER_SCRIPT>
chmod +x /usr/local/sbin/lldp-mirror-worker.sh
```

### 3. Configure Your Guests
The configuration syntax is **identical** for both VMs and LXC containers.

**Example for a VM (ID 114):**
```bash
# Edit VM config
nano /etc/pve/qemu-server/114.conf

# Add these lines at the bottom:
hookscript: local:snippets/lldp-launcher-hook.sh
lldp_mirror_net0=bond0
lldp_mirror_net1=bond1
```

**Example for an LXC Container (ID 101):**
```bash
# Edit container config
nano /etc/pve/lxc/101.conf

# Add these lines at the bottom:
hookscript: local:snippets/lldp-launcher-hook.sh
lldp_mirror_net0=bond0
```

### 4. Start the Guest & Verify
1.  Restart your VM or container to trigger the hookscript.
2.  Check the log on the Proxmox host: `tail -f /var/log/lldp-hook.log`.
3.  Inside the guest, install `lldpd` and check for neighbors: `lldpcli show neighbors`.

---

## 🔧 Configuration Reference

| Parameter | Format | Description | Example |
|-----------|---------|-------------|---------|
| `hookscript` | `local:snippets/script.sh` | Path to the **launcher** script | `local:snippets/lldp-launcher-hook.sh` |
| `lldp_mirror_net[X]` | `...=[bond_name]` | Mirror guest `net[X]` to physical `bond` | `lldp_mirror_net0=bond0` |

**Universal Interface Mapping Logic:**
- **VMs:** `lldp_mirror_net0` refers to the host's `tap[VMID]i0` interface.
- **LXC:** `lldp_mirror_net0` refers to the host's `veth[CTID]i0` interface.

---

## 🛠️ Troubleshooting

- **Primary Tool:** The log file on the host at `/var/log/lldp-hook.log`. It will tell you if the script ran, what guest type it detected, and the outcome of the `tc` commands.
- **`tc` Rules:** Manually check if rules were applied on the host: `tc filter show dev bond0 ingress`.
- **Inside the Guest:** Ensure `lldpd` is installed and running. Use `sudo tcpdump -i eth0 ether proto 0x88cc` to see if mirrored packets are arriving.

---

## 📄 License

This project is licensed under the MIT License.

---

**Made with ❤️ for the Proxmox community.**
