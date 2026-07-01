# Hitachi VSP iSCSI Audit & Remediation

Detects and fixes stale Cinder BDM / host-group state on **Hitachi VSP** storage left behind by failed OpenStack live migrations.

Cross-references Nova, Cinder, and the Hitachi VSP REST API to find LDEVs that are mapped to the wrong host group(s).

---

## Failure Modes

| Mode | What It Means |
|------|--------------|
| `DUAL HOST GROUP` | LDEV is mapped to **both** source and destination host groups. Root cause: `pre_live_migration` ran on the destination but the migration failed and BDM rollback was skipped (libvirt monitor timeout). |
| `SOURCE MISSING` | LDEV is mapped **only** to the destination host group; the source host group mapping was removed (e.g. a failed `terminate_connection` call). |

---

## Prerequisites

- Python 3
- `openstack` CLI installed and OpenStack RC file sourced
- Network access to the Hitachi VSP management IP
- (Optional) SSH access to compute hosts for IQN resolution and host health checks

---

## Usage

### Detect only

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin
```

Password is prompted if `--hitachi-password` is not provided.

### Check a single VM

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --server <vm-uuid-or-name>
```

### With SSH (recommended)

SSH enables automatic IQN resolution and a host health report (multipath paths, D-state processes, libvirtd status).

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --ssh-user root --ssh-key /path/to/key
```

### Supply IQNs manually (alternative to SSH)

Use when SSH is not available. Get the IQN from the host:

```bash
ssh <compute-host> 'cat /etc/iscsi/initiatorname.iscsi'
```

Then pass it in:

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --host-iqn pf9-n01=iqn.2004-10.com.ubuntu:01:04cd37af9c9
```

Repeat `--host-iqn` for each host.

### Override LDEV ID manually

When `provider_location` is not visible without admin scope, supply the LDEV ID directly:

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --volume-ldev <volume-uuid>=<ldev-id>
```

Find the LDEV ID from Hitachi Storage Navigator or from the Cinder volume's `provider_location` field (requires admin).

### Preview remediation (safe — no changes)

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --dry-run
```

### Apply fixes

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --remediate
```

### Flush orphaned multipath devices

```bash
python3 pf9-storage-audit-hitachi.py \
  --hitachi-host <vsp-mgmt-ip> \
  --hitachi-user svol_admin \
  --ssh-user root --ssh-key /path/to/key \
  --clean-mpath
```

Use with `--dry-run` to preview which devices would be flushed.

---

## What `--remediate` Does

For each finding, the script runs three steps:

**Step 1 — Fix Hitachi LU paths (automated)**
- `DUAL HOST GROUP`: removes stale host group's LU path entries from VSP
- `SOURCE MISSING`: adds LU path entries to the correct (nova) host group, then removes the stale ones

**Step 2 — iSCSI rescan (printed, run manually on the affected host)**
```bash
iscsiadm -m session -R
iscsiadm -m node --login
multipath -r
multipath -ll | grep -E 'failed|faulty|0 paths'
```

**Step 3 — Nova BDM fix (SQL printed for review)**

The script prints the `SELECT` and `UPDATE` statements needed to correct `target_lun` / `target_luns` in `block_device_mapping`. Review before applying.

---

## Verifying After Remediation

```bash
virsh list --all          # should not hang on the affected host
multipath -ll             # no failed/faulty maps
openstack volume list     # volumes should be 'in-use'
openstack server list     # VMs should be 'ACTIVE'
```

---

## All Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--hitachi-host` | (required) | VSP management IP or hostname |
| `--hitachi-user` | `openstack` | Storage admin user |
| `--hitachi-password` | prompted | Password |
| `--storage-device-id` | auto-discovered | VSP storage device ID |
| `--server` | all VMs | Check a single VM by UUID or name |
| `--ssh-user` | — | SSH user for IQN fetch and host health checks |
| `--ssh-key` | — | SSH private key path |
| `--host-iqn HOST=IQN` | — | Known IQN for a compute host; repeat per host |
| `--volume-ldev UUID=ID` | — | Manual LDEV ID override; repeat per volume |
| `--dry-run` | — | Preview all steps without making changes |
| `--remediate` | — | Apply LU path fixes and print iSCSI/BDM steps |
| `--clean-mpath` | — | Flush mpath devices with all paths failed (requires `--ssh-user`) |

---

## Hitachi-Specific Notes

**Host groups are per-port.** A single compute host appears as one host group on each iSCSI port (e.g. `CL1-D` and `CL2-D`). The script groups them by name and classifies the name as a single host identity.

**HBSD naming convention.** When the Hitachi HBSD Cinder driver is used, host groups are named `HBSD-<hypervisor_mgmt_ip>`. The script resolves these using the hypervisor list from Nova when no IQN is available.

**Async jobs.** Mutating VSP operations return a job ID. The script polls until the job completes before proceeding.

**Phantom records.** Some LU paths may be visible via the VSP API but already removed internally (Hitachi error `KART40014-E`). The script treats these as already-clean and continues. If phantom records are widespread, escalate to Hitachi for cleanup via Storage Navigator or SVP.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | No issues found |
| `1` | Issues found or error occurred |
