# pf9-storage-audit.py — iSCSI Live-Migration Remediation Tool

## What This Script Does

After a failed live migration, OpenStack can leave behind corrupted iSCSI
attachment state on the NetApp array. The VM may still be running, but its
disk is mapped to the wrong igroup — which can cause I/O errors, failed
rescans, or a complete loss of disk access on the next reboot.

This script:
1. Queries Nova and Cinder to find every VM and its attached volumes
2. Queries NetApp ONTAP to check which igroup each LUN is mapped to
3. Compares the two and reports any mismatch
4. Optionally fixes the NetApp igroup mappings automatically

---

## Failure Modes Detected

### DUAL IGROUP (most common in production)

`pre_live_migration` on the destination host creates a new LUN map entry
**before** the VM actually moves. If the migration fails, the source igroup
entry is never cleaned up — the same LUN ends up mapped to two igroups at once.

```
LUN /vol/vol1/cinder-volume-abc...
  ✓ igroup-source  →  iqn....source-host   ← correct, VM is here
  ✗ igroup-dest    →  iqn....dest-host     ← stale, must be removed
```

Nova's BDM `target_lun` may also point to the destination's LUN ID, requiring
a DB fix after the igroup is corrected.

---

### SOURCE MISSING

A failed `terminate_connection` call removes the source igroup entry entirely.
Only the destination's igroup entry remains — the source host loses access.

```
LUN /vol/vol1/cinder-volume-abc...
  ✗ igroup-dest    →  iqn....dest-host     ← wrong host, source entry is gone
```

---

## What `--remediate` Actually Does

This is the most important thing to understand before running the script.

**`--remediate` makes live changes to NetApp ONTAP immediately:**

| Action | Automated? |
|--------|-----------|
| Remove stale LUN→igroup mapping on NetApp (DUAL IGROUP) | **Yes — executes immediately** |
| Re-add correct LUN→igroup mapping on NetApp (SOURCE MISSING) | **Yes — executes immediately** |
| iSCSI rescan commands (`iscsiadm`, `multipath -r`) | No — printed for you to run manually on the host |
| Nova BDM `target_lun` SQL fix | No — printed for you to review and run on the DB host |

**Always run `--dry-run` first.** It shows you exactly what would happen
without touching anything.

---

## Prerequisites

| Requirement | How to verify |
|-------------|--------------|
| Python 3.8+ | `python3 --version` |
| OpenStack CLI | `pip3 install python-openstackclient` |
| RC file sourced | `echo $OS_AUTH_URL` — must return a URL |
| Network access to NetApp (port 443) | `curl -sk https://<netapp-ip>/api/cluster` |

---

## Supplying IQNs (required for Ubuntu compute hosts)

Ubuntu iSCSI IQNs encode a hardware ID (MAC suffix), not the hostname.
The script cannot infer them from the igroup name — you must supply them.

Without IQNs the script can still **detect** dual mappings but cannot
classify which igroup entry is correct vs stale.

**Option A — SSH (automatic, recommended):**

```bash
python3 pf9-storage-audit.py \
    --netapp-host <netapp-ip> \
    --netapp-user admin \
    --svm <svm-name> \
    --ssh-user root \
    --ssh-key /path/to/key
```

The script SSHes to each compute host and reads
`/etc/iscsi/initiatorname.iscsi` automatically.

**Option B — Manual:**

```bash
# On each compute host, run:
cat /etc/iscsi/initiatorname.iscsi
# → InitiatorName=iqn.2004-10.com.ubuntu:01:04cd37af9c9

# Then pass to the script (one --host-iqn per host):
python3 pf9-storage-audit.py \
    --netapp-host <netapp-ip> \
    --netapp-user admin \
    --svm <svm-name> \
    --host-iqn "compute-970-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9" \
    --host-iqn "compute-970-2=iqn.2004-10.com.ubuntu:01:ef99ea7be46"
```

---

## Usage Examples

