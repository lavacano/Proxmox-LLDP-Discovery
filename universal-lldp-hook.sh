#!/usr/bin/env bash

# =============================================================================
# Proxmox Universal LLDP Mirroring Hookscript (VM + LXC Support)
#
# Author: Community Script (Enhanced for Universal Support)
# Version: 4.2.0 2024-08-06
# Compatible: Proxmox VE 8.x
# License: MIT
#
# This script supports both QEMU/KVM VMs and LXC containers by detecting
# the guest type and adapting interface naming and configuration paths.
#
# Changelog v4.2.0:
# - Expanded all single-line functions for improved readability and maintainability.
# - Added comments to clarify logic within functions.
# - Final production-ready version based on comprehensive testing and feedback.
# =============================================================================

# --- Script Configuration ---
LOG_FILE="/var/log/lldp-hook.log"
VERBOSE=true
MAX_LOG_SIZE_KB=1024
DRY_RUN=false

# --- Version Information ---
SCRIPT_VERSION="4.2.0"
SCRIPT_DATE="2024-08-06"

# --- Proxmox-Provided Arguments ---
VMID=$1
PHASE=$2

# --- Global Variables ---
GUEST_TYPE=""
VM_CONF=""
INTERFACE_PREFIX=""

# --- Function Definitions ---

