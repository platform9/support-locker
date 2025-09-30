# Kubernetes CNI Migration: Calico to Cilium

This orchestrator automates the migration of a Kubernetes cluster from **Calico** to **Cilium** as the Container Network Interface (CNI). It performs all the necessary steps for a safe, validated, and auditable transition — node by node.

---

## Overview

The script performs:

- Backup of state (resources/ objects) in the current cluster - excluding ETCD
- Pre-flight validation
- Per-node permission setup
- Cilium manifest installation
- Node-by-node migration:
  - Cordon and drain
  - Remove Calico CNI
  - Switch to Cilium
  - Validate pod network
- Connectivity checks via test pods
- Cilium policy enforcement enablement
- Final cleanup of Calico resources

---

## Prerequisites

Ensure the following before starting:

- Kubernetes cluster reachable via `kubectl`
- All nodes accessible via passwordless SSH (as `${SSH_USER}`)
- `sudo` must not prompt for password on remote nodes
- On the management host, the following tools must be installed:
  - `kubectl`
  - `curl`
  - `ssh`, `scp`
  - `jq`

---

## Usage

### Customize Variables

Set the following variables at the top of the script to match your environment:

| Variable                        | Description                                            |
| ------------------------------- | ------------------------------------------------------ |
| `CILIUM_CLI_VERSION_OVERRIDE`   | Version of `cilium-cli` to use                         |
| `CILIUM_TARGET_CLUSTER_VERSION` | Cilium CNI version to use                              |
| `CILIUM_IPV4_CLUSTER_POOL_CIDR` | Cilium pod IP pool (e.g., `10.42.0.0/16`)              |
| `SSH_USER`                      | SSH user for node access (must have passwordless sudo) |
| `SLEEP_AFTER_DRAIN`             | sleep time in seconds after each node drain            |
| `DS_ROLLOUT_TIMEOUT`            | cilium daemonset rollout timeout                       |
| `CILIUM_INTERFACE`              | network interface for cilium to pick                   |

###  Make the Script Executable

```bash
chmod +x migrate-cni.sh
./migrate-cni.sh
```

### Note:
To completely automate the script without any interactive prompts, set the environment variable AUTO_APPROVE=true. This will auto-approve all confirmation prompts and proceed without manual input.
Additionally, if the script runs in a non-interactive terminal (like CI/CD), it will auto-approve by default.

AUTO_APPROVE=true ./migrate-cni.sh

---

### Post-Migration

After the migration from Calico to Cilium is complete, the cluster details in UI would still display "Calico" and its containers cidr. This is outdated metadata and does not reflect the actual state of the cluster.
You can use the "/update_cni_on_migration" QBERT API specifically for this.

More info: https://platform9.com/docs/qbert

---

## Migration Phases

### Phase 1: Node Preparation (Pre-Cilium)

- Ensures required CNI directories are writable on each node
- Ensures nodelet is aware of cilium yamls/scripts on each node.
- Uses `kubectl debug` to modify permissions
- Falls back to manual SSH if `kubectl debug` fails

---

### Phase 2: Cilium Deployment and Node Migration

- Installs the `cilium` CLI if not present
- Applies the `cilium.yaml` manifest
- Waits for DaemonSet and operator rollout

Then migrates each node sequentially:

- Cordon and drain the node
- Remotely execute `cleanup_cni_files` via SSH
- Restart the kubelet
- Uncordon the node and verify Cilium health
- Create a test pod to:
    - Ping `8.8.8.8`
    - Optionally test DNS
- Clean up the test pod

---

### Phase 3: Post-Migration Cleanup

- Updates Cilium policy mode: `enable-policy=default`
- Re-applies the Cilium manifest
- Restarts the Cilium DaemonSet
- Deletes remaining Calico components:
    - DaemonSets and Deployments
    - ConfigMaps and Services
    - CRDs, RBAC bindings, ServiceAccounts
    - Residual files on each node via SSH