### 1. Detect issues across all VMs (safe — no changes)

```bash
python3 pf9-storage-audit.py \
    --netapp-host <netapp-ip> \
    --netapp-user admin \
    --svm <svm-name> \
    --host-iqn "compute-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9" \
    --host-iqn "compute-2=iqn.2004-10.com.ubuntu:01:ef99ea7be46"
```

### 2. Detect issues for a single VM (safe — no changes)

```bash
python3 pf9-storage-audit.py \
    --netapp-host <netapp-ip> \
    --netapp-user admin \
    --svm <svm-name> \
    --host-iqn "compute-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9" \
    --host-iqn "compute-2=iqn.2004-10.com.ubuntu:01:ef99ea7be46" \
    --server <vm-uuid-or-name>
```

### 3. Preview what remediation would do (safe — no changes)

```bash
python3 pf9-storage-audit.py \
    --netapp-host <netapp-ip> \
    --netapp-user admin \
    --svm <svm-name> \
    --host-iqn "compute-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9" \
    --host-iqn "compute-2=iqn.2004-10.com.ubuntu:01:ef99ea7be46" \
    --server <vm-uuid-or-name> \
    --dry-run
```

### 4. Apply fixes — changes NetApp immediately

```bash
python3 pf9-storage-audit.py \
    --netapp-host <netapp-ip> \
    --netapp-user admin \
    --svm <svm-name> \
    --host-iqn "compute-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9" \
    --host-iqn "compute-2=iqn.2004-10.com.ubuntu:01:ef99ea7be46" \
    --server <vm-uuid-or-name> \
    --remediate
```

> **Recommended order:** run without flags first → then `--dry-run` → then `--remediate`.

---

## Sample Output

### Clean environment (no issues)

```
✓  No igroup mapping issues detected.
```

---

### DUAL IGROUP detected

```
================================================================================
ISSUES FOUND: 1
================================================================================

  [DUAL IGROUP]
  VM           : prod-vm-07 (a1b2c3d4-...)  status=ACTIVE
  Volume       : vol-uuid-...
  Nova host    : compute-970-1   ← VM is HERE
  LUN maps     : 2 igroup(s)  ← DUAL MAPPING (most common production failure)
    ✓ cinder-iqn-abc...  →  IQN hosts: compute-970-1  [correct — nova host]
    ✗ cinder-iqn-def...  →  IQN hosts: compute-970-2  [stale — destination igroup]

Summary: 1 VM(s), 1 volume(s) with issues [dual_mapping=1, source_missing=0]

Run with --dry-run to preview remediation steps.
Run with --remediate to apply igroup fixes and print Cinder/iSCSI steps.
```

---

### SOURCE MISSING detected

```
================================================================================
ISSUES FOUND: 1
================================================================================

  [SOURCE MISSING]
  VM           : prod-vm-07 (a1b2c3d4-...)  status=ACTIVE
  Volume       : vol-uuid-...
  Nova host    : compute-970-1   ← VM is HERE
  LUN maps     : source igroup mapping is MISSING (removed by failed terminate_connection)
    ✗ cinder-iqn-def...  →  IQN hosts: compute-970-2  [wrong host — destination only]

Summary: 1 VM(s), 1 volume(s) with issues [dual_mapping=0, source_missing=1]
```

---

### Dry run — DUAL IGROUP case

Command used:
```bash
python3 pf9-storage-audit.py ... --server <vm-uuid> --dry-run
```

