#!/usr/bin/env bash
# =============================================================================
# Proxmox Stateful & Idempotent LLDP Mirroring Hookscript
#
# Author: Gemini AI & User Collaboration
# Version: 10.0.1 (Final Parser Hotfix)
#
# Changelog v10.0.1:
# - CRITICAL FIX (Parser): Replaced the fragile grep/sed pipeline in the handle
#   capture function with a simpler, more robust method that is guaranteed
#   not to hang on incompatible shell utility versions.
# =============================================================================

# --- Strict Mode & Environment Setup ---
set -uo pipefail
IFS=$'\n\t'
export PATH="/sbin:/usr/sbin:$PATH"

# --- Configuration & Globals ---
readonly LOG_FILE="/var/log/lldp-stateful-hook.log"
readonly VERBOSE=true
readonly STATE_DIR="/var/run/lldp-hook"
readonly TC_PRIO_BASE=18800
readonly VMID=${1:-}
readonly PHASE=${2:-}
GUEST_TYPE=""
LLDP_CONF=""
INTERFACE_PREFIX=""
declare -A WANTED_STATE
declare -A RUNNING_STATE

# --- Function Definitions ---

log_message() {
  local -r vmid="$1"; local -r level="$2"; local -r message="${3:-}"
  [ "${VERBOSE:-true}" = true ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $level [VMID ${vmid:-?}] $message" >> "$LOG_FILE"
}
run_startup_checks() {
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  if [[ ${EUID:-} -ne 0 ]]; then echo "FATAL: Must be run as root." >> "$LOG_FILE"; return 1; fi
  if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSION%%.*}" -lt 4 ]; then echo "FATAL: Bash 4.0+ required." >> "$LOG_FILE"; return 1; fi
  for cmd in tc ip awk grep sort tr date mktemp flock sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then log_message "?" "FATAL" "Required command '$cmd' not found"; return 1; fi
  done
  if ! tc qdisc show dev lo >/dev/null 2>&1; then log_message "?" "FATAL" "'tc' command failed. Lacking CAP_NET_ADMIN?"; return 1; fi
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  return 0
}
detect_guest_type() {
  local -r vmid="$1"
  if [ -f "/etc/pve/qemu-server/${vmid}.conf" ]; then
    GUEST_TYPE="qemu"; LLDP_CONF="/etc/pve/qemu-server/${vmid}.lldp"; INTERFACE_PREFIX="tap"
  elif [ -f "/etc/pve/lxc/${vmid}.conf" ]; then
    GUEST_TYPE="lxc"; LLDP_CONF="/etc/pve/lxc/${vmid}.lldp"; INTERFACE_PREFIX="veth"
  else return 1; fi
  log_message "$vmid" "INFO" "Detected $GUEST_TYPE guest."
  return 0
}
parse_wanted_state() {
    local -r vmid="$1"
    log_message "$vmid" "INFO" "Parsing wanted state from $LLDP_CONF"
    if [ ! -f "$LLDP_CONF" ]; then log_message "$vmid" "INFO" "No external LLDP config file found."; return 1; fi
    local configs
    configs=$(awk -F= '{gsub(/\r$/,"");gsub(/^[ \t]*/,"");gsub(/[ \t]*$/,"");if(!/^[ \t]*#/&&$1~/^lldp_mirror_net[0-9]+$/&&$2!=""){sub(/[ \t]*#.*/,"",$2);print $1"="$2}}' "$LLDP_CONF")
    if [ -z "$configs" ]; then log_message "$vmid" "INFO" "LLDP config file has no valid entries."; return 1; fi
    while IFS='=' read -r key value; do
        if ! [[ $key =~ ^lldp_mirror_net([0-9]+)$ ]]; then log_message "$vmid" "WARN" "Skipping invalid key '$key'"; continue; fi
        local -r net_id=${BASH_REMATCH[1]}; local phys_if=$value
        if [ -z "$phys_if" ] || ! [[ $phys_if =~ ^[a-zA-Z0-9._:-]{1,15}$ ]]; then log_message "$vmid" "WARN" "Skipping invalid interface '$phys_if' for '$key'"; continue; fi
        local -r guest_if="${INTERFACE_PREFIX}${vmid}i${net_id}"
        WANTED_STATE["$guest_if"]="$phys_if"
        log_message "$vmid" "INFO" "WANTED: $guest_if <-> $phys_if (net $net_id)"
    done <<< "$configs"
    if [ ${#WANTED_STATE[@]} -eq 0 ]; then log_message "$vmid" "WARN" "No valid configurations were parsed."; return 1; fi
    return 0
}
get_tc_mirrors_for_iface() {
    local -r iface="$1"
    # This robustly finds the line with "mirred", then extracts the content inside parentheses
    # (E.g., "Mirror to device veth104i0)" -> "veth104i0" or "Mirror to device *)" -> "*"
    tc -s filter show dev "$iface" ingress 2>/dev/null | awk '
        /mirred/ {
            pos_open = index($0, "(");
            pos_close = index($0, ")");
            if (pos_open > 0 && pos_close > pos_open) {
                # Extract content inside parentheses
                content = substr($0, pos_open + 1, pos_close - pos_open - 1);
                # Find the last word in the content (which should be the device name)
                split(content, words, " ");
                print words[length(words)];
            }
        }' || true
}
get_running_state() {
  local -r vmid="$1"; log_message "$vmid" "INFO" "Querying running state..."; RUNNING_STATE=()
  local interfaces_to_check; interfaces_to_check=$( (for i in "${!WANTED_STATE[@]}"; do echo "$i"; done; for i in "${WANTED_STATE[@]}"; do echo "$i"; done) | sort -u )
  for iface in $interfaces_to_check; do
    if ! ip link show "$iface" >/dev/null 2>&1; then continue; fi
    while IFS= read -r dest; do [ -n "$dest" ] || continue; RUNNING_STATE["$iface"]="${RUNNING_STATE[$iface]:-}${dest}"$'\n'; log_message "$vmid" "INFO" "RUNNING: $iface -> $dest"; done < <(get_tc_mirrors_for_iface "$iface")
  done; log_message "$vmid" "INFO" "Finished querying running state."
}
running_has_dest() { local -r src=$1 dst=$2; printf '%s' "${RUNNING_STATE[$src]:-}" | grep -Fxq "$2"; }
wait_for_interface() {
  local -r vmid="$1" iface=$2; local -r max_wait=${3:-20}; local elapsed=0 delay=0.25; log_message "$vmid" "INFO" "Waiting for interface $iface (max ${max_wait}s)..."
  while ! ip link show "$iface" >/dev/null 2>&1; do
    if (( $(awk 'BEGIN{print ('"$elapsed"'>='"$max_wait"')}') )); then log_message "$vmid" "ERROR" "Timeout waiting for interface $iface"; return 1; fi
    sleep "$delay"; elapsed=$(awk 'BEGIN{print '"$elapsed"'+'"$delay"'}'); delay=$(awk 'BEGIN{d='"$delay"'*1.6; if(d>2)d=2; print d}')
  done; log_message "$vmid" "INFO" "Interface $iface present."; return 0
}
wait_for_rule() {
  local -r vmid="$1" src=$2 dst=$3 want_exists=${4:-true}; local -r timeout=${5:-6}; local -r start=$(date +%s)
  while true; do get_running_state "$vmid"; if [ "$want_exists" = true ]; then if running_has_dest "$src" "$dst"; then return 0; fi; else if ! running_has_dest "$src" "$dst"; then return 0; fi; fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then return 1; fi; sleep 0.25
  done
}
execute_tc_command() {
  local -r vmid="$1" desc="$2"; shift 2; local out rc; set +e; out=$("$@" 2>&1); rc=$?; set -e
  if [ $rc -ne 0 ]; then log_message "$vmid" "ERROR" "$desc failed (rc=$rc). Cmd: '$*'. Output: $out"; fi; return $rc
}
add_rules_for() {
  local -r vmid="$1" guest_if="$2" phys_if="$3"
  trap 'log_message "$vmid" "ERROR" "--- ERROR TRAP: Cleaning up for $guest_if <-> $phys_if ---"; remove_rules_for "$vmid" "$guest_if" "$phys_if"' ERR
  local -r net_id="${guest_if##*i}"; if ! [[ $net_id =~ ^[0-9]+$ ]]; then log_message "$vmid" "ERROR" "Invalid net_id from $guest_if"; return 1; fi
  local -r prio=$((TC_PRIO_BASE + net_id))
  log_message "$vmid" "INFO" "ACTION: Creating rules for $guest_if <-> $phys_if with prio $prio"
  wait_for_interface "$vmid" "$guest_if" 30 || return 1
  
  execute_tc_command "$vmid" "replace qdisc on $phys_if" tc qdisc replace dev "$phys_if" ingress
  execute_tc_command "$vmid" "replace qdisc on $guest_if" tc qdisc replace dev "$guest_if" ingress

  execute_tc_command "$vmid" "create filter $phys_if -> $guest_if" tc filter replace dev "$phys_if" parent ffff: prio "$prio" protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$guest_if"
  execute_tc_command "$vmid" "create filter $guest_if -> $phys_if" tc filter replace dev "$guest_if" parent ffff: prio "$prio" protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$phys_if"
  
  if wait_for_rule "$vmid" "$phys_if" "$guest_if" true && wait_for_rule "$vmid" "$guest_if" "$phys_if" true; then
    log_message "$vmid" "INFO" "SUCCESS: rules active for $guest_if <-> $phys_if"
  else log_message "$vmid" "ERROR" "FAILURE: rules did not appear for $guest_if <-> $phys_if"; return 1; fi
  trap - ERR
}
remove_rules_for() {
  local -r vmid="$1" guest_if=$2 phys_if=$3; local -r net_id="${guest_if##*i}"; local -r prio=$((TC_PRIO_BASE + net_id))
  log_message "$vmid" "INFO" "ACTION: Removing rules for $guest_if <-> $phys_if with prio $prio"
  execute_tc_command "$vmid" "delete filter from $phys_if" tc filter del dev "$phys_if" parent ffff: prio "$prio" || true
  execute_tc_command "$vmid" "delete filter from $guest_if" tc filter del dev "$guest_if" parent ffff: prio "$prio" || true
  if wait_for_rule "$vmid" "$phys_if" "$guest_if" false && wait_for_rule "$vmid" "$guest_if" "$phys_if" false; then
    log_message "$vmid" "INFO" "SUCCESS: rules removed for $guest_if <-> $phys_if"
  else log_message "$vmid" "ERROR" "FAILURE: rules may still exist for $guest_if <-> $phys_if"; fi
}

main() {
    log_message "$VMID" "INFO" "--- Stateful Hook v10.0.1 Started: Phase=$PHASE ---"
    if [ -z "$VMID" ] || [ -z "$PHASE" ]; then log_message "?" "ERROR" "Script called with missing arguments."; exit 1; fi
    if ! run_startup_checks; then exit 1; fi
    case "$PHASE" in
        post-start|pre-stop) ;;
        *) log_message "$VMID" "INFO" "Phase '$PHASE' requires no action. Exiting."; exit 0 ;;
    esac
    if ! detect_guest_type "$VMID"; then log_message "$VMID" "INFO" "Could not determine guest type for ID $VMID"; exit 0; fi
    if ! parse_wanted_state "$VMID"; then exit 0; fi
    get_running_state "$VMID"
    case "$PHASE" in
      post-start)
        for guest_if in "${!WANTED_STATE[@]}"; do
          phys_if=${WANTED_STATE[$guest_if]}
          if running_has_dest "$phys_if" "$guest_if" && running_has_dest "$guest_if" "$phys_if"; then
            log_message "$VMID" "INFO" "CHECK: rules exist for $guest_if <-> $phys_if"
          else
            log_message "$VMID" "INFO" "CHECK: creating rules for $guest_if <-> $phys_if"
            add_rules_for "$VMID" "$guest_if" "$phys_if"
          fi
        done ;;
      pre-stop)
        for guest_if in "${!WANTED_STATE[@]}"; do
          phys_if=${WANTED_STATE[$guest_if]}
          if running_has_dest "$phys_if" "$guest_if" || running_has_dest "$guest_if" "$phys_if"; then
            log_message "$VMID" "INFO" "CHECK: removing rules for $guest_if <-> $phys_if"
            remove_rules_for "$VMID" "$guest_if" "$phys_if"
          else
            log_message "$VMID" "INFO" "CHECK: no running rules for $guest_if <-> $phys_if"
          fi
        done ;;
    esac
    log_message "$VMID" "INFO" "--- Stateful Hook Finished ---"
}

main "$@"
exit 0
