#!/usr/bin/env bash

# =============================================================================
# Proxmox Universal LLDP Mirroring Hookscript
#
# Author: Community Script (with expert review)
# Version: 3.3.0 2024-08-06
# Compatible: Proxmox VE 8.4+ (Debian 12)
# License: MIT
#
# This script is called by Proxmox when a VM starts or stops. It reads the
# VM's configuration file for "lldp_mirror_netX" keys and sets up tc
# mirroring rules to solve LLDP discovery issues for VMs on VLAN-aware
# bridges.
#
# Changelog v3.3.0:
# - Optimized TC operations using 'replace' for atomicity and idempotency
# - Streamlined configuration parsing with single AWK process
# - Eliminated external processes in loops using Bash parameter expansion
# - Enhanced performance for high-frequency hook script execution
# - Production-grade optimizations for Proxmox 8.4/Debian 12
# =============================================================================

# --- Script Configuration ---
LOG_FILE="/var/log/lldp-hook.log"
VERBOSE=true                  # Set to false to disable logging for production
MAX_LOG_SIZE_KB=1024          # Rotate log when it exceeds this size (e.g., 1MB)
DRY_RUN=false                 # Set to true for validation/testing mode

# --- Version Information ---
SCRIPT_VERSION="3.3.0"
SCRIPT_DATE="2024-08-06"

# --- Proxmox-Provided Arguments ---
VMID=$1
PHASE=$2

# --- Function Definitions ---

# Enhanced logging function with execution environment details
log_message() {
    local message="$1"
    local priority="${2:-info}"
    
    if [ "$VERBOSE" = true ]; then
        # Ensure log directory exists
        local log_dir
        log_dir=$(dirname "$LOG_FILE")
        [ -d "$log_dir" ] || mkdir -p "$log_dir" 2>/dev/null
        
        # Create log file if it doesn't exist
        if ! touch "$LOG_FILE" 2>/dev/null; then
            # Fallback to stderr if can't write to log file
            echo "LLDP-Hook: $message" >&2
            return 1
        fi
        
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
        logger -t "lldp-hook[$$]" -p "daemon.$priority" "$message" 2>/dev/null || true
    fi
}

# Log execution environment for debugging
log_execution_context() {
    if [ "$VERBOSE" = true ]; then
        local user
        user=$(whoami 2>/dev/null || echo "unknown")
        log_message "Execution context - User: $user, Phase: $PHASE, PID: $$" "debug"
        log_message "Script version: $SCRIPT_VERSION ($SCRIPT_DATE)" "info"
        
        if [ "$DRY_RUN" = true ]; then
            log_message "DRY RUN MODE - No actual changes will be made" "notice"
        fi
    fi
}

# Enhanced log rotation with better history management
rotate_log() {
    if [ "$VERBOSE" = true ] && [ -f "$LOG_FILE" ]; then
        local current_size
        current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local current_size_kb=$((current_size / 1024))
        
        if [ "$current_size_kb" -gt "$MAX_LOG_SIZE_KB" ]; then
            log_message "Rotating log file (size: ${current_size_kb}KB)" "notice"
            
            # Keep 4 generations of history
            [ -f "${LOG_FILE}.3" ] && rm -f "${LOG_FILE}.3"
            [ -f "${LOG_FILE}.2" ] && mv "${LOG_FILE}.2" "${LOG_FILE}.3"
            [ -f "${LOG_FILE}.1" ] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"
            
            # Rotate current log
            if mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null; then
                touch "$LOG_FILE" 2>/dev/null
                log_message "Log rotation completed successfully (v$SCRIPT_VERSION)" "info"
            else
                log_message "Failed to rotate log file" "warning"
            fi
        fi
    fi
}

