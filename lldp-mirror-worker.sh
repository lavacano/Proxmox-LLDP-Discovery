#!/bin/bash

# =============================================================================
# Proxmox Universal LLDP Mirroring WORKER Script
# Version: 8.1 (Multi-Interface Support)
#
# Enhanced to support multiple source interfaces with storm prevention
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
    # Extract LLDP mirror configurations from main config
    local main_mirror_configs=$(grep '^lldp_mirror_net' "$VM_CONF" 2>/dev/null)
    
    if [ -n "$main_mirror_configs" ]; then
        log_message "Found lldp_mirror_netX in main config. Managing in separate .lldp file."
        
        # Create/update the .lldp file
        echo "$main_mirror_configs" > "$LLDP_CONF"
        
        # Create a cleaned config without lldp_mirror lines
        local temp_conf=$(mktemp)
        grep -v '^lldp_mirror_net' "$VM_CONF" > "$temp_conf"
        
        # Only update main config if it actually contains lldp_mirror lines
        if ! cmp -s "$VM_CONF" "$temp_conf"; then
            log_message "Removing lldp_mirror_netX from main config to prevent parsing errors."
            cp "$temp_conf" "$VM_CONF"
        fi
        
        rm -f "$temp_conf"
        return 0
    else
        # No lldp_mirror in main config, check if .lldp file exists
        if [ -f "$LLDP_CONF" ]; then
            log_message "Using existing .lldp file."
            return 0
        else
            log_message "No lldp_mirror_netX config found in main config or .lldp file."
            return 1
        fi
    fi
}

