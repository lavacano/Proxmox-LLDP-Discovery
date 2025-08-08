#!/bin/bash

# =============================================================================
# Proxmox Universal LLDP Mirroring WORKER Script
# Version: 7.0 (External Config File Support)
#
# This script reads lldp_mirror_netX settings from a separate .lldp file
# to avoid Proxmox config parsing issues.
# =============================================================================

LOG_FILE="/var/log/lldp-hook.log"
VMID=$1
PHASE=$2

# --- Function Definitions ---
log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') - [VMID $VMID] $1" >> "$LOG_FILE"; }

detect_guest_type() {
    if [ -f "/etc/pve/qemu-server/${1}.conf" ]; then
        GUEST_TYPE="qemu"
        VM_CONF="/etc/pve/qemu-server/${1}.conf"
        LLDP_CONF="/etc/pve/qemu-server/${1}.lldp"
        INTERFACE_PREFIX="tap"
    elif [ -f "/etc/pve/lxc/${1}.conf" ]; then
        GUEST_TYPE="lxc"
        VM_CONF="/etc/pve/lxc/${1}.conf"
        LLDP_CONF="/etc/pve/lxc/${1}.lldp"
        INTERFACE_PREFIX="veth"
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

# Check for LLDP configuration file
if [ ! -f "$LLDP_CONF" ]; then
    log_message "No LLDP config file found at $LLDP_CONF. Nothing to do. Exiting."
    exit 0
fi

MIRROR_CONFIGS=$(grep '^lldp_mirror_net' "$LLDP_CONF")

if [ -z "$MIRROR_CONFIGS" ]; then
    log_message "No lldp_mirror_netX config found in $LLDP_CONF. Nothing to do. Exiting."
    exit 0
fi

log_message "Found mirror config in $LLDP_CONF. Proceeding with phase: $PHASE"

if [ "$PHASE" == "post-start" ]; then
    log_message "Applying TC rules (fire-and-forget)..."
    sleep 5 # Give interfaces time to come up

    while IFS='=' read -r key value; do
        # Sanitize input to remove Windows carriage returns and whitespace
        value_clean=$(echo "$value" | tr -d '\r' | sed 's/[[:space:]]//g')

        net_id=${key##*lldp_mirror_net}
        mirror_if="$value_clean"
        guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"

        if ip link show "$mirror_if" &>/dev/null && ip link show "$guest_if" &>/dev/null; then
            log_message "Configuring: $guest_if <-> $mirror_if"

            # Use the simple, known-good tc commands
            tc qdisc del dev "$mirror_if" ingress 2>/dev/null
            tc qdisc del dev "$guest_if" ingress 2>/dev/null
            tc qdisc add dev "$mirror_if" ingress &>> "$LOG_FILE"
            tc qdisc add dev "$guest_if" ingress &>> "$LOG_FILE"

            # The simple "match-all" u32 filter
            tc filter add dev "$mirror_if" parent ffff: protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$guest_if" &>> "$LOG_FILE"
            tc filter add dev "$guest_if" parent ffff: protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$mirror_if" &>> "$LOG_FILE"

            log_message "SUCCESS: TC filter commands executed for $mirror_if."

        else
            log_message "ERROR: Interface missing for $guest_if or $mirror_if"
        fi
    done <<< "$MIRROR_CONFIGS"

    log_message "All filters applied. Restarting host lldpd."
    systemctl restart lldpd.service
fi

if [ "$PHASE" == "pre-stop" ]; then
    log_message "Cleaning up TC rules..."
    while IFS='=' read -r key value; do
        # Sanitize the input value to remove carriage returns and whitespace
        value_clean=$(echo "$value" | tr -d '\r' | sed 's/[[:space:]]//g')
        mirror_if="$value_clean"
        tc qdisc del dev "$mirror_if" ingress 2>/dev/null
    done <<< "$MIRROR_CONFIGS"

    log_message "Waiting for kernel to stabilize interfaces after cleanup..."
    sleep 2 # Add a 2-second pause

    log_message "Restarting host lldpd after cleanup."
    systemctl restart lldpd.service
fi

log_message "Worker finished for Phase: $PHASE"
exit 0