# Enhanced interface validation with detailed reporting
validate_interface() {
    local interface="$1"
    
    # Check if interface exists
    if ! ip link show "$interface" &>/dev/null; then
        return 1
    fi
    
    # Check operational state and provide detailed info
    local operstate carrier
    operstate=$(cat "/sys/class/net/$interface/operstate" 2>/dev/null || echo "unknown")
    carrier=$(cat "/sys/class/net/$interface/carrier" 2>/dev/null || echo "unknown")
    
    case "$operstate" in
        "up")
            log_message "Interface $interface is UP (carrier: $carrier)" "debug"
            ;;
        "down")
            log_message "WARNING: Interface $interface exists but is DOWN" "warning"
            ;;
        *)
            log_message "Interface $interface state: $operstate (carrier: $carrier)" "debug"
            ;;
    esac
    
    return 0
}

# OPTIMIZED: TC setup using 'replace' for atomicity and idempotency
setup_tc_link() {
    local bond_if="$1"
    local tap_if="$2"

    log_message "Setting up TC link for $bond_if <-> $tap_if" "info"
    
    if [ "$DRY_RUN" = true ]; then
        log_message "DRY RUN: Would set up TC mirroring for $bond_if <-> $tap_if" "info"
        return 0
    fi
    
    # Validate both interfaces exist
    if ! validate_interface "$bond_if"; then
        log_message "ERROR: Bond interface $bond_if does not exist" "err"
        return 1
    fi
    
    if ! validate_interface "$tap_if"; then
        log_message "ERROR: TAP interface $tap_if does not exist" "err"
        return 1
    fi

    # OPTIMIZATION: Use 'replace' for atomic, idempotent qdisc management
    # This eliminates the need for delete-then-add patterns
    if ! tc qdisc replace dev "$bond_if" ingress 2>>"$LOG_FILE"; then
        log_message "ERROR: Failed to replace ingress qdisc on $bond_if" "err"
        log_tc_debug_info "$bond_if"
        return 1
    fi
    
    if ! tc qdisc replace dev "$tap_if" ingress 2>>"$LOG_FILE"; then
        log_message "ERROR: Failed to replace ingress qdisc on $tap_if" "err"
        log_tc_debug_info "$tap_if"
        # Cleanup partial setup - delete the successfully created qdisc
        tc qdisc del dev "$bond_if" ingress 2>/dev/null || true
        return 1
    fi

    # OPTIMIZATION: Use 'replace' for filters to prevent errors on re-run
    # Enhanced LLDP mirroring filters with precise EtherType matching
    if ! tc filter replace dev "$bond_if" parent ffff: prio 1 protocol 0x88cc \
         u32 match u16 0x88cc 0xffff at -2 \
         action mirred egress mirror dev "$tap_if" 2>>"$LOG_FILE"; then
        log_message "ERROR: Failed to replace TC filter for $bond_if -> $tap_if" "err"
        log_tc_debug_info "$bond_if"
        cleanup_tc_link "$bond_if"
        cleanup_tc_link "$tap_if"
        return 1
    fi

    if ! tc filter replace dev "$tap_if" parent ffff: prio 1 protocol 0x88cc \
         u32 match u16 0x88cc 0xffff at -2 \
         action mirred egress mirror dev "$bond_if" 2>>"$LOG_FILE"; then
        log_message "ERROR: Failed to replace TC filter for $tap_if -> $bond_if" "err"
        log_tc_debug_info "$tap_if"
        cleanup_tc_link "$bond_if"
        cleanup_tc_link "$tap_if"
        return 1
    fi

    # Verify filters are active
    log_message "TC mirror filters for $bond_if <-> $tap_if are active" "info"
    log_tc_status "$bond_if"
    log_tc_status "$tap_if"
    
    return 0
}

# Enhanced debugging output with TC statistics
log_tc_debug_info() {
    local interface="$1"
    
    if [ "$VERBOSE" = true ] && [ -n "$interface" ]; then
        log_message "TC Debug Info for $interface:" "debug"
        
        # Log existing qdiscs
        local qdiscs
        qdiscs=$(tc qdisc show dev "$interface" 2>/dev/null || echo "No qdiscs found")
        log_message "  Qdiscs: $qdiscs" "debug"
        
        # Log existing filters
        local filters
        filters=$(tc filter show dev "$interface" parent ffff: 2>/dev/null || echo "No filters found")
        log_message "  Filters: $filters" "debug"
    fi
}

