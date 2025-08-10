#!/bin/bash

# =============================================================================
# Proxmox Bidirectional LLDP Mirroring WORKER Script
# Version: 8.1 (Hybrid)
#
# This script applies bidirectional tc rules to mirror LLDP traffic between
# a physical host interface and a guest's virtual TAP interface.
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

extract_and_manage_lldp_config() {
    local main_mirror_configs=$(grep '^lldp_mirror_net' "$VM_CONF" 2>/dev/null)
    if [ -n "$main_mirror_configs" ]; then
        echo "$main_mirror_configs" > "$LLDP_CONF"
        grep -v '^lldp_mirror_net' "$VM_CONF" > "${VM_CONF}.tmp" && mv "${VM_CONF}.tmp" "$VM_CONF"
        log_message "Managed lldp_mirror_netX config in ${LLDP_CONF}"
        return 0
    elif [ -f "$LLDP_CONF" ]; then
        return 0
    else
        log_message "No lldp_mirror_netX config found."
        return 1
    fi
}

# --- Main Script Execution ---
log_message "Worker started for Phase: $PHASE"

if ! detect_guest_type "$VMID"; then
    log_message "Could not find config for VM/CT. Exiting."
    exit 0
fi

if ! extract_and_manage_lldp_config; then
    exit 0
fi

MIRROR_CONFIGS=$(cat "$LLDP_CONF")
if [ -z "$MIRROR_CONFIGS" ]; then
    log_message "LLDP config file is empty. Nothing to do. Exiting."
    exit 0
fi

if [ "$PHASE" == "post-start" ]; then
    log_message "Applying bidirectional TC rules..."

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
        value_clean=$(echo "$value" | tr -d '\r' | sed 's/[[:space:]]//g')
        net_id=${key##*lldp_mirror_net}
        mirror_if="$value_clean"
        guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"

        # Wait for the guest interface to appear
        wait_seconds=30
        interface_ready=false
        for ((i=0; i<wait_seconds; i++)); do
            if ip link show "$guest_if" &>/dev/null; then
                log_message "Interface $guest_if is up."
                interface_ready=true
                break
            fi
            sleep 1
        done

        if ! $interface_ready; then
            log_message "ERROR: Interface $guest_if did not appear after ${wait_seconds} seconds. Aborting."
            continue
        fi

        if ip link show "$mirror_if" &>/dev/null; then
            log_message "Configuring: $guest_if <-> $mirror_if"

            # Ensure ingress qdisc exists on both interfaces
            tc qdisc add dev "$mirror_if" ingress 2>/dev/null
            tc qdisc add dev "$guest_if" ingress 2>/dev/null

            # Rule 1: Ingress (Physical -> Guest)
            pref_in=$((10000 + VMID))
            tc filter add dev "$mirror_if" parent ffff: protocol 0x88cc pref "$pref_in" u32 match u32 0 0 \
                action mirred egress mirror dev "$guest_if" &>> "$LOG_FILE"
            log_message "SUCCESS: Ingress rule applied ($mirror_if -> $guest_if)."

            # Rule 2: Egress (Guest -> Physical)
            pref_out=$((20000 + VMID))
            tc filter add dev "$guest_if" parent ffff: protocol 0x88cc pref "$pref_out" u32 match u32 0 0 \
                action mirred egress mirror dev "$mirror_if" &>> "$LOG_FILE"
            log_message "SUCCESS: Egress rule applied ($guest_if -> $mirror_if)."
        else
            log_message "ERROR: Physical interface $mirror_if does not exist."
        fi
    done <<< "$MIRROR_CONFIGS"
fi

if [ "$PHASE" == "pre-stop" ]; then
    log_message "Cleaning up TC rules for stopping VM..."
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

        value_clean=$(echo "$value" | tr -d '\r' | sed 's/[[:space:]]//g')
        net_id=${key##*lldp_mirror_net}
        mirror_if="$value_clean"
        guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"

        # Delete Ingress Rule
        pref_in=$((10000 + VMID))
        if tc filter show dev "$mirror_if" ingress 2>/dev/null | grep -q "pref $pref_in"; then
            log_message "Deleting INGRESS filter with pref $pref_in from $mirror_if."
            tc filter del dev "$mirror_if" parent ffff: pref "$pref_in" u32 &>> "$LOG_FILE"
        fi
        
        # Delete Egress Rule
        pref_out=$((20000 + VMID))
        if ip link show "$guest_if" &>/dev/null && tc filter show dev "$guest_if" ingress 2>/dev/null | grep -q "pref $pref_out"; then
            log_message "Deleting EGRESS filter with pref $pref_out from $guest_if."
            tc filter del dev "$guest_if" parent ffff: pref "$pref_out" u32 &>> "$LOG_FILE"
        fi
    done <<< "$MIRROR_CONFIGS"
fi

log_message "Worker finished for Phase: $PHASE"
exit 0
