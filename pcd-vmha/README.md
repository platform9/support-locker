# VMHA Role Verification & Remediation


Whenever **VMHA is enabled** (for example, you disable VMHA and enable it again), you **must run the HA validation scripts**.

This is also required:

* After January (Jan) upgrade
* After any VMHA re-initialization

If not executed, some hosts may not have the `pf9-ha-slave` role installed.

---

## Why Is This Needed?


Some hosts may:

* Be missing the role
* Have incomplete role installation
* Be inconsistent after upgrade

To fix this, we use two scripts:

1. `list_missing_ha_hosts.sh`
2. `apply_ha_role.sh`

---

# Step 1 – List Hosts Missing `pf9-ha-slave` Role

### Script

```bash
list_missing_ha_hosts.sh
```

### Usage

```bash
./list_missing_ha_hosts.sh > missing_hosts.txt
```

You will be prompted for:

* DU FQDN
* Auth Token (Keystone Token)

### Output File Format

The generated file (`missing_hosts.txt`) contains entries in the format:

```text
host_id | hostname | cluster_name | responding | hypervisor_status | current_roles
```

### Sample `missing_hosts.txt`

```bash
cat missing_hosts.txt
# host_id | hostname | cluster_name | responding | pf9-ostackhost-neutron_status | current_roles
# Generated: 2026-02-24 13:58:24 | DU: test-du-drr-4430735-hkg.app.qa-pcd.platform9.com
#
1b71fc78-77ce-4049-8fa8-487c1e065f95 | test-pf9-drr-4430735-290-1 | auto-cluster1 | true | applied | pf9-cindervolume-base,pf9-cindervolume-config,pf9-glance-role,pf9-ip-discovery,pf9-neutron-base,pf9-neutron-ovn-controller,pf9-neutron-ovn-metadata-agent,pf9-ostackhost-neutron
```

---

# Step 2 – Apply `pf9-ha-slave` Role

### Script

```bash
apply_ha_role.sh
```

### Usage

```bash
./apply_ha_role.sh missing_hosts.txt
```

### Expected File Format

The input file must be generated from:

```bash
./list_missing_ha_hosts.sh
```

Each line must follow:

```text
host_id | hostname | cluster_name | responding | hypervisor_status | current_roles
```

* Lines starting with `#` are ignored
* Empty lines are skipped

---

# Recommended Execution Flow

```bash
# Step 1: Identify missing HA roles
./list_missing_ha_hosts.sh > missing_hosts.txt

# Step 2: Apply HA role
./apply_ha_role.sh missing_hosts.txt
```

---

# Post-Run Validation and Retry

After running `./apply_ha_role.sh missing_hosts.txt`, wait a few minutes and verify again:

```bash
./list_missing_ha_hosts.sh > missing_hosts.txt
```

If the new `missing_hosts.txt` is empty, no further action is required.

If hosts are still missing the `pf9-ha-slave` role, repeat the same flow:

```bash
./apply_ha_role.sh missing_hosts.txt
```

If some hosts are unreachable, resolve host connectivity first, then run the apply step again using the latest `missing_hosts.txt`.

---

# When To Run These Scripts

| Scenario                              | Required |
| ------------------------------------- | -------- |
| VMHA disabled → enabled               | Yes      |
| After Jan upgrade                     | Yes      |
| Fresh HA configuration on new cluster | Yes      |

---

# Expected Outcome

After running both scripts:

* All eligible hosts will have `pf9-ha-slave` role installed
* VMHA will function correctly
* HA state will be consistent across the cluster