Output:
```
================================================================================
[DRY-RUN] REMEDIATION
================================================================================
Steps per finding:
  1. Fix NetApp LUN maps / igroup initiators  (automated here)
  2. iSCSI rescan                             (commands to run on the correct host)
  3. Nova BDM target_lun fix                  (SQL to run — review before applying)

── prod-vm-07 (a1b2c3d4-...) ──
   Nova host  : compute-970-1

  STEP 1: Fix NetApp LUN maps

    Volume  : vol-uuid-...
    LUN path: /vol/vol1/cinder-volume-vol-uuid-...
    [DRY-RUN] NetApp: remove LUN map → igroup 'cinder-iqn-def...' (igroup-uuid-...)
    Correct LUN ID (nova host's mapping): 3  ← use this for BDM fix in Step 3

  STEP 2: iSCSI rescan — run on compute-970-1:
    iscsiadm -m session -R
    iscsiadm -m node --login
    multipath -r
    multipath -ll | grep -E 'failed|faulty|0 paths'

  STEP 3: Nova BDM target_lun fix
    # target_lun / target_luns in Nova BDM may point to the destination LUN ID.
    # First, check current values and path count:
    mysql> SELECT instance_uuid,
                  JSON_EXTRACT(connection_info, '$.data.target_lun')  AS lun,
                  JSON_EXTRACT(connection_info, '$.data.target_luns') AS luns
           FROM block_device_mapping
           WHERE volume_id = 'vol-uuid-...'
             AND instance_uuid = 'a1b2c3d4-...'
             AND deleted = 0;

    # Then update — adjust JSON_ARRAY() length to match the path count above:
    # Volume vol-uuid-...  →  correct LUN ID = 3
    mysql> UPDATE block_device_mapping
           SET connection_info = JSON_SET(
               JSON_SET(connection_info, '$.data.target_lun', 3),
               '$.data.target_luns', JSON_ARRAY(3, 3, 3, 3)
           )
           WHERE volume_id = 'vol-uuid-...'
             AND instance_uuid = 'a1b2c3d4-...'
             AND deleted = 0;

================================================================================
After all steps, verify:
  virsh list --all           (on affected host — should not hang)
  multipath -ll              (no failed/faulty maps)
  openstack volume list      (volumes should be 'in-use')
  openstack server list      (VMs should be 'ACTIVE')
```

---

### Remediate — DUAL IGROUP case

Command used:
```bash
python3 pf9-storage-audit.py ... --server <vm-uuid> --remediate
```

Same output as dry run above, except Step 1 lines read:
```
    NetApp: remove LUN map → igroup 'cinder-iqn-def...' (igroup-uuid-...)
    Done.
```
The `[DRY-RUN]` prefix is gone and `Done.` confirms the change was applied.

---

### Remediate — SOURCE MISSING case

Command used:
```bash
python3 pf9-storage-audit.py ... --server <vm-uuid> --remediate
```

Output:
```
── prod-vm-07 (a1b2c3d4-...) ──
   Nova host  : compute-970-1

  STEP 1: Fix NetApp LUN maps

    Volume  : vol-uuid-...
    LUN path: /vol/vol1/cinder-volume-vol-uuid-...
    NetApp: remove LUN map → igroup 'cinder-iqn-def...' (igroup-uuid-dest)
    Done.
    NetApp: map LUN '/vol/vol1/cinder-volume-vol-uuid-...' → igroup 'cinder-iqn-abc...'
    Done.

  STEP 2: iSCSI rescan — run on compute-970-1:
    iscsiadm -m session -R
    iscsiadm -m node --login
    multipath -r
    multipath -ll | grep -E 'failed|faulty|0 paths'

  STEP 3: Nova BDM target_lun fix
    # Volume vol-uuid-...: LUN ID unknown — check NetApp and set manually
```

> If the source igroup cannot be found (IQN unknown and SSH unreachable),
> Step 1 prints a warning and skips the `add_lun_map` call.
> Supply the IQN via `--host-iqn` or `--ssh-user` and re-run.

---

### With host health checks (`--ssh-user root`)

When `--ssh-user` is provided, the script also checks each compute host's
health over SSH and prints a summary:

```
================================================================================
HOST HEALTH
================================================================================

  compute-970-1
    libvirtd     : active
    multipath    : 2 failed path(s)  ← ATTENTION
    D-state procs: none
    virsh        : 5 domain(s) visible

  compute-970-2
    libvirtd     : active
    multipath    : OK
    D-state procs: qemu-system-x86  ← ATTENTION
    virsh        : 4 domain(s) visible
```