# Log TC status with statistics
log_tc_status() {
    local interface="$1"
    
    if [ "$VERBOSE" = true ] && [ -n "$interface" ]; then
        # Log filter statistics if available
        local stats
        stats=$(tc -s filter show dev "$interface" parent ffff: 2>/dev/null | grep -A2 "protocol 0x88cc" || echo "No LLDP filter stats")
        log_message "TC stats for $interface: $stats" "debug"
    fi
}

# Enhanced cleanup function
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
    
    # Check if interface still exists before cleanup
    if ip link show "$interface" &>/dev/null; then
        if tc qdisc del dev "$interface" ingress 2>/dev/null; then
            log_message "Successfully removed TC qdisc from $interface" "info"
        else
            log_message "No TC qdisc to remove on $interface (normal if not configured)" "debug"
        fi
    else
        log_message "Interface $interface no longer exists, skipping cleanup" "debug"
    fi
}

# Enhanced LLDP service management
restart_lldp_service() {
    log_message "Managing host lldpd service" "info"
    
    if [ "$DRY_RUN" = true ]; then
        log_message "DRY RUN: Would restart lldpd service" "info"
        return 0
    fi
    
    # Check if service exists
    if ! systemctl list-unit-files lldpd.service &>/dev/null; then
        log_message "WARNING: lldpd.service not found on this system" "warning"
        return 1
    fi
    
    # Check if service is enabled
    if ! systemctl is-enabled lldpd.service &>/dev/null; then
        log_message "WARNING: lldpd.service is not enabled - consider 'systemctl enable lldpd'" "warning"
    fi
    
    # Get current status before restart for logging
    local was_active=false
    if systemctl is-active lldpd.service &>/dev/null; then
        was_active=true
        log_message "lldpd service was active before restart" "debug"
    fi
    
    # Restart with timeout
    if timeout 30 systemctl restart lldpd.service &>>"$LOG_FILE"; then
        log_message "Successfully restarted lldpd service" "info"
        
        # Verify service is running with pragmatic sleep
        # Note: Using a simple sleep 2 is a pragmatic choice that balances
        # simplicity and effectiveness for this use case
        sleep 2
        if systemctl is-active lldpd.service &>/dev/null; then
            log_message "lldpd service is active and running" "info"
        else
            log_message "WARNING: lldpd service is not active after restart" "warning"
            # Log service status for debugging
            local status
            status=$(systemctl status lldpd.service --no-pager -l 2>/dev/null || echo "Status unavailable")
            log_message "Service status: $status" "debug"
        fi
    else
        log_message "ERROR: Failed to restart lldpd service within 30 seconds" "err"
        return 1
    fi
    
    return 0
}

