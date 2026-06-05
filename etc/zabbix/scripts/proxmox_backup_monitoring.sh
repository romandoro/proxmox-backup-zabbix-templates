#!/bin/bash
# /etc/zabbix/scripts/proxmox_backup_status.sh
# Proxmox VE Backup Monitoring for Zabbix Agent2
# Sources: pvesh API (local Unix socket, no network, no sudo for tasks)
# Covers: vzdump → backup_external_box → AWS, vzdump → PBS
# Compatible: PVE 6.x - 9.x, Debian 10-13
# Version: 1.0

set -uo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────

NODE=$(hostname -s 2>/dev/null || hostname | cut -d'.' -f1)
readonly NODE
export NODE

readonly PVESH="/usr/bin/pvesh"
readonly TIMEOUT=10  # seconds for pvesh call

# Backup status codes (matches Zabbix value map)
readonly STATUS_OK=1
readonly STATUS_FAILED=0
readonly STATUS_RUNNING=2
readonly STATUS_NO_BACKUP=3

# Backup type codes
readonly TYPE_PBS=1
readonly TYPE_AWS=2
readonly TYPE_LOCAL=3
readonly TYPE_UNKNOWN=0

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 <mode> [vmid]

Modes:
  discovery        — JSON list of VMIDs with scheduled backups (for Zabbix LLD)
  get <vmid>       — JSON object with all backup metrics for one VM

Output for 'get':
  {
    "status":      0|1|2|3   (0=failed, 1=ok, 2=running, 3=no_backup),
    "status_text": string,
    "endtime":     unix_timestamp (0 if none),
    "starttime":   unix_timestamp (0 if none),
    "duration":    seconds (0 if none),
    "storage":     string  (storage name from job),
    "type":        0|1|2|3 (0=unknown, 1=pbs, 2=aws, 3=local),
    "type_text":   string,
    "aws_upload":  0|1     (1=Upload S3 OK confirmed),
    "upid":        string,
    "error":       string  (empty if none)
  }
EOF
    exit 1
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Safe pvesh call with timeout
# Uses sudo when not running as root (e.g. under zabbix user)
pvesh_get() {
    if [[ "$EUID" -eq 0 ]]; then
        timeout "$TIMEOUT" "$PVESH" get "$@" --output-format json 2>/dev/null
    else
        timeout "$TIMEOUT" sudo "$PVESH" get "$@" --output-format json 2>/dev/null
    fi
}

# Emit valid empty JSON for 'get' mode when nothing found
empty_result() {
    local reason="${1:-no backup found}"
    printf '{"status":%d,"status_text":"%s","endtime":0,"starttime":0,"duration":0,"storage":"","type":%d,"type_text":"unknown","aws_upload":0,"error":"%s"}\n' \
        "$STATUS_NO_BACKUP" "no_backup" "$TYPE_UNKNOWN" "$reason"
}

# ─── Mode: discovery ─────────────────────────────────────────────────────────
# Primary source: /var/log/vzdump/qemu-{VMID}.log files
# This works on ALL PVE versions (6-9) without sudo, without pvesh,
# without parsing config files. A log file means the VM was backed up.
# Secondary: jobs.cfg / vzdump.cron for VMs scheduled but not yet backed up.

