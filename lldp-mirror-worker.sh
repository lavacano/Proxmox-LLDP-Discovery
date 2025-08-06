#!/bin/bash

# =============================================================================
# Proxmox Universal LLDP Mirroring WORKER Script
# Version: 6.0 (Self-Configuring)
#
# This script is launched by a simple hookscript. It determines the guest
# type (VM/LXC) and reads lldp_mirror_netX settings from the guest's own
# config file to apply the necessary tc mirroring rules.
# =============================================================================

LOG_FILE="/var/log/lldp-hook.log"
VMID=$1
PHASE=$2

# --- Function Definitions ---
log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') - [VMID $VMID] $1" >> "$LOG_FILE"; }

detect_guest_type() {
    if [ -f "/etc/pve/qemu-server/${1}.conf" ]; then
        GUEST_TYPE="qemu"; VM_CONF="/etc/pve/qemu-server/${1}.conf"; INTERFACE_PREFIX="tap"
    elif [ -f "/etc/pve/lxc/${1}.conf" ]; then
        GUEST_TYPE="lxc"; VM_CONF="/etc/pve/lxc/${1}.conf"; INTERFACE_PREFIX="veth"
    else
        return 1
    fi
    return 0
}

# --- Main Script Execution ---
log_message "Worker started for Phase: $PHASE"

if ! detect_guest_type "$VMID"; then
    log_message "Could not find config for VM/CT. Exiting."
    exit 0
fi

MIRROR_CONFIGS=$(grep '^lldp_mirror_net' "$VM_CONF")

if [ -z "$MIRROR_CONFIGS" ]; then
    log_message "No lldp_mirror_netX config found. Nothing to do. Exiting."
    exit 0
fi

log_message "Found mirror config. Proceeding with phase: $PHASE"

if [ "$PHASE" == "post-start" ]; then
    log_message "Applying TC rules (fire-and-forget)..."
    sleep 5 # Give interfaces time to come up

    while IFS='=' read -r key value; do
        # Sanitize input to remove Windows carriage returns
        value_clean=$(echo "$value" | tr -d '\r')

        net_id=${key##*lldp_mirror_net}
        bond_if=${value_clean//[[:space:]]/}
        guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"

        if ip link show "$bond_if" &>/dev/null && ip link show "$guest_if" &>/dev/null; then
            log_message "Configuring: $guest_if <-> $bond_if"

            # Use the simple, known-good tc commands
            tc qdisc del dev "$bond_if" ingress 2>/dev/null
            tc qdisc del dev "$guest_if" ingress 2>/dev/null
            tc qdisc add dev "$bond_if" ingress &>> "$LOG_FILE"
            tc qdisc add dev "$guest_if" ingress &>> "$LOG_FILE"

            # The simple "match-all" u32 filter
            tc filter add dev "$bond_if" parent ffff: protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$guest_if" &>> "$LOG_FILE"
            tc filter add dev "$guest_if" parent ffff: protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$bond_if" &>> "$LOG_FILE"

            log_message "SUCCESS: TC filter commands executed for $bond_if."

        else
            log_message "ERROR: Interface missing for $guest_if or $bond_if"
        fi
    done <<< "$MIRROR_CONFIGS"

    log_message "All filters applied. Restarting host lldpd."
    systemctl restart lldpd.service
fi

if [ "$PHASE" == "pre-stop" ]; then
    log_message "Cleaning up TC rules..."
    while IFS='=' read -r key value; do
        # Sanitize the input value to remove carriage returns
        value_clean=$(echo "$value" | tr -d '\r')
        bond_if=${value_clean//[[:space:]]/}
        tc qdisc del dev "$bond_if" ingress 2>/dev/null
    done <<< "$MIRROR_CONFIGS"

    log_message "Waiting for kernel to stabilize interfaces after cleanup..."
    sleep 2 # Add a 2-second pause

    log_message "Restarting host lldpd after cleanup."
    systemctl restart lldpd.service
fi

log_message "Worker finished for Phase: $PHASE"
exit 0