# OPTIMIZED: Configuration parsing using single AWK process
parse_mirror_configs() {
    local vm_conf="$1"
    
    if [ ! -f "$vm_conf" ]; then
        log_message "ERROR: VM config file $vm_conf not found" "err"
        return 1
    fi
    
    # OPTIMIZATION: Single AWK process replaces grep|grep|sed pipeline
    # This reduces process creation overhead significantly
    local configs
    configs=$(awk '
        # Match lines starting with lldp_mirror_netX=, ignoring leading whitespace
        /^[[:space:]]*lldp_mirror_net[0-9]+[[:space:]]*=/ {
            # Skip lines that are commented out
            if ($0 !~ /^[[:space:]]*#/) {
                # Trim leading/trailing whitespace from the whole line and print
                sub(/^[[:space:]]*/, "");
                sub(/[[:space:]]*$/, "");
                print;
            }
        }
    ' "$vm_conf")
    
    if [ -n "$configs" ]; then
        log_message "Parsed configuration lines:" "debug"
        echo "$configs" | while IFS= read -r line; do
            [ -n "$line" ] && log_message "  $line" "debug"
        done
    fi
    
    echo "$configs"
}

# Enhanced interface waiting with better feedback and timeout handling
wait_for_interfaces() {
    local max_wait=30
    local wait_interval=2
    local waited=0
    
    log_message "Waiting for network interfaces to be ready (max ${max_wait}s)..." "info"
    
    while [ $waited -lt $max_wait ]; do
        local all_ready=true
        local missing_interfaces=()
        
        # Check each configured interface
        while IFS='=' read -r key value; do
            if [ -n "$key" ] && [ -n "$value" ]; then
                # OPTIMIZATION: Use Bash parameter expansion instead of external sed
                local net_id bond_if tap_if
                net_id=${key##*lldp_mirror_net}  # Remove longest prefix match
                bond_if=$(echo "$value" | tr -d '[:space:]')  # Keep tr for value cleanup
                tap_if="tap${VMID}i${net_id}"
                
                if ! validate_interface "$bond_if"; then
                    all_ready=false
                    missing_interfaces+=("$bond_if")
                fi
                
                if ! validate_interface "$tap_if"; then
                    all_ready=false
                    missing_interfaces+=("$tap_if")
                fi
            fi
        done <<< "$MIRROR_CONFIGS"
        
        if [ "$all_ready" = true ]; then
            log_message "All required interfaces are ready" "info"
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

# Enhanced dry-run validation
validate_configuration() {
    local vm_conf="$1"
    local validation_errors=0
    
    log_message "Validating configuration for VM $VMID..." "info"
    
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            # OPTIMIZATION: Use Bash parameter expansion instead of external processes
            local net_id bond_if tap_if
            net_id=${key##*lldp_mirror_net}  # Remove longest prefix match
            bond_if=$(echo "$value" | tr -d '[:space:]')
            tap_if="tap${VMID}i${net_id}"
            
            # Validate net_id format
            if ! [[ "$net_id" =~ ^[0-9]+$ ]]; then
                log_message "VALIDATION ERROR: Invalid net_id format: '$net_id'" "err"
                validation_errors=$((validation_errors + 1))
            fi
            
            # Validate bond interface format
            if ! [[ "$bond_if" =~ ^[a-zA-Z][a-zA-Z0-9]*[0-9]*$ ]]; then
                log_message "VALIDATION ERROR: Invalid bond interface format: '$bond_if'" "err"
                validation_errors=$((validation_errors + 1))
            fi
            
            # Check if corresponding net interface exists in VM config
            if ! grep -q "^net${net_id}:" "$vm_conf"; then
                log_message "VALIDATION WARNING: net${net_id} interface not found in VM config" "warning"
            fi
            
            log_message "VALIDATION: net${net_id} -> bond:$bond_if, tap:$tap_if" "info"
        fi
    done <<< "$MIRROR_CONFIGS"
    
    return $validation_errors
}

# --- Main Script Execution ---

# Initialize
rotate_log
log_execution_context
log_message "=== Hookscript v$SCRIPT_VERSION started. VMID: $VMID, Phase: $PHASE ===" "info"

# Check for dry-run mode via environment variable
if [ "${LLDP_HOOK_DRY_RUN:-false}" = "true" ]; then
    DRY_RUN=true
    log_message "Dry-run mode enabled via environment variable" "info"
fi

# Validate arguments
if [ -z "$VMID" ] || [ -z "$PHASE" ]; then
    log_message "ERROR: Missing required arguments. Usage: $0 <VMID> <PHASE>" "err"
    log_message "Supported phases: post-start, pre-stop" "info"
    exit 1
fi

# Validate VMID format using bash pattern matching
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    log_message "ERROR: Invalid VMID format: '$VMID' (must be numeric)" "err"
    exit 1
fi

# Check VM configuration file
VM_CONF="/etc/pve/qemu-server/${VMID}.conf"
if [ ! -f "$VM_CONF" ]; then
    log_message "VM config file $VM_CONF not found. Exiting gracefully." "info"
    exit 0
fi

# Parse mirror configurations using optimized AWK-based parser
MIRROR_CONFIGS=$(parse_mirror_configs "$VM_CONF")

if [ -z "$MIRROR_CONFIGS" ]; then
    log_message "No 'lldp_mirror_netX' config found for VM $VMID. Nothing to do." "info"
    exit 0
fi

# Validate configuration in dry-run mode
if [ "$DRY_RUN" = true ]; then
    validation_errors=$(validate_configuration "$VM_CONF")
    if [ $validation_errors -gt 0 ]; then
        log_message "DRY RUN: Configuration validation failed with $validation_errors error(s)" "err"
        exit 1
    else
        log_message "DRY RUN: Configuration validation passed" "info"
    fi
fi

log_message "Found LLDP mirror configurations for VM $VMID:" "info"
echo "$MIRROR_CONFIGS" | while IFS= read -r line; do
    [ -n "$line" ] && log_message "  $line" "info"
done

# Handle different phases
case "$PHASE" in
    post-start)
        log_message "Phase is post-start. Applying TC rules." "info"
        
        # Wait for interfaces to be ready (skip in dry-run)
        if [ "$DRY_RUN" = false ]; then
            wait_for_interfaces
        fi

        local setup_errors=0
        
        # OPTIMIZED: Process each mirror configuration with minimal external processes
        while IFS='=' read -r key value; do
            # Skip empty lines
            if [ -z "$key" ] || [ -z "$value" ]; then
                continue
            fi
            
            # OPTIMIZATION: Extract components using Bash parameter expansion
            local net_id bond_if tap_if
            net_id=${key##*lldp_mirror_net}  # Remove longest prefix match - much faster than sed
            bond_if=$(echo "$value" | tr -d '[:space:]')  # Keep tr for reliable whitespace removal
            tap_if="tap${VMID}i${net_id}"

            # Enhanced validation using bash pattern matching
            if [ -z "$net_id" ] || [ -z "$bond_if" ] || ! [[ "$net_id" =~ ^[0-9]+$ ]]; then
                log_message "ERROR: Invalid configuration - key: '$key', value: '$value'" "err"
                setup_errors=$((setup_errors + 1))
                continue
            fi
            
            # Attempt setup
            if ! setup_tc_link "$bond_if" "$tap_if"; then
                setup_errors=$((setup_errors + 1))
            fi
        done <<< "$MIRROR_CONFIGS"

        # Always attempt to restart LLDP service (unless dry-run)
        if ! restart_lldp_service; then
            log_message "LLDP service restart failed, but continuing" "warning"
        fi

        # Report results
        if [ $setup_errors -gt 0 ]; then
            log_message "WARNING: $setup_errors interface(s) failed to set up properly" "warning"
            exit 1
        else
            log_message "All LLDP mirror configurations applied successfully" "info"
        fi
        ;;

    pre-stop)
        log_message "Phase is pre-stop. Cleaning up TC rules." "info"

        # OPTIMIZED: Extract unique bond interfaces using readarray for better handling
        # This approach avoids string splitting issues and is more robust
        readarray -t unique_bond_ifs < <(echo "$MIRROR_CONFIGS" | cut -d'=' -f2 | tr -d '[:space:]' | sort -u)

        if [ ${#unique_bond_ifs[@]} -gt 0 ]; then
            log_message "Cleaning up ${#unique_bond_ifs[@]} unique bond interface(s): ${unique_bond_ifs[*]}" "info"
            
            # Clean each unique bond interface
            for bond_if in "${unique_bond_ifs[@]}"; do
                if [ -n "$bond_if" ]; then
                    cleanup_tc_link "$bond_if"
                fi
            done
        else
            log_message "No bond interfaces found to clean up" "info"
        fi
        
        # Restart LLDP service
        if ! restart_lldp_service; then
            log_message "LLDP service restart failed during cleanup" "warning"
        fi
        ;;
        
    *)
        log_message "ERROR: Unknown phase: '$PHASE'. Supported phases: post-start, pre-stop" "err"
        exit 1
        ;;
esac

log_message "=== Hookscript v$SCRIPT_VERSION finished for VM $VMID ===" "info"
exit 0
