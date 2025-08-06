#!/bin/bash

# Proxmox LLDP Mirroring LAUNCHER Hookscript v1.0
# This script launches the main worker script in the background.

VMID=$1
PHASE=$2
WORKER_SCRIPT="/usr/local/sbin/lldp-mirror-worker.sh"

if [ -x "$WORKER_SCRIPT" ]; then
    "$WORKER_SCRIPT" "$VMID" "$PHASE" &
fi

exit 0
