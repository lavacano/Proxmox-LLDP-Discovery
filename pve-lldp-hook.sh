#!/usr/bin/env bash
# =============================================================================
# Proxmox Stateful & Idempotent LLDP Mirroring Hookscript
#
# Author: Gemini AI & User Collaboration
# Version: 9.1.0 (Definitive Production Release)
#
# This version is the definitive production release, incorporating final hardening
# and best-practice refinements from a comprehensive series of expert code reviews.
#
# Changelog v9.1.0:
# - BEST PRACTICES: Implemented `readonly` variables for constants and function
#   parameters to improve script safety and clarity.
# - BEST PRACTICES: The `log_message` function now uses log levels (e.g., INFO,
#   ERROR) for standardized, filterable logging.
# - ROBUSTNESS: Hardened the validation for interface names to include a
#   character length check.
# =============================================================================

# --- Strict Mode & Environment Setup ---
set -uo pipefail
IFS=$'\n\t'

# --- Early Environment Checks ---
if [[ ${EUID:-} -ne 0 ]]; then
  echo "$(date '+%F %T') - FATAL: This script must be run as root." >&2
  exit 1
fi
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSION%%.*}" -lt 4 ]; then
  echo "$(date '+%F %T') - FATAL: Bash 4.0+ is required for associative arrays." >&2
  exit 1
fi
export PATH="/sbin:/usr/sbin:$PATH"

# --- Configuration ---
readonly LOG_FILE="/var/log/lldp-stateful-hook.log"
readonly VERBOSE=true
readonly STATE_DIR="/var/run/lldp-hook"
readonly TC_PRIO_BASE=18800

# --- Proxmox args ---
readonly VMID=${1:-}
readonly PHASE=${2:-}

# --- Globals ---
GUEST_TYPE=""
LLDP_CONF=""
STATE_FILE=""
INTERFACE_PREFIX=""
TC_SUPPORTS_JSON=false
declare -A WANTED_STATE
declare -A RUNNING_STATE

# --- Function Definitions ---

log_message() {
  local -r level="$1"
  local -r message="$2"
  [ "${VERBOSE:-true}" = true ] && logger -t "lldp-hook[$$]" "$level [VMID ${VMID:-?}] $message"
}

run_startup_checks() {
  if ! command -v tc >/dev/null 2>&1; then echo "$(date '+%F %T') - FATAL: 'tc' not found." >&2; return 1; fi
  if ! tc qdisc show dev lo >/dev/null 2>&1; then log_message "FATAL" "'tc' command failed. Lacking CAP_NET_ADMIN?"; return 1; fi
  for cmd in ip awk grep sort tr date mktemp flock logger; do
    if ! command -v "$cmd" >/dev/null 2>&1; then log_message "FATAL" "Required command '$cmd' not found"; return 1; fi
  done
  if tc -j filter show dev lo >/dev/null 2>&1; then TC_SUPPORTS_JSON=true; fi
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  return 0
}

detect_guest_type() {
  if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then log_message "ERROR" "VMID invalid or missing: '$VMID'"; return 1; fi
  if [ -f "/etc/pve/qemu-server/${VMID}.conf" ]; then
    GUEST_TYPE="qemu"; LLDP_CONF="/etc/pve/qemu-server/${VMID}.lldp"; INTERFACE_PREFIX="tap"
  elif [ -f "/etc/pve/lxc/${VMID}.conf" ]; then
    GUEST_TYPE="lxc"; LLDP_CONF="/etc/pve/lxc/${VMID}.lldp"; INTERFACE_PREFIX="veth"
  else
    return 1
  fi
  STATE_FILE="${STATE_DIR}/${VMID}.state"
  log_message "INFO" "Detected $GUEST_TYPE guest; state file: $STATE_FILE"
  return 0
}