# NEW: Parse multiple interfaces from comma-separated value
parse_mirror_interfaces() {
    local value="$1"
    echo "$value" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# NEW: Check if interface has active LLDP neighbors
has_lldp_neighbors() {
    local interface="$1"
    lldpcli show neighbors ports "$interface" 2>/dev/null | grep -q "Interface:"
}

# NEW: Apply multi-interface mirroring with storm prevention
apply_multi_interface_mirroring() {
    local guest_if="$1"
    local interfaces_str="$2"
    
    # Parse interfaces into array
    local interfaces=()
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && interfaces+=("$iface")
    done < <(parse_mirror_interfaces "$interfaces_str")
    
    local num_interfaces=${#interfaces[@]}
    log_message "Configuring multi-interface mirroring: $guest_if with ${num_interfaces} sources"
    
    if [ "$num_interfaces" -eq 1 ]; then
        # Single interface - use original logic
        local mirror_if="${interfaces[0]}"
        log_message "Single interface mode: $guest_if <-> $mirror_if"
        
        tc qdisc del dev "$mirror_if" ingress 2>/dev/null
        tc qdisc del dev "$guest_if" ingress 2>/dev/null
        tc qdisc add dev "$mirror_if" ingress &>> "$LOG_FILE"
        tc qdisc add dev "$guest_if" ingress &>> "$LOG_FILE"
        
        tc filter add dev "$mirror_if" parent ffff: protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$guest_if" &>> "$LOG_FILE"
        tc filter add dev "$guest_if" parent ffff: protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$mirror_if" &>> "$LOG_FILE"
        
    elif [ "$num_interfaces" -gt 1 ]; then
        # Multiple interfaces - use primary/secondary with rate limiting
        log_message "Multi-interface mode: Using primary/secondary logic with rate limiting"
        
        # Set up guest interface qdisc
        tc qdisc del dev "$guest_if" ingress 2>/dev/null
        tc qdisc add dev "$guest_if" ingress &>> "$LOG_FILE"
        
        local primary_if=""
        local secondary_interfaces=()
        
        # Find primary interface (first one with LLDP neighbors, or just first one)
        for iface in "${interfaces[@]}"; do
            if [ -z "$primary_if" ]; then
                if has_lldp_neighbors "$iface" || [ ${#interfaces[@]} -eq 1 ]; then
                    primary_if="$iface"
                    log_message "Selected primary interface: $primary_if"
                else
                    secondary_interfaces+=("$iface")
                fi
            else
                secondary_interfaces+=("$iface")
            fi
        done
        
        # If no interface had neighbors, use first as primary
        if [ -z "$primary_if" ]; then
            primary_if="${interfaces[0]}"
            secondary_interfaces=("${interfaces[@]:1}")
        fi
        
        # Configure primary interface with normal rate
        tc qdisc del dev "$primary_if" ingress 2>/dev/null
        tc qdisc add dev "$primary_if" ingress &>> "$LOG_FILE"
        
        # Primary: Normal LLDP mirroring with basic rate limit
        tc filter add dev "$primary_if" parent ffff: protocol 0x88cc \
            u32 match u32 0 0 \
            action police rate 30pps burst 10 continue \
            action mirred egress mirror dev "$guest_if" &>> "$LOG_FILE"
        
        # Guest to primary: Normal mirroring
        tc filter add dev "$guest_if" parent ffff: protocol 0x88cc \
            u32 match u32 0 0 \
            action mirred egress mirror dev "$primary_if" &>> "$LOG_FILE"
        
        # Configure secondary interfaces with reduced rate
        for sec_if in "${secondary_interfaces[@]}"; do
            if ip link show "$sec_if" &>/dev/null; then
                log_message "Configuring secondary interface: $sec_if (reduced rate)"
                
                tc qdisc del dev "$sec_if" ingress 2>/dev/null
                tc qdisc add dev "$sec_if" ingress &>> "$LOG_FILE"
                
                # Secondary: Reduced rate to prevent storms
                tc filter add dev "$sec_if" parent ffff: protocol 0x88cc \
                    u32 match u32 0 0 \
                    action police rate 5pps burst 2 continue \
                    action mirred egress mirror dev "$guest_if" &>> "$LOG_FILE"
            fi
        done
        
        log_message "Multi-interface mirroring configured: Primary=$primary_if, Secondary=[${secondary_interfaces[*]}]"
    fi
}

# --- Main Script Execution ---
log_message "Worker started for Phase: $PHASE"

if ! detect_guest_type "$VMID"; then
    log_message "Could not find config for VM/CT. Exiting."
    exit 0
fi

# Extract and manage LLDP configuration
if ! extract_and_manage_lldp_config; then
    log_message "No LLDP mirror configuration found. Nothing to do. Exiting."
    exit 0
fi

# Read mirror configurations from .lldp file
MIRROR_CONFIGS=$(cat "$LLDP_CONF")

if [ -z "$MIRROR_CONFIGS" ]; then
    log_message "LLDP config file is empty. Nothing to do. Exiting."
    exit 0
fi

log_message "Found mirror config in $LLDP_CONF. Proceeding with phase: $PHASE"

if [ "$PHASE" == "post-start" ]; then
    log_message "Applying TC rules (enhanced multi-interface support)..."
    sleep 5 # Give interfaces time to come up

    while IFS='=' read -r key value; do
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
        # Sanitize input to remove Windows carriage returns and whitespace
        value_clean=$(echo "$value" | tr -d '\r' | sed 's/[[:space:]]//g')

        net_id=${key##*lldp_mirror_net}
        interfaces_str="$value_clean"
        guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"

        if ip link show "$guest_if" &>/dev/null; then
            log_message "Processing: $guest_if -> [$interfaces_str]"
            
            # Check if all specified interfaces exist
            local all_exist=true
            while IFS= read -r iface; do
                if [[ -n "$iface" ]] && ! ip link show "$iface" &>/dev/null; then
                    log_message "ERROR: Interface $iface does not exist"
                    all_exist=false
                fi
            done < <(parse_mirror_interfaces "$interfaces_str")
            
            if [ "$all_exist" = true ]; then
                apply_multi_interface_mirroring "$guest_if" "$interfaces_str"
            else
                log_message "ERROR: Some interfaces missing for $guest_if"
            fi
        else
            log_message "ERROR: Guest interface $guest_if does not exist"
        fi
    done <<< "$MIRROR_CONFIGS"

    log_message "All filters applied. Restarting host lldpd."
    systemctl restart lldpd.service
fi

if [ "$PHASE" == "pre-stop" ]; then
    log_message "Cleaning up TC rules..."
    while IFS='=' read -r key value; do
        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
        # Sanitize the input value
        value_clean=$(echo "$value" | tr -d '\r' | sed 's/[[:space:]]//g')
        
        # Clean up all interfaces in the list
        while IFS= read -r iface; do
            if [[ -n "$iface" ]]; then
                tc qdisc del dev "$iface" ingress 2>/dev/null
            fi
        done < <(parse_mirror_interfaces "$value_clean")
        
    done <<< "$MIRROR_CONFIGS"

    log_message "Waiting for kernel to stabilize interfaces after cleanup..."
    sleep 2

    log_message "Restarting host lldpd after cleanup."
    systemctl restart lldpd.service
fi

log_message "Worker finished for Phase: $PHASE"
exit 0
