# Handle different phases
case "$PHASE" in
    post-start)
        log_message "Phase is post-start. Applying TC rules for $GUEST_TYPE." "info"
        
        if [ "$DRY_RUN" = false ]; then
            wait_for_interfaces
        fi

        local setup_errors=0
        
        while IFS='=' read -r key value; do
            if [ -z "$key" ] || [ -z "$value" ]; then
                continue
            fi
            
            local net_id bond_if guest_if
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
        # These are valid phases, but we have no actions to take.
        # Exit gracefully so Proxmox can continue.
        log_message "Phase is '$PHASE'. No action required. Exiting gracefully." "info"
        exit 0
        ;;
        
    *)
        log_message "ERROR: Unknown phase: '$PHASE'. Supported phases: post-start, pre-stop" "err"
        exit 1
        ;;
esac