parse_wanted_state() {
  log_message "INFO" "Parsing wanted state from $LLDP_CONF"
  if [ ! -f "$LLDP_CONF" ]; then log_message "INFO" "No external LLDP config file found."; return 1; fi
  
  local configs
  configs=$(awk '
    { gsub(/\r$/, ""); line=$0; sub(/^[ \t]*/, "", line); sub(/[ \t]*$/, "", line);
      if (line == "" || line ~ /^[ \t]*#/) next;
      eq = index(line, "="); if (eq == 0) next;
      k = substr(line,1,eq-1); v = substr(line, eq+1);
      gsub(/^[ \t]*/, "", k); gsub(/[ \t]*$/, "", k);
      gsub(/^[ \t]*/, "", v); gsub(/[ \t]*$/, "", v);
      sub(/[ \t]*#.*/, "", v);
      if (k ~ /^lldp_mirror_net[0-9]+$/ && v != "") print k "=" v
    }' "$LLDP_CONF")
  
  if [ -z "$configs" ]; then log_message "INFO" "LLDP config file has no valid entries."; return 1; fi

  while IFS='=' read -r key value; do
    if ! [[ $key =~ ^lldp_mirror_net([0-9]+)$ ]]; then log_message "WARN" "Skipping invalid key '$key'"; continue; fi
    local -r net_id=${BASH_REMATCH[1]}
    local phys_if=$value
    # Harden interface name validation with length check
    if [ -z "$phys_if" ] || ! [[ $phys_if =~ ^[a-zA-Z0-9._:-]{1,15}$ ]]; then log_message "WARN" "Skipping invalid physical interface '$phys_if' for $key"; continue; fi
    local -r guest_if="${INTERFACE_PREFIX}${VMID}i${net_id}"
    WANTED_STATE["$guest_if"]="$phys_if"
    log_message "INFO" "WANTED: $guest_if <-> $phys_if (net $net_id)"
  done <<< "$configs"
  
  if [ ${#WANTED_STATE[@]} -eq 0 ]; then log_message "WARN" "No valid configurations were parsed."; return 1; fi
  return 0
}

get_tc_output_file() {
  local -r iface="$1"
  local tmpf; tmpf=$(mktemp "${STATE_DIR}/tc-out.XXXXXX")
  tc -s filter show dev "$iface" ingress 2>/dev/null >"$tmpf" || true
  printf "%s" "$tmpf"
}
get_tc_mirrors_for_iface() {
  local -r iface="$1"
  if [ "$TC_SUPPORTS_JSON" = true ]; then
    tc -j filter show dev "$iface" ingress 2>/dev/null | awk 'BEGIN{RS="},"} /mirred/ && /mirror/ {if(match($0,/"dev"[[:space:]]*:[[:space:]]*"([^"]+)"/,a)){print a[1]}}'
    return
  fi
  local outfile; outfile=$(get_tc_output_file "$iface")
  awk 'BEGIN{RS=""; FS="\n"} {block=$0; if(block ~ /mirred/ && block ~ /mirror dev/) {if(match(block,/mirror dev[ \t]+([A-Za-z0-9._:-]+)/,m)) print m[1]}}' < "$outfile"
  if [[ "$outfile" == ${STATE_DIR}/tc-out.* ]]; then rm -f "$outfile"; fi
}
get_running_state() {
  log_message "INFO" "Querying running state..."
  RUNNING_STATE=()
  local interfaces_to_check
  interfaces_to_check=$( (for i in "${!WANTED_STATE[@]}"; do echo "$i"; done; for i in "${WANTED_STATE[@]}"; do echo "$i"; done) | sort -u )
  for iface in $interfaces_to_check; do
    if ! ip link show "$iface" >/dev/null 2>&1; then continue; fi
    while IFS= read -r dest; do
      [ -n "$dest" ] || continue
      RUNNING_STATE["$iface"]="${RUNNING_STATE[$iface]:-}${dest}"$'\n'
      log_message "INFO" "RUNNING: $iface -> $dest"
    done < <(get_tc_mirrors_for_iface "$iface")
  done
  log_message "INFO" "Finished querying running state."
}
running_has_dest() { local -r src=$1 dst=$2; printf '%s' "${RUNNING_STATE[$src]:-}" | grep -Fxq "$dst"; }

wait_for_interface() {
  local -r iface=$1
  local -r max_wait=${2:-20}
  local elapsed=0 delay=0.25
  log_message "INFO" "Waiting for interface $iface (max ${max_wait}s)..."
  while ! ip link show "$iface" >/dev/null 2>&1; do
    if (( $(awk 'BEGIN{print ('"$elapsed"'>='"$max_wait"')}') )); then log_message "ERROR" "Timeout waiting for interface $iface"; return 1; fi
    sleep "$delay"; elapsed=$(awk 'BEGIN{print '"$elapsed"'+'"$delay"'}'); delay=$(awk 'BEGIN{d='"$delay"'*1.6; if(d>2)d=2; print d}')
  done
  log_message "INFO" "Interface $iface present."; return 0
}
wait_for_rule() {
  local -r src=$1 dst=$2 want_exists=${3:-true}
  local -r timeout=${4:-6}
  local -r start=$(date +%s)
  while true; do
    get_running_state
    if [ "$want_exists" = true ]; then
      if running_has_dest "$src" "$dst"; then return 0; fi
    else
      if ! running_has_dest "$src" "$dst"; then return 0; fi
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then return 1; fi
    sleep 0.25
  done
}

execute_tc_command() {
  local -r desc="$1"; shift; local out rc
  set +e; out=$("$@" 2>&1); rc=$?; set -e
  if [ $rc -ne 0 ]; then log_message "ERROR" "$desc failed (rc=$rc). Cmd: '$*'. Output: $out"; fi
  return $rc
}

save_handle_to_state() {
  local -r key="$1"
  local -r val="$2"
  local -r lockfile="${STATE_DIR}/${VMID}.lock"
  exec 200>"$lockfile"
  flock -x 200
  local tmp_state_file="${STATE_DIR}/${VMID}.state.tmp"
  grep -v -F "$key=" "$STATE_FILE" 2>/dev/null > "$tmp_state_file" || true
  echo "$key=$val" >> "$tmp_state_file"; mv "$tmp_state_file" "$STATE_FILE"
  flock -u 200; exec 200>&-
}
read_state_value() {
  local -r key="$1"
  if [ ! -f "$STATE_FILE" ]; then return 1; fi
  awk -F= -v k="$key" '$1==k{print $2; exit}' "$STATE_FILE"
}

create_and_capture_handle() {
  local -r iface="$1" dest_if="$2" net_id="$3" dir_prefix="$4"
  local -r prio=$((TC_PRIO_BASE + net_id)); local attempt=0 handle block
  
  if ! execute_tc_command "create filter on $iface -> $dest_if" \
       tc filter replace dev "$iface" parent ffff: prio "$prio" protocol 0x88cc u32 match u32 0 0 action mirred egress mirror dev "$dest_if"; then
    return 1
  fi
  
  for attempt in {1..5}; do
    block=$(tc filter show dev "$iface" parent ffff: 2>/dev/null | awk -v dest="$dest_if" 'BEGIN{RS=""} $0 ~ /mirred/ && $0 ~ dest {print; exit}')
    if [ -n "$block" ]; then handle=$(printf "%s" "$block" | awk 'match($0,/handle[ \t]+([0-9a-fA-F:]+)/,a){print a[1]}'); if [ -n "$handle" ]; then break; fi; fi
    sleep 0.2
  done

  if [ -z "${handle:-}" ]; then log_message "ERROR" "Could not capture handle for filter on $iface -> $dest_if"; return 1; fi
  
  local -r key="${dir_prefix}_handle_${net_id}"
  save_handle_to_state "$key" "$handle"
  log_message "INFO" "Captured handle $handle for $iface -> $dest_if (key $key)"
  return 0
}

add_rules_for() {
  trap 'log_message "ERROR" "--- ERROR TRAP: Cleaning up partial rules for $guest_if <-> $phys_if ---"; remove_rules_for "$guest_if" "$phys_if"' ERR
  
  local -r guest_if=$1 phys_if=$2
  local -r net_id="${guest_if##*i}"
  if ! [[ $net_id =~ ^[0-9]+$ ]]; then log_message "ERROR" "Invalid net_id extracted from $guest_if"; return 1; fi

  log_message "INFO" "ACTION: Creating rules for $guest_if <-> $phys_if"
  wait_for_interface "$guest_if" 30 || return 1

  mkdir -p "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
  create_and_capture_handle "$phys_if" "$guest_if" "$net_id" "phys_to_guest"
  create_and_capture_handle "$guest_if" "$phys_if" "$net_id" "guest_to_phys"

  if wait_for_rule "$phys_if" "$guest_if" true && wait_for_rule "$guest_if" "$phys_if" true; then
    log_message "INFO" "SUCCESS: bidirectional rules active for $guest_if <-> $phys_if"
  else
    log_message "ERROR" "FAILURE: rules did not appear in time for $guest_if <-> $phys_if"; return 1
  fi
  trap - ERR
}
remove_rules_for() {
  local -r guest_if=$1 phys_if=$2
  local -r net_id="${guest_if##*i}"
  log_message "INFO" "ACTION: Removing rules for $guest_if <-> $phys_if"
  if [ ! -f "$STATE_FILE" ]; then log_message "WARN" "State file $STATE_FILE missing; cannot delete by handle."; return; fi

  local p2g_handle g2p_handle
  p2g_handle=$(read_state_value "phys_to_guest_handle_${net_id}")
  g2p_handle=$(read_state_value "guest_to_phys_handle_${net_id}")

  if [ -n "$p2g_handle" ]; then execute_tc_command "delete filter $p2g_handle from $phys_if" tc filter del dev "$phys_if" parent ffff: handle "$p2g_handle" u32 || true; fi
  if [ -n "$g2p_handle" ]; then execute_tc_command "delete filter $g2p_handle from $guest_if" tc filter del dev "$guest_if" parent ffff: handle "$g2p_handle" u32 || true; fi

  if wait_for_rule "$phys_if" "$guest_if" false && wait_for_rule "$guest_if" "$phys_if" false; then
    log_message "INFO" "SUCCESS: rules removed for $guest_if <-> $phys_if"
    local -r lockfile="${STATE_DIR}/${VMID}.lock"
    exec 200>"$lockfile"; flock -x 200
    grep -v "_handle_${net_id}" "$STATE_FILE" > "${STATE_DIR}/${VMID}.state.tmp" && mv "${STATE_DIR}/${VMID}.state.tmp" "$STATE_FILE"
    flock -u 200; exec 200>&-
  else
    log_message "ERROR" "FAILURE: some rules may still exist for $guest_if <-> $phys_if"
  fi
}

# --- Main ---
log_message "INFO" "--- Stateful Hook v9.1.0 Started: VMID=$VMID, Phase=$PHASE ---"

if ! run_startup_checks; then exit 1; fi
if ! detect_guest_type; then log_message "INFO" "Could not determine guest type for ID $VMID"; exit 0; fi
if ! parse_wanted_state; then exit 0; fi

get_running_state

case "$PHASE" in
  post-start)
    for guest_if in "${!WANTED_STATE[@]}"; do
      phys_if=${WANTED_STATE[$guest_if]}
      if running_has_dest "$phys_if" "$guest_if" && running_has_dest "$guest_if" "$phys_if"; then
        log_message "INFO" "CHECK: rules exist for $guest_if <-> $phys_if"
      else
        log_message "INFO" "CHECK: creating rules for $guest_if <-> $phys_if"
        add_rules_for "$guest_if" "$phys_if"
      fi
    done
    ;;
  pre-stop)
    for guest_if in "${!WANTED_STATE[@]}"; do
      phys_if=${WANTED_STATE[$guest_if]}
      if running_has_dest "$phys_if" "$guest_if" || running_has_dest "$guest_if" "$phys_if"; then
        log_message "INFO" "CHECK: removing rules for $guest_if <-> $phys_if"
        remove_rules_for "$guest_if" "$phys_if"
      else
        log_message "INFO" "CHECK: no running rules for $guest_if <-> $phys_if"
      fi
    done
    ;;
  *)
    log_message "WARN" "Phase '$PHASE' not handled"
    ;;
esac

log_message "INFO" "--- Stateful Hook Finished ---"
exit 0
