# Proxmox Stateful LLDP Mirroring Hookscript

[![Proxmox VE 8.x](https://img.shields.io/badge/Proxmox%20VE-8.x-blue.svg)](https://www.proxmox.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/Bash-4.0+-lightgrey.svg)](https://www.gnu.org/software/bash/)

A robust, stateful Proxmox hookscript that makes VMs and LXC containers visible to your physical network switches via LLDP by creating bidirectional traffic control (`tc`) mirrors.

This script is idempotent, non-destructive, and safe for production environments, as it manages its own `tc` rules without interfering with other system configurations.

## The Problem

By default, Proxmox's Linux bridges do not forward LLDP packets between guests and the physical network. This makes your VMs and containers "invisible" to your network switches, leading to incomplete network topology maps, inaccurate monitoring, and difficulties with network automation.

## The Solution

This hookscript intelligently manages `tc` filter rules to mirror LLDP traffic between a guest's virtual interface (`tap` for VMs, `veth` for containers) and a specified physical host interface (e.g., a physical NIC, a bond, or a bridge).

### Key Features

-   **Universal Support:** Works for both **QEMU/KVM VMs** and **LXC containers**.
-   **Stateful & Idempotent:** Intelligently checks the current state before acting. It will only add or remove rules if needed, making it safe to run multiple times.
-   **Non-Destructive:** Creates and removes its own specific `tc` rules by capturing their unique kernel-assigned handles. It will **not** interfere with or delete other QoS or filtering rules on your interfaces.
-   **Robust:** Handles interface timing races with polling, is immune to Proxmox config file sanitization, and has no external dependencies beyond standard system utilities.
-   **Syslog Integration:** Logs all actions to the system's journal for easy monitoring and debugging with `journalctl`.

## Requirements

-   Proxmox VE (tested on 8.x)
-   `lldpd` and `iproute2` packages installed on the Proxmox host.
-   Bash v4.0 or newer.

## Installation

1.  **Install Dependencies:**
    ```bash
    apt update
    apt install -y lldpd iproute2
    ```

2.  **Download the Hookscript:**
    Download the script to `/usr/local/sbin/` and make it executable.

    ```bash
    wget -O /usr/local/sbin/pve-lldp-hook.sh https://raw.githubusercontent.com/lavacano/Proxmox-LLDP-Discovery/refs/heads/main/pve-lldp-hook.sh
    chmod +x /usr/local/sbin/pve-lldp-hook.sh
    ```

## Configuration

Configuration is a two-step process: **enabling the hookscript** for a guest and **creating its LLDP config file**.

#### 1. Enable the Hookscript for a Guest

For each VM or container, run the corresponding command to enable the hookscript.

-   **For a VM (e.g., VMID 101):**
    ```bash
    qm set 101 --hookscript local:usr/local/sbin/pve-lldp-hook.sh
    ```

-   **For an LXC Container (e.g., CTID 202):**
    ```bash
    pct set 202 --hookscript /usr/local/sbin/pve-lldp-hook.sh
    ```

#### 2. Create the LLDP Configuration File

The script reads its configuration from a dedicated `.lldp` file, which you must create. This file tells the script which guest network interface should be mirrored to which host interface.

-   **For a VM (e.g., VMID 101, guest `net0` -> host `bond0`):**
    ```bash
    echo "lldp_mirror_net0=bond0" > /etc/pve/qemu-server/101.lldp
    ```

-   **For an LXC Container (e.g., CTID 202, guest `net0` -> host `vmbr0`):**
    ```bash
    echo "lldp_mirror_net0=vmbr0" > /etc/pve/lxc/202.lldp
    ```

-   **Multiple Interfaces:** To mirror more than one interface, simply add more lines to the file. You can also add comments.
    ```
    # Main LAN connection
    lldp_mirror_net0=bond0

    # High-speed storage network
    lldp_mirror_net1=eno49
    ```

Restart your VM or container to apply the changes.

## Troubleshooting

The script logs all its actions to the system journal with the tag `lldp-hook`. Use `journalctl` to monitor its activity.

```bash
# Follow the logs for the hookscript in real-time
journalctl -fu lldp-hook

# Check the current tc filter rules on a host interface (e.g., bond0)
tc filter show dev bond0 ingress

# Check the ephemeral state file for a running VM (which stores tc handles)
cat /var/run/lldp-hook/101.state
```

## How It Works

1.  **Trigger:** The Proxmox hook system executes the script during guest `post-start` and `pre-stop` phases.
2.  **Read Config:** The script reads the desired mirror rules from the guest's dedicated `.lldp` file.
3.  **Check State:** It queries `tc` to determine the current running mirror rules on the system.
4.  **Act:**
    -   On **start**, it compares the desired state to the running state. If a rule is missing, it creates it, captures its unique kernel-assigned handle, and saves the handle to a state file in `/var/run/lldp-hook/`.
    -   On **stop**, it reads the saved handles from the state file and surgically removes only the specific filters it created.
5.  **Verify:** After every action, it re-queries `tc` to verify that the operation was successful.

## License

This script is licensed under the **MIT License**.