---

### Ubuntu IQN warning (no `--host-iqn` supplied)

If IQNs are not provided and SSH is not available, the script warns per host:

```
  [WARN] compute-970-1: igroup check skipped — pass --host-iqn compute-970-1=<IQN>
         (get via: cat /etc/iscsi/initiatorname.iscsi)
✓  No igroup mapping issues detected.
```

The script can still report the LUN map state but cannot determine which
igroup entry is correct vs stale without knowing the host's IQN.

---

## All Options

| Option | Default | Description |
|--------|---------|-------------|
| `--netapp-host` | *(required)* | NetApp management IP or hostname |
| `--netapp-user` | `admin` | NetApp username |
| `--netapp-password` | *(prompted)* | NetApp password — prompted if omitted |
| `--svm` | *(all SVMs)* | Limit to a specific SVM (e.g. `cinder_svm`) — recommended |
| `--server` | *(all VMs)* | Check a single VM by UUID or name |
| `--ssh-user` | *(none)* | SSH user for compute hosts — enables IQN auto-fetch and health checks |
| `--ssh-key` | *(default key)* | Path to SSH private key |
| `--host-iqn` | *(none)* | Known IQN for a compute host: `--host-iqn hostname=iqn.xxx` — repeat per host |
| `--dry-run` | *(off)* | Show all remediation steps without making any changes |
| `--remediate` | *(off)* | Execute NetApp igroup fixes; print iSCSI rescan + BDM SQL steps |
| `--clean-mpath` | *(off)* | Scan compute hosts for mpath devices with all paths failed/ghost and flush them. Requires `--ssh-user`. Use with `--dry-run` to preview. |

---

## What Gets Fixed Automatically

| Step | What | How |
|------|------|-----|
| 1a | Remove stale destination LUN map (DUAL IGROUP) | **Automated** by `--remediate` |
| 1b | Re-add source LUN map (SOURCE MISSING, if IQN known) | **Automated** by `--remediate` |
| 2 | iSCSI rescan on correct compute host | **Printed** — run manually on the host |
| 3 | Fix Nova BDM `target_lun` + `target_luns` | **Printed** — SQL to review and run manually |
| 4 | Flush orphaned mpath devices (all paths failed) | **Automated** by `--clean-mpath --remediate` |

---

## Common Errors

**`Missing value auth-url required for auth plugin password`**
```bash
source openstack-rc.rc
```

**`'openstack' CLI not found`**
```bash
pip3 install python-openstackclient
```

**`Cannot reach NetApp at <host>: Network is unreachable`**
You are not on the correct network. Check VPN or run from inside the customer environment.

**`Found 0 VM(s)`**
RC file is sourced for the wrong project, or there are no VMs in the project.
Verify with `openstack server list --all`.

**`[WARN] <host>: igroup check skipped`**
No IQN is known for this host. The script detected a LUN map but cannot classify
it as correct or stale. Supply the IQN:
```bash
# On the compute host:
cat /etc/iscsi/initiatorname.iscsi

# Then re-run with:
--host-iqn "hostname=iqn.2004-10.com.ubuntu:01:..."
```

**`[WARN] Cannot find igroup for <host>`**
SOURCE MISSING case — the source igroup must be re-added but the host IQN is
unknown, so the script cannot locate the correct igroup. Supply the IQN as
above and re-run `--remediate`.

**`[MANUAL ACTION REQUIRED] NetApp rejected automatic removal`**
Older ONTAP versions require LUN maps to be removed before igroup initiators
can be deleted. Follow the printed NetApp System Manager steps, then re-run
`--remediate`.

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Clean — no issues found |
| `1` | Issues detected, or fatal error |
| `130` | Interrupted (Ctrl+C) |