log_message() {
    local message="$1"
    local priority="${2:-info}"
    
    if [ "$VERBOSE" = true ]; then
        local log_dir
        log_dir=$(dirname "$LOG_FILE")
        [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null
        
        if ! touch "$LOG_FILE" 2>/dev/null; then
            echo "LLDP-Hook: $message" >&2
            return 1
        fi
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
        logger -t "lldp-hook[$$]" -p "daemon.$priority" "$message" 2>/dev/null || true
    fi
}

detect_guest_type() {
    local vmid="$1"
    
    if [ -f "/etc/pve/qemu-server/${vmid}.conf" ]; then
        GUEST_TYPE="qemu"
        VM_CONF="/etc/pve/qemu-server/${vmid}.conf"
        INTERFACE_PREFIX="tap"
        log_message "Detected QEMU/KVM virtual machine (VMID: $vmid)" "info"
        return 0
    elif [ -f "/etc/pve/lxc/${vmid}.conf" ]; then
        GUEST_TYPE="lxc"
        VM_CONF="/etc/pve/lxc/${vmid}.conf"
        INTERFACE_PREFIX="veth"
        log_message "Detected LXC container (CTID: $vmid)" "info"
        return 0
    else
        log_message "ERROR: No configuration file found for ID $vmid (checked both VM and LXC)" "err"
        return 1
    fi
}

validate_interface() {
    local interface="$1"
    
    if ! ip link show "$interface" &>/dev/null; then
        return 1
    fi
    
    local operstate carrier interface_type
    operstate=$(cat "/sys/class/net/$interface/operstate" 2>/dev/null || echo "unknown")
    carrier=$(cat "/sys/class/net/$interface/carrier" 2>/dev/null || echo "unknown")
    
    if [[ "$interface" == tap* ]]; then
        interface_type="TAP (VM)"
    elif [[ "$interface" == veth* ]]; then
        interface_type="veth (LXC)"
    else
        interface_type="Physical"
    fi
    
    log_message "Interface $interface ($interface_type) state: $operstate, carrier: $carrier" "debug"
    
    if [ "$operstate" = "down" ]; then
        log_message "WARNING: Interface $interface exists but is DOWN" "warning"
    fi
    
    return 0
}

# HYBRID KERNEL-AWARE: TC setup that tries modern 'flower' classifier
# and falls back to legacy 'u32' if verification fails.
setup_tc_link() {
    local bond_if="$1"
    local guest_if="$2"

    log_message "Setting up TC link for $bond_if <-> $guest_if ($GUEST_TYPE)" "info"
    
    if [ "$DRY_RUN" = true ]; then
        log_message "DRY RUN: Would set up TC mirroring for $bond_if <-> $guest_if" "info"
        return 0
    fi
    
    if ! validate_interface "$bond_if"; then log_message "ERROR: Bond interface $bond_if does not exist" "err"; return 1; fi
    if ! validate_interface "$guest_if"; then log_message "ERROR: Guest interface $guest_if does not exist" "err"; return 1; fi

    # Ensure ingress qdiscs exist
    if ! tc qdisc replace dev "$bond_if" ingress 2>>"$LOG_FILE"; then log_message "ERROR: Failed to replace ingress qdisc on $bond_if" "err"; return 1; fi
    if ! tc qdisc replace dev "$guest_if" ingress 2>>"$LOG_FILE"; then log_message "ERROR: Failed to replace ingress qdisc on $guest_if" "err"; tc qdisc del dev "$bond_if" ingress 2>/dev/null || true; return 1; fi

    # --- ATTEMPT 1: Use the modern 'flower' classifier ---
    log_message "Attempting TC setup with 'flower' classifier..." "debug"
    tc filter replace dev "$bond_if" parent ffff: prio 1 protocol 0x88cc flower action mirred egress mirror dev "$guest_if" &>>"$LOG_FILE"
    tc filter replace dev "$guest_if" parent ffff: prio 1 protocol 0x88cc flower action mirred egress mirror dev "$bond_if" &>>"$LOG_FILE"

    # Verify if 'flower' worked
    sleep 1
    if tc filter show dev "$bond_if" parent ffff: | grep -q "mirred egress mirror dev $guest_if"; then
        log_message "SUCCESS: 'flower' classifier worked. TC filters are active." "info"
        return 0 # Success! We are done.
    fi

    # --- ATTEMPT 2: Fallback to the legacy 'u32' classifier ---
    log_message "WARNING: 'flower' classifier failed verification. Falling back to legacy 'u32' classifier." "warning"
    tc filter replace dev "$bond_if" parent ffff: prio 1 protocol 0x88cc u32 match u8 0 0 action mirred egress mirror dev "$guest_if" &>>"$LOG_FILE"
    tc filter replace dev "$guest_if" parent ffff: prio 1 protocol 0x88cc u32 match u8 0 0 action mirred egress mirror dev "$bond_if" &>>"$LOG_FILE"

    # Verify if 'u32' worked
    sleep 1
    if ! tc filter show dev "$bond_if" parent ffff: | grep -q "mirred egress mirror dev $guest_if"; then
        log_message "FATAL ERROR: Both 'flower' and 'u32' classifiers failed to apply TC filter on $bond_if." "err"
        cleanup_tc_link "$bond_if"
        cleanup_tc_link "$guest_if"
        return 1
    fi

    log_message "SUCCESS: Legacy 'u32' classifier worked. TC filters are active." "info"
    return 0
}

cleanup_tc_link() {
    local interface="$1"
    
    if [ -z "$interface" ]; then
        log_message "ERROR: No interface specified for cleanup" "err"
        return 1
    fi
    
    log_message "Cleaning up TC qdisc for $interface" "info"
    
    if [ "$DRY_RUN" = true ]; then
        log_message "DRY RUN: Would clean up TC rules for $interface" "info"
        return 0
    fi
    
    if ip link show "$interface" &>/dev/null; then
        if tc qdisc del dev "$interface" ingress 2>/dev/null; then
            log_message "Successfully removed TC qdisc from $interface" "info"
        else
            log_message "No TC qdisc to remove on $interface" "debug"
        fi
    else
        log_message "Interface $interface no longer exists, skipping cleanup" "debug"
    fi
}

restart_lldp_service() {
    log_message "Managing host lldpd service" "info"
    
    if [ "$DRY_RUN" = true ]; then
        log_message "DRY RUN: Would restart lldpd service" "info"
        return 0
    fi
    
    if ! systemctl list-unit-files lldpd.service &>/dev/null; then
        log_message "WARNING: lldpd.service not found on this system" "warning"
        return 1
    fi
    
    if timeout 30 systemctl restart lldpd.service &>>"$LOG_FILE"; then
        log_message "Successfully restarted lldpd service" "info"
        sleep 2
        if systemctl is-active lldpd.service &>/dev/null; then
            log_message "lldpd service is active and running" "info"
        else
            log_message "WARNING: lldpd service is not active after restart" "warning"
        fi
    else
        log_message "ERROR: Failed to restart lldpd service within 30 seconds" "err"
        return 1
    fi
    
    return 0
}

parse_mirror_configs() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log_message "ERROR: Config file $config_file not found" "err"
        return 1
    fi
    
    local configs
    configs=$(awk '
        /^[[:space:]]*lldp_mirror_net[0-9]+[[:space:]]*=/ {
            if ($0 !~ /^[[:space:]]*#/) {
                sub(/^[[:space:]]*/, "");
                sub(/[[:space:]]*$/, "");
                print;
            }
        }
    ' "$config_file")
    
    if [ -n "$configs" ]; then
        log_message "Parsed $GUEST_TYPE configuration:" "debug"
        echo "$configs" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                log_message "  $line" "debug"
            fi
        done
    fi
    
    echo "$configs"
}

wait_for_interfaces() {
    local max_wait=30
    local wait_interval=2
    local waited=0
    
    log_message "Waiting for $GUEST_TYPE interfaces to be ready (max ${max_wait}s)..." "info"
    
    while [ $waited -lt $max_wait ]; do
        local all_ready=true
        local missing_interfaces=()
        
        while IFS='=' read -r key value; do
            if [ -n "$key" ] && [ -n "$value" ]; then
                local net_id bond_if guest_if
                net_id=${key##*lldp_mirror_net}
                bond_if=$(echo "$value" | tr -d '[:space:]')
                guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"
                
                if ! validate_interface "$bond_if"; then
                    all_ready=false
                    missing_interfaces+=("$bond_if")
                fi
                
                if ! validate_interface "$guest_if"; then
                    all_ready=false
                    missing_interfaces+=("$guest_if")
                fi
            fi
        done <<< "$MIRROR_CONFIGS"
        
        if [ "$all_ready" = true ]; then
            log_message "All required $GUEST_TYPE interfaces are ready" "info"
            return 0
        fi
        
        if [ ${#missing_interfaces[@]} -gt 0 ]; then
            log_message "Still waiting for: ${missing_interfaces[*]} (${waited}s/${max_wait}s)" "debug"
        fi
        
        sleep $wait_interval
        waited=$((waited + wait_interval))
    done
    
    log_message "WARNING: Timeout waiting for interfaces after ${max_wait}s, proceeding anyway" "warning"
    return 1
}

# --- Main Script Execution ---

log_message "=== Universal LLDP Hookscript v$SCRIPT_VERSION started ===" "info"
log_message "Processing ID: $VMID, Phase: $PHASE" "info"

if [ -z "$VMID" ] || [ -z "$PHASE" ]; then
    log_message "ERROR: Missing required arguments. Usage: $0 <VMID> <PHASE>" "err"
    exit 1
fi

if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    log_message "ERROR: Invalid VMID format: '$VMID' (must be numeric)" "err"
    exit 1
fi

if ! detect_guest_type "$VMID"; then
    log_message "No valid configuration found for ID $VMID. Exiting gracefully." "info"
    exit 0
fi

MIRROR_CONFIGS=$(parse_mirror_configs "$VM_CONF")

if [ -z "$MIRROR_CONFIGS" ]; then
    log_message "No 'lldp_mirror_netX' config found for $GUEST_TYPE $VMID. Nothing to do." "info"
    exit 0
fi

log_message "Found LLDP mirror configurations for $GUEST_TYPE $VMID:" "info"
echo "$MIRROR_CONFIGS" | while IFS= read -r line; do
    if [ -n "$line" ]; then
        log_message "  $line" "info"
    fi
done

case "$PHASE" in
    post-start)
        log_message "Phase is post-start. Applying TC rules for $GUEST_TYPE." "info"
        
        if [ "$DRY_RUN" = false ]; then
            wait_for_interfaces
        fi
        
        setup_errors=0
        
        while IFS='=' read -r key value; do
            if [ -z "$key" ] || [ -z "$value" ]; then
                continue
            fi
            
            net_id=${key##*lldp_mirror_net}
            bond_if=$(echo "$value" | tr -d '[:space:]')
            guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"

            if [ -z "$net_id" ] || [ -z "$bond_if" ] || ! [[ "$net_id" =~ ^[0-9]+$ ]]; then
                log_message "ERROR: Invalid configuration - key: '$key', value: '$value'" "err"
                setup_errors=$((setup_errors + 1))
                continue
            fi
            
            log_message "Configuring: $GUEST_TYPE net$net_id ($guest_if) <-> bond $bond_if" "info"
            
            if ! setup_tc_link "$bond_if" "$guest_if"; then
                setup_errors=$((setup_errors + 1))
            fi
        done <<< "$MIRROR_CONFIGS"

        if ! restart_lldp_service; then
            log_message "LLDP service restart failed, but continuing" "warning"
        fi

        if [ $setup_errors -gt 0 ]; then
            log_message "WARNING: $setup_errors interface(s) failed to set up properly" "warning"
            exit 1
        else
            log_message "All LLDP mirror configurations applied successfully for $GUEST_TYPE $VMID" "info"
        fi
        ;;

    pre-stop)
        log_message "Phase is pre-stop. Cleaning up TC rules for $GUEST_TYPE." "info"

        readarray -t unique_bond_ifs < <(echo "$MIRROR_CONFIGS" | cut -d'=' -f2 | tr -d '[:space:]' | sort -u)

        if [ ${#unique_bond_ifs[@]} -gt 0 ]; then
            log_message "Cleaning up ${#unique_bond_ifs[@]} unique bond interface(s): ${unique_bond_ifs[*]}" "info"
            
            for bond_if in "${unique_bond_ifs[@]}"; do
                if [ -n "$bond_if" ]; then
                    cleanup_tc_link "$bond_if"
                fi
            done
        fi
        
        if ! restart_lldp_service; then
            log_message "LLDP service restart failed during cleanup" "warning"
        fi
        ;;

    pre-start|post-stop)
        log_message "Phase is '$PHASE'. No action required. Exiting gracefully." "info"
        exit 0
        ;;
        
    *)
        log_message "ERROR: Unknown phase: '$PHASE'. Supported phases: pre-start, post-start, pre-stop, post-stop" "err"
        exit 1
        ;;
esac

log_message "=== Universal LLDP Hookscript v$SCRIPT_VERSION finished for $GUEST_TYPE $VMID ===" "info"
exit 0