mode_discovery() {
    local vmids=()
    local log_dir="/var/log/vzdump"

    # ── Source 1: vzdump log files (primary, universal) ──
    # Every VM that was ever backed up has qemu-{VMID}.log or lxc-{VMID}.log
    if [[ -d "$log_dir" ]]; then
        for logfile in "${log_dir}"/qemu-*.log "${log_dir}"/lxc-*.log; do
            [[ -f "$logfile" ]] || continue
            local basename
            basename=$(basename "$logfile")
            # Extract VMID from filename: qemu-102401.log → 102401
            if [[ "$basename" =~ ^(qemu|lxc)-([0-9]+)\.log$ ]]; then
                local vmid="${BASH_REMATCH[2]}"
                [[ "$vmid" -ge 100 ]] && vmids+=("$vmid")
            fi
        done
    fi

    # ── Source 4: /etc/pve/qemu-server/*.conf — all VMs on host ──
    # Accessible via www-data group (zabbix is member).
    # VMs here without log file → status=no_backup → trigger fires.
    local qemu_dir="/etc/pve/qemu-server"
    if [[ -d "$qemu_dir" ]] && [[ -r "$qemu_dir" ]]; then
        for conf in "${qemu_dir}"/*.conf; do
            [[ -f "$conf" ]] || continue
            local basename
            basename=$(basename "$conf" .conf)
            [[ "$basename" =~ ^[0-9]+$ ]] && [[ "$basename" -ge 100 ]] && \
                vmids+=("$basename")
        done
    fi
    local jobs_cfg="/etc/pve/jobs.cfg"
    if [[ -r "$jobs_cfg" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]+vmid[[:space:]]+(.+)$ ]]; then
                IFS=',' read -ra parts <<< "${BASH_REMATCH[1]}"
                for p in "${parts[@]}"; do
                    p="${p// /}"
                    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 100 ]] && vmids+=("$p")
                done
            fi
        done < "$jobs_cfg"
    fi

    # ── Source 3: vzdump.cron (PVE 6/7) — add scheduled VMs not yet backed up ──
    local vzdump_cron="/etc/pve/vzdump.cron"
    if [[ -r "$vzdump_cron" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            if [[ "$line" =~ vzdump[[:space:]](.+)$ ]]; then
                local args="${BASH_REMATCH[1]}"
                for word in $args; do
                    [[ "$word" =~ ^[0-9]{3,}$ ]] && vmids+=("$word")
                done
            fi
        done < "$vzdump_cron"
    fi

    # ── Deduplicate and emit JSON ──
    local -A seen=()
    local unique=()
    for v in "${vmids[@]}"; do
        if [[ -z "${seen[$v]+x}" ]]; then
            seen[$v]=1
            unique+=("$v")
        fi
    done

    if [[ ${#unique[@]} -eq 0 ]]; then
        echo '{"data":[]}'
        return
    fi

    printf '{"data":['
    local first=true
    for vmid in "${unique[@]}"; do
        [[ "$first" == true ]] && first=false || printf ','
        printf '{"{#VMID}":"%s"}' "$vmid"
    done
    printf ']}\n'
}

# ─── Mode: get <vmid> ────────────────────────────────────────────────────────
# Returns single JSON object with all backup metrics.
# Primary source: /var/log/vzdump/qemu-{VMID}.log (always per-VM, works for
# both single-VM and multi-VM jobs).
# Fallback: pvesh tasks (for VMs without vzdump log file).

mode_get() {
    local vmid="$1"

    # Validate VMID
    if [[ ! "$vmid" =~ ^[0-9]+$ ]] || [[ "$vmid" -lt 100 ]]; then
        empty_result "invalid vmid"
        return
    fi

    local log_file="/var/log/vzdump/qemu-${vmid}.log"

    # ── Primary: parse vzdump log file ──
    if [[ -f "$log_file" ]] && [[ -r "$log_file" ]]; then
        _parse_vzdump_log "$vmid" "$log_file"
        return
    fi

    # ── Fallback: pvesh tasks (single-VM jobs only) ──
    _parse_pvesh_task "$vmid"
}

# Parse /var/log/vzdump/qemu-{VMID}.log
_parse_vzdump_log() {
    local vmid="$1"
    local log_file="$2"

    # ── Status detection ──
    # Priority: ERROR > running (no Finished line) > OK (Finished line present)
    local status_code="$STATUS_FAILED"
    local status_text="failed"
    local error_text=""
    local endtime=0
    local starttime=0
    local duration=0
    local storage_name=""
    local type_code="$TYPE_UNKNOWN"
    local type_text="unknown"
    local aws_upload=0

    # Check if backup is currently running (process exists)
    if pgrep -f "vzdump.*${vmid}" >/dev/null 2>&1; then
        status_code="$STATUS_RUNNING"
        status_text="running"
    elif grep -q "Finished Backup of VM ${vmid}" "$log_file" 2>/dev/null; then
        # Check for ERROR lines — hook script errors don't fail the task
        # but real vzdump errors do
        if grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ERROR:" \
            "$log_file" 2>/dev/null; then
            status_code="$STATUS_FAILED"
            status_text="failed"
            error_text=$(grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2} .* ERROR:" \
                "$log_file" | tail -1 | sed 's/.*ERROR: //' | \
                tr '"\\' "'/" 2>/dev/null || echo "error")
        else
            status_code="$STATUS_OK"
            status_text="ok"
        fi
    else
        # No Finished line and not running — failed or interrupted
        if grep -qE "ERROR:" "$log_file" 2>/dev/null; then
            status_code="$STATUS_FAILED"
            status_text="failed"
            error_text=$(grep -E "ERROR:" "$log_file" | tail -1 | \
                sed 's/.*ERROR: //' | tr '"\\' "'/" 2>/dev/null || echo "error")
        else
            # Log exists but incomplete — treat as failed
            status_code="$STATUS_FAILED"
            status_text="failed"
            error_text="incomplete backup log"
        fi
    fi

    # ── Timestamps ──
    # Start: first line "YYYY-MM-DD HH:MM:SS INFO: Starting Backup of VM {vmid}"
    local start_line
    start_line=$(grep "Starting Backup of VM ${vmid}" "$log_file" \
        2>/dev/null | head -1)
    if [[ -n "$start_line" ]]; then
        local start_str
        start_str=$(echo "$start_line" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
        starttime=$(date -d "$start_str" +%s 2>/dev/null || echo 0)
    fi

    # End: "YYYY-MM-DD HH:MM:SS INFO: Finished Backup of VM {vmid} (HH:MM:SS)"
    local finish_line
    finish_line=$(grep "Finished Backup of VM ${vmid}" "$log_file" 2>/dev/null | tail -1)
    if [[ -n "$finish_line" ]]; then
        local end_str
        end_str=$(echo "$finish_line" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
        endtime=$(date -d "$end_str" +%s 2>/dev/null || echo 0)

        # Duration from log "(HH:MM:SS)" at end of Finished line
        local dur_str
        dur_str=$(echo "$finish_line" | grep -oP '\(\d{2}:\d{2}:\d{2}\)' | tr -d '()')
        if [[ -n "$dur_str" ]]; then
            local h m s
            IFS=: read -r h m s <<< "$dur_str"
            duration=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
        fi
    fi

    # ── Storage name and type from log content ──
    # Per-VM vzdump logs don't contain --storage parameter.
    # Detect type by log content patterns:
    # PBS:   "creating Proxmox Backup Server archive 'vm/VMID/...'"
    # Local: "creating vzdump archive '/path/to/file.vma...'"

    local pbs_line
    pbs_line=$(grep "creating Proxmox Backup Server archive" "$log_file" \
        2>/dev/null | head -1)

    local vzdump_line
    vzdump_line=$(grep "creating vzdump archive" "$log_file" \
        2>/dev/null | head -1)

    if [[ -n "$pbs_line" ]]; then
        # PBS — extract datastore name from archive path 'vm/VMID/...'
        # Try to get storage from jobs.cfg
        storage_name=$(grep -A20 "vzdump:" /etc/pve/jobs.cfg 2>/dev/null | \
            grep -B5 "vmid.*\b${vmid}\b" | \
            grep "storage" | head -1 | \
            awk '{print $2}' || echo "")
        [[ -z "$storage_name" ]] && storage_name="PBS"
        type_code="$TYPE_PBS"
        type_text="pbs"
    elif [[ -n "$vzdump_line" ]]; then
        # Extract full archive path then normalize to storage name
        # Path format: '/mnt/pve/{storage_name}/dump/vzdump-...' or '/backup/dump/...'
        local archive_path
        archive_path=$(echo "$vzdump_line" | \
            grep -oP "(?<=creating vzdump archive ')([^']+)" | \
            head -1 || echo "")

        # Normalize: extract storage name from path
        # /mnt/pve/backup_external_box/dump/... → backup_external_box
        # /backup/dump/... → backup
        # /var/lib/vz/dump/... → local
        if [[ "$archive_path" =~ ^/mnt/pve/([^/]+)/ ]]; then
            storage_name="${BASH_REMATCH[1]}"
        elif [[ "$archive_path" =~ ^/backup/ ]]; then
            storage_name="backup"
        elif [[ "$archive_path" =~ ^/var/lib/vz/ ]]; then
            storage_name="local"
        else
            # Fallback: use directory name
            storage_name=$(dirname "$archive_path" | xargs dirname | \
                xargs basename 2>/dev/null || echo "unknown")
        fi

        # Check for AWS upload confirmation
        if grep -q "Upload S3 OK" "$log_file" 2>/dev/null; then
            aws_upload=1
            type_code="$TYPE_AWS"
            type_text="aws"
        else
            type_code="$TYPE_LOCAL"
            type_text="local"
        fi
    fi

    # ── Emit result ──
    printf '{"status":%d,"status_text":"%s","endtime":%d,"starttime":%d,"duration":%d,"storage":"%s","type":%d,"type_text":"%s","aws_upload":%d,"error":"%s"}\n' \
        "$status_code" \
        "$status_text" \
        "$endtime" \
        "$starttime" \
        "$duration" \
        "$storage_name" \
        "$type_code" \
        "$type_text" \
        "$aws_upload" \
        "$error_text"
}

# Fallback: parse pvesh task list (for VMs without vzdump log)
_parse_pvesh_task() {
    local vmid="$1"

    local tasks_json
    tasks_json=$(pvesh_get "/nodes/${NODE}/tasks" \
        --typefilter vzdump \
        --vmid "$vmid" \
        --limit 1 2>/dev/null) || true

    if [[ -z "$tasks_json" ]] || [[ "$tasks_json" == "[]" ]]; then
        empty_result "no log file and no tasks found"
        return
    fi

    local task_status endtime starttime upid
    read -r task_status endtime starttime upid < <(python3 -c "
import sys, json
tasks = json.load(sys.stdin)
if not tasks:
    print('none 0 0 none')
    sys.exit(0)
t = tasks[0]
print(
    t.get('status', 'none'),
    t.get('endtime', 0),
    t.get('starttime', 0),
    t.get('upid', 'none')
)
" <<< "$tasks_json" 2>/dev/null) || true

    if [[ -z "$task_status" ]] || [[ "$task_status" == "none" ]]; then
        empty_result "parse error"
        return
    fi

    local status_code="$STATUS_FAILED"
    local status_text="failed"
    local error_text=""

    if [[ "$endtime" -eq 0 ]] && [[ "$starttime" -gt 0 ]]; then
        status_code="$STATUS_RUNNING"
        status_text="running"
    elif [[ "$task_status" == "OK" ]]; then
        status_code="$STATUS_OK"
        status_text="ok"
    else
        status_code="$STATUS_FAILED"
        status_text="failed"
        error_text="${task_status//\"/\'}"
    fi

    local duration=0
    if [[ "$endtime" -gt 0 ]] && [[ "$starttime" -gt 0 ]]; then
        duration=$(( endtime - starttime ))
    fi

    printf '{"status":%d,"status_text":"%s","endtime":%d,"starttime":%d,"duration":%d,"storage":"","type":%d,"type_text":"unknown","aws_upload":0,"error":"%s"}\n' \
        "$status_code" \
        "$status_text" \
        "$endtime" \
        "$starttime" \
        "$duration" \
        "$TYPE_UNKNOWN" \
        "$error_text"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    # Check pvesh exists
    if [[ ! -x "$PVESH" ]]; then
        echo '{"error":"pvesh not found at '"$PVESH"'"}' >&2
        exit 1
    fi

    local mode="$1"

    case "$mode" in
        discovery)
            mode_discovery
            ;;
        get)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: 'get' mode requires vmid argument" >&2
                exit 1
            fi
            mode_get "$2"
            ;;
        *)
            echo "ERROR: unknown mode '$mode'" >&2
            usage
            ;;
    esac
}

main "$@"

