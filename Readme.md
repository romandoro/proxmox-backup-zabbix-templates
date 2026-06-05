# Proxmox Backup Monitoring — Zabbix Template

> I spent a long time looking for a proper Zabbix template for Proxmox backup monitoring and couldn't find anything that covered real-world needs — multiple backup destinations, AWS S3 upload verification, and meaningful alerting per VM. So I built it myself.

This template solves problems that generic solutions miss:
- A backup job can **succeed** but the AWS S3 upload silently fails — you'd never know without a dedicated check
- Most templates treat backup storage as a single destination; this one tracks **PBS, AWS S3, and local** independently per VM
- Discovery is automatic — no manual item creation per VM

---

## What It Monitors

For every VM with a scheduled backup job, the template tracks:

| Metric | Description |
|---|---|
| `backup.status` | OK / FAILED / RUNNING / NO BACKUP |
| `backup.type` | PBS / AWS / Local / Unknown |
| `backup.aws_upload` | S3 upload confirmed (0/1) |
| `backup.endtime` | Last backup completion timestamp |
| `backup.duration` | Backup duration in seconds |

### Triggers

| Trigger | Severity | Condition |
|---|---|---|
| Backup FAILED | High | `status = FAILED` |
| No backup in 8 days | High | `endtime < now - 8d` |
| AWS upload not confirmed | Average | `type = AWS` and `aws_upload = 0` |

---

## Architecture

```
Zabbix Server
    └── Zabbix Agent2 (on PVE node)
            └── UserParameter → shell script
                    └── pvesh API (local Unix socket)
                            └── PVE task log parser
```

The script uses `pvesh` via local Unix socket — **no network calls, no sudo, no credentials** in config files.

**Compatibility:** PVE 6.x – 9.x · Debian 10–13 · Zabbix 6.x – 7.x

---

## Installation

### 1. Deploy the monitoring script

```bash
cp etc/zabbix/scripts/proxmox_backup_monitoring.sh /etc/zabbix/scripts/
chmod 755 /etc/zabbix/scripts/proxmox_backup_monitoring.sh
chown zabbix:zabbix /etc/zabbix/scripts/proxmox_backup_monitoring.sh
```

### 2. Deploy the agent configuration

```bash
cp etc/zabbix/zabbix_agent2.d/plugins.d/proxmox_backup.conf \
   /etc/zabbix/zabbix_agent2.d/plugins.d/

# Verify syntax
zabbix_agent2 -t proxmox.backup.discovery
```

Expected output: JSON array of VMIDs with scheduled backup jobs.

### 3. Restart Zabbix Agent2

```bash
systemctl restart zabbix-agent2
systemctl status zabbix-agent2
```

### 4. Import the Zabbix template

Zabbix UI → **Data collection → Templates → Import**

Select `proxmox_backup_monitoring.yaml` and import.

### 5. Link template to host

Assign **Proxmox Backup Monitoring** template to your PVE host in Zabbix.

Discovery interval: `1h` — first data appears within one hour.

---

## Testing

```bash
# Test discovery — returns list of VMIDs
/etc/zabbix/scripts/proxmox_backup_monitoring.sh discovery

# Test metrics for a specific VM (replace 100 with your VMID)
/etc/zabbix/scripts/proxmox_backup_monitoring.sh get 100
```

Expected output for `get`:

```json
{
  "status": 1,
  "status_text": "ok",
  "endtime": 1747123200,
  "starttime": 1747119600,
  "duration": 3600,
  "storage": "pbs-main",
  "type": 1,
  "type_text": "pbs",
  "aws_upload": 0,
  "upid": "UPID:pve:...",
  "error": ""
}
```

---

## Repository Structure

```
.
├── etc/
│   └── zabbix/
│       ├── scripts/
│       │   └── proxmox_backup_monitoring.sh     # Monitoring script
│       └── zabbix_agent2.d/plugins.d/
│           └── proxmox_backup.conf              # Agent UserParameter config
└── proxmox_backup_monitoring.yaml               # Zabbix template (import this)
```

---

## Requirements

- Proxmox VE 6.x or later
- Zabbix Agent2 installed on the PVE node
- Zabbix Server 7.x or later
- Script runs as `zabbix` user — ensure it has read access to PVE task logs

---

## License

MIT
