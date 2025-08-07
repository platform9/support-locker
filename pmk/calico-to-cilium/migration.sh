#!/bin/bash
# ==============================================================================
# WARNING: CRITICAL CNI MIGRATION ORCHESTRATOR - USE WITH EXTREME CAUTION!
# ==============================================================================
# This script orchestrates the Calico to Cilium migration from a central
# management machine. It relies on 'node_migration_task.sh' to be executed
# locally on each cluster node.
#
# SSH ACCESS REQUIREMENT (for transferring and executing node script):
# - The user running this script MUST have passwordless SSH access to ALL nodes
#   as the specified SSH_USER.
# - The SSH_USER MUST have passwordless sudo privileges on all nodes for all
#   commands executed by 'node_migration_task.sh'.
#
# MANUAL INTERVENTION:
# 1. Manual editing of the 'cilium.yaml' manifest after it's generated (CRITICAL).
# 2. Manual verification steps throughout the process.
#
# Ensure you have recent backups of your entire Kubernetes cluster (etcd, resources).
# ==============================================================================

# --- Configuration Variables ---
# !!! IMPORTANT: REVIEW AND CONFIGURE THESE !!!
CILIUM_CLI_VERSION_OVERRIDE="v0.18.5" # Explicitly setting to your currently working cilium-cli version
CILIUM_TARGET_CLUSTER_VERSION="v1.17.5" # <--- IMPORTANT: Set this to the Cilium CNI version you want to deploy
CILIUM_IPV4_CLUSTER_POOL_CIDR="10.42.0.0/16" # Example: REPLACE THIS with your actual UNUSED CIDR
CALICO_NODE_IMAGE="calico/node:v3.27.2" # Your confirmed Calico image version
CILIUM_INTERFACE="" # <--- IMPORTANT: Change this to your preferred network interface for cilium to pick. If left empty, interface having default route will be picked.
SSH_USER="root" # <--- IMPORTANT: Change this to your SSH user on the nodes (MUST have passwordless sudo)
SLEEP_AFTER_DRAIN=30 # Default sleep time (in seconds) after draining a node before continuing

KUBE_SYSTEM_NAMESPACE="kube-system"
BACKUP_DIR="${HOME}/k8s_migration_backup_$(date +%Y%m%d%H%M%S)"
CILIUM_MANIFEST_FILE="cilium.yaml"

NODE_TASK_SCRIPT_NAME="node_migration_task.sh"
REMOTE_NODE_TASK_PATH="/tmp/${NODE_TASK_SCRIPT_NAME}" # Path to store script on remote node

# --- Helper Functions ---
log() { echo "--- $(date '+%Y-%m-%d %H:%M:%S') --- $1"; }
confirm() {
  local prompt_message="$1"
  local ANSWER
  # Auto-approve if flag is set
  if [ "${AUTO_APPROVE}" = true ]; then
    log "Auto-approve enabled: proceeding without confirmation for prompt: ${prompt_message}"
    return 0
  fi

  # Auto-approve if no interactive terminal
  if [ ! -t 0 ]; then
    log "No terminal detected for input — auto-approving prompt: ${prompt_message}"
    return 0
  fi
  while true; do
    read -p "${prompt_message} (yes/no): " ANSWER
    case "$ANSWER" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]) log "Operation aborted by user."; exit 1 ;;
      *) log "Invalid input. Please type 'yes' or 'no'.";;
    esac
  done
}
check_command() { if ! command -v "$1" &> /dev/null; then log "Error: '$1' command not found. Please install it and ensure it's in your PATH."; exit 1; fi; }

# --- SSH Command Execution Function (for orchestraor to invoke node script) ---
run_on_node_ssh() {
  local node_ip="$1"
  local command_to_run="$2"
  log "Executing on ${node_ip}: ${command_to_run}"
  # Use BatchMode and StrictHostKeyChecking=no for non-interactive SSH
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SSH_USER}@${node_ip}" "${command_to_run}" < /dev/null
  if [ $? -ne 0 ]; then
    log "Error: Command failed on node ${node_ip}."
    return 1 # Indicate failure
  fi
  return 0 # Indicate success
}


# --- Phase 0: Prerequisites ---
log "=============================================================="
log "  VERIFY THE FOLLOWING CONFIGURATION BEFORE PROCEEDING"
log "=============================================================="
echo ""
echo " CILIUM_CLI_VERSION_OVERRIDE     = ${CILIUM_CLI_VERSION_OVERRIDE}"
echo " CILIUM_TARGET_CLUSTER_VERSION   = ${CILIUM_TARGET_CLUSTER_VERSION}"
echo " CILIUM_IPV4_CLUSTER_POOL_CIDR   = ${CILIUM_IPV4_CLUSTER_POOL_CIDR}"
echo " CALICO_NODE_IMAGE               = ${CALICO_NODE_IMAGE}"
echo " CILIUM_INTERFACE                = ${CILIUM_INTERFACE:-<auto-detected default route interface>}"
echo " SSH_USER                        = ${SSH_USER}"
echo " SLEEP_AFTER_DRAIN (seconds)     = ${SLEEP_AFTER_DRAIN}"
echo ""
log "IMPORTANT: If any of the above are incorrect, edit the script before continuing."
confirm "Do you want to proceed with the above configuration?"

log "PHASE 0: Checking Prerequisites..."
check_command kubectl; check_command curl; check_command scp; check_command ssh; check_command jq # Added jq check

log "Verifying kubectl access to cluster..."
kubectl cluster-info > /dev/null 2>&1 || { log "Error: kubectl is not configured correctly or cannot connect to the cluster."; exit 1; }
log "kubectl is configured and connected."

# --- Install cilium-cli (on the management host) ---
log "PHASE 0: Installing cilium-cli (on this management host)..."
if ! command -v /usr/local/bin/cilium &> /dev/null; then
  log "Cilium CLI not found at /usr/local/bin/cilium. Proceeding with download and install."
  if [ -z "${CILIUM_CLI_VERSION_OVERRIDE}" ]; then CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt); else CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION_OVERRIDE}"; fi
  CLI_ARCH=$(uname -m); case "$CLI_ARCH" in x86_64) CLI_ARCH="amd64" ;; aarch64) CLI_ARCH="arm64" ;; *) log "Unsupported architecture: ${CLI_ARCH}."; exit 1 ;; esac
  log "Downloading cilium-cli v${CILIUM_CLI_VERSION} for ${CLI_ARCH} architecture..."
  curl -L --fail --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}" || { log "Error: Failed to download cilium-cli."; exit 1; }
  log "Verifying cilium-cli checksum..."; sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum" || { log "Error: cilium-cli checksum mismatch."; exit 1; }
  log "Installing cilium-cli to /usr/local/bin/..."; if [ ! -d "/usr/local/bin" ]; then sudo mkdir -p /usr/local/bin || { log "Error: Failed to create /usr/local/bin."; exit 1; }; fi
  sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin; TAR_EXIT_CODE=$?
  if [ ${TAR_EXIT_CODE} -ne 0 ]; then log "Error: Failed to install cilium-cli via tar. Exit code: ${TAR_EXIT_CODE}."; confirm "Cilium CLI installation failed via tar. Proceed anyway? (HIGH RISK)"; fi
  if [ ! -f "/usr/local/bin/cilium" ]; then log "ERROR: /usr/local/bin/cilium was NOT found after tar extraction. Cilium CLI installation failed."; exit 1; fi
  log "Cilium binary found at /usr/local/bin/cilium."; rm "cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}
else
  log "Cilium CLI already found at /usr/local/bin/cilium. Skipping download and install."
fi
log "Verifying cilium-cli installation..."; /usr/local/bin/cilium version --client || { log "Error: cilium-cli not installed correctly or not in PATH."; exit 1; }
log "cilium-cli installed successfully."

confirm "Prerequisites checked. Continue with migration script?"

# --- Phase 1: Preparation and Planning ---
log "PHASE 1: Preparation and Planning..."

log "1.1. Verifying Current Calico Status..."
kubectl get pods -n ${KUBE_SYSTEM_NAMESPACE} -l k8s-app=calico-node
kubectl get deployments -n ${KUBE_SYSTEM_NAMESPACE} -l k8s-app=calico-kube-controllers
kubectl get ds,deploy -n ${KUBE_SYSTEM_NAMESPACE} | grep calico
kubectl get ippools -o yaml

log "1.2. Creating Backup Directory: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}" || { log "Error: Failed to create backup directory."; exit 1; }

log "1.3. Backing up Kubernetes Cluster State..."
kubectl get all --all-namespaces -o yaml > "${BACKUP_DIR}/all_resources_backup.yaml" || { log "Backup failed."; exit 1; }
kubectl get crd -o yaml > "${BACKUP_DIR}/all_crds_backup.yaml" || { log "Backup failed."; exit 1; }
kubectl get clusterrole,clusterrolebinding,role,rolebinding --all-namespaces -o yaml > "${BACKUP_DIR}/all_rbac_backup.yaml" || { log "Backup failed."; exit 1; }
kubectl get networkpolicy --all-namespaces -o yaml > "${BACKUP_DIR}/calico_k8s_network_policies.yaml" || { log "Backup failed."; exit 1; }
kubectl get globalnetworkpolicy -o yaml > "${BACKUP_DIR}/calico_global_network_policies.yaml" || { log "Backup failed."; exit 1; }
log "Cluster resources backed up to ${BACKUP_DIR}"
log "IMPORTANT: Ensure you have a separate etcd backup strategy for your cluster!"

if [[ -f "${CILIUM_MANIFEST_FILE}" ]]; then
    log "WARNING: '${CILIUM_MANIFEST_FILE}' already exists. Skipping manifest generation to avoid overwriting user modifications."
    log "If you want to regenerate the manifest, please delete or rename '${CILIUM_MANIFEST_FILE}' manually and rerun the script."
else
    log "1.4. Generating Raw Cilium Manifests using cilium-cli (IPAM mode: cluster-pool)..."
    /usr/local/bin/cilium install --dry-run \
	--version "${CILIUM_TARGET_CLUSTER_VERSION}" \
	--set cni.chaining.enabled=true \
	--set cni.chaining.mode="generic-veth" \
	--set kubeProxyReplacement=true \
	--set bpf.masquerade=true \
	--set ipam.mode=cluster-pool \
	--set ipam.operator.clusterPoolIPv4PodCIDRList="{$CILIUM_IPV4_CLUSTER_POOL_CIDR}" \
	--set operator.unmanagedPodWatcher.restart=false \
	--set policyEnforcementMode=never \
	--set cleanCilumetdFiles=false \
	--set cleanLocalCiliumFiles=false \
	--set devices="{$CILIUM_INTERFACE}" \
	> "${CILIUM_MANIFEST_FILE}" || { log "Error: Failed to generate Cilium manifests with cilium-cli."; exit 1; }

    if [ -z "$CILIUM_INTERFACE" ]; then
        sed -i '/^[[:space:]]*devices:.*$/d' "${CILIUM_MANIFEST_FILE}"
        log "WARNING: No network interface provided, proceeding with default cilium interface detection."
    fi

    log "Cilium manifests generated to: ${CILIUM_MANIFEST_FILE}"

    log "======================================================================"
    log "CRITICAL MANUAL STEP: CONFIGURE ${CILIUM_MANIFEST_FILE}"
    log "======================================================================"
    log "You MUST manually inspect and edit '${CILIUM_MANIFEST_FILE}'."
    log "Open the file in a text editor (e.g., nano ${CILIUM_MANIFEST_FILE})."
    log "You need to replace specific placeholders and verify settings:"
    log ""
    log "1.  Replace '__IPV4_ENABLED__' with 'true' (if using IPv4, usually yes)."
    log "    Look for: 'enable-ipv4: \"__IPV4_ENABLED__\"' and 'k8s-require-ipv4-pod-cidr: \"__IPV4_ENABLED__\"'"
    log ""
    log "2.  Replace '__MASTER_IP__' with your Kubernetes API Service Virtual IP (VIP) for multi-master cluster."
    log "    Get the VIP by consulting your load balancer or network configuration."
    log "    Look for: 'value: \"__MASTER_IP__\"' under KUBERNETES_SERVICE_HOST env var."
    log ""
    log "3.  (Conditional) If your 'ipam' is set to 'cluster-pool' (in cilium-config):"
    log "    Replace '__CILIUM_IPV4POOL_CIDR__' with the CIDR you defined (e.g., ${CILIUM_IPV4_CLUSTER_POOL_CIDR})."
    log "    Example: 'cluster-pool-ipv4-cidr: \"10.42.0.0/16\"'"
    log "    Confirm 'cluster-pool-ipv4-mask-size' is appropriate (e.g., '24' for /24 per node)."
    log ""
    log "4.  Replace '__CILIUM_INSTALL_CNI_CPU__' with '100m' and '__CILIUM_INSTALL_CNI_MEMORY__' with '100Mi'."
    log "    These are for resource requests of the 'install-cni-binaries' initContainer."
    log ""
    log "5.  Review image tags (e.g., quay.io/cilium/cilium:v1.17.5). Ensure they match your desired Cilium version."
    log "    If the generated YAML has a different version than your target, consider manually adjusting it."
    log ""
    log "Add any other custom configurations (e.g., specific tolerations, resource limits) as needed."
    log "Save the file after your modifications."
    log "======================================================================"
    confirm "I have carefully inspected and, if necessary, edited '${CILIUM_MANIFEST_FILE}' and saved it. Continue?"
fi

# --- Phase 1.5: Copy Node Task Script to All Nodes ---
log "PHASE 1.5: Copying '${NODE_TASK_SCRIPT_NAME}' to all nodes and making it executable."
# Create node_migration_task.sh locally
cat <<'EOF_NODE_SCRIPT' > "${NODE_TASK_SCRIPT_NAME}"
#!/bin/bash
# Node-specific migration tasks script
# This script is executed locally on each Kubernetes node.

log_node() {
  echo "--- $(date '+%Y-%m-%d %H:%M:%S') --- NODE $(hostname): $1"
}

# --- Automated Calico IPTables Cleanup Function (Local Execution) ---
perform_local_calico_iptables_cleanup() {
log_node "FORCE-CLEANING all IPv4 iptables rules and user-defined chains (Calico wipeout mode)..."

  for table in filter nat mangle raw; do
    log_node "Flushing IPv4 table: $table"
    sudo iptables -t "$table" -F || true
    sudo iptables -t "$table" -X || true
  done

  # Final verification
  remaining=$(sudo iptables-save | grep -c cali)

  if [ "$remaining" -eq 0 ]; then
    log_node "All Calico-related IPv4 iptables entries removed."
    return 0
  else
    log_node "Still $remaining cali-* entries found in IPv4 iptables."
    return 1
  fi
}

# --- Main Node Task Execution ---
case "$1" in
  prepare_node)
    log_node "Starting node preparation tasks."
    log_node "Creating cilium configs for nodelet"
    mkdir -p /opt/pf9/pf9-kube/network_plugins/cilium
    # Write the cilium.sh script into that directory
    cat << 'EOF' > /opt/pf9/pf9-kube/network_plugins/cilium/cilium.sh
    #!/bin/bash

    #### Required interface function definitions

	function network_running()
	{
		if [ "$ROLE" == "none" ]; then
			return 1
		fi
		return 0
	}

	function ensure_network_running()
	{
		if [ "$PF9_MANAGED_DOCKER" != "false" ]; then
			delete_docker0_bridge_if_present
		fi

		if [ "$ROLE" == "master" ] || [ "${MASTERLESS_ENABLED}" == "true" ] ; then
			deploy_cilium_daemonset
		fi
	}

	function write_cni_config_file()
	{
		return 0
	}

	function ensure_network_config_up_to_date()
	{
		return 0
	}

	function ensure_network_controller_destroyed()
	{
		remove_cilium_tunnel_iface
	}

	#### Plugin specific methods

	function deploy_cilium_daemonset()
	{
		local cilium_app="${CONF_SRC_DIR}/networkapps/cilium.yaml"
		${KUBECTL_SYSTEM} apply -f ${cilium_app}
	}

	function delete_docker0_bridge_if_present()
	{
	   ip link set dev docker0 down || true
	   ip link del docker0 || true
	}

	function remove_cilium_tunnel_iface()
	{
	  ip link del cilium_net || true
	  ip link del cilium_host || true
	}
EOF
    chmod +x /opt/pf9/pf9-kube/network_plugins/cilium/cilium.sh
    echo "export PF9_NETWORK_PLUGIN=\"cilium\"" >> /etc/pf9/kube_override.env
    echo "export CONTAINERS_CIDR=\"__CILIUM_CIDR_PLACEHOLDER__\"" >> /etc/pf9/kube_override.env
    log_node "Restarting pf9-kubelet service."
    sudo systemctl restart pf9-kubelet || { log_node "ERROR: Failed to restart pf9-kubelet."; exit 1; }

    log_node "Node preparation tasks complete."
    ;;
  cleanup_cni_files)
    log_node "Starting CNI file cleanup tasks."
    log_node "Removing Calico CNI configuration files."
    sudo rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/10-calico.conf || { log_node "ERROR: Failed to remove Calico CNI files."; exit 1; }
    log_node "Verifying Cilium's CNI config is present."
    ls -l /etc/cni/net.d/ | grep 05-cilium.conflist || { log_node "ERROR: Cilium CNI config not found. Manual check needed."; exit 1; }
    log_node "Restarting pf9-kubelet service for CNI switch."
    sudo systemctl restart pf9-kubelet || { log_node "ERROR: Failed to restart pf9-kubelet after CNI switch."; exit 1; }
    log_node "CNI file cleanup tasks complete."
    ;;
  final_cleanup)
    log_node "Starting final node cleanup tasks."
    log_node "Removing residual Calico files."
    sudo rm -rf /var/lib/calico/ /etc/cni/net.d/*calico* || { log_node "WARNING: Failed to remove some Calico files. Manual intervention may be needed."; }
    log_node "Running final Calico iptables cleanup."
    perform_local_calico_iptables_cleanup || { log_node "WARNING: Final Calico iptables cleanup failed locally."; } # Don't exit here, just warn
    log_node "Restarting pf9-kubelet service after final cleanup."
    sudo systemctl restart pf9-kubelet || { log_node "WARNING: Failed to restart pf9-kubelet after final cleanup. Manual intervention may be needed."; }
    log_node "Final node cleanup tasks complete."
    ;;
  *)
    log_node "Usage: sudo ./node_migration_task.sh {prepare_node|cleanup_cni_files|final_cleanup}"
    exit 1
    ;;
esac
EOF_NODE_SCRIPT

sed -i "s|__CILIUM_CIDR_PLACEHOLDER__|${CILIUM_IPV4_CLUSTER_POOL_CIDR}|g" "${NODE_TASK_SCRIPT_NAME}"
chmod +x "${NODE_TASK_SCRIPT_NAME}" || { log "Error: Failed to make ${NODE_TASK_SCRIPT_NAME} executable."; exit 1; }
log "Local node task script '${NODE_TASK_SCRIPT_NAME}' created and made executable."

ALL_NODES_INFO=$(kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) \([.status.addresses[] | select(.type=="InternalIP") | .address][0])"')
if [ -z "${ALL_NODES_INFO}" ]; then
  log "ERROR: Could not retrieve node names and Internal IPs. ALL_NODES_INFO is empty."
  log "Please ensure all nodes are in 'Ready' state and have 'InternalIP' addresses in their status."
  exit 1
fi

log "Detected nodes for migration: $(echo "${ALL_NODES_INFO}" | wc -l) nodes"
log "List of nodes to process: "
while IFS= read -r NODE_INFO_LINE || [[ -n "$NODE_INFO_LINE" ]]; do # FIX: Added || [[ -n "$NODE_INFO_LINE" ]] for robustness for last line
  if [[ -z "$NODE_INFO_LINE" ]]; then continue; fi # Skip empty lines

  NODE_NAME=$(echo "${NODE_INFO_LINE}" | awk '{print $1}')
  NODE_IP=$(echo "${NODE_INFO_LINE}" | awk '{print $2}')

  if [ -z "${NODE_NAME}" ] || [ -z "${NODE_IP}" ]; then
    log "WARNING: Skipping malformed node info line: '${NODE_INFO_LINE}'. Node name or IP is missing."
    continue
  fi

  log "--- Copying '${NODE_TASK_SCRIPT_NAME}' to node ${NODE_NAME} (${NODE_IP}) ---"
  scp -o BatchMode=yes -o StrictHostKeyChecking=no "${NODE_TASK_SCRIPT_NAME}" "${SSH_USER}@${NODE_IP}:${REMOTE_NODE_TASK_PATH}"
  if [ $? -ne 0 ]; then
    log "ERROR: Failed to copy '${NODE_TASK_SCRIPT_NAME}' to node ${NODE_NAME}. SSH access issue. Aborting."
    log "Verify SSH setup for ${SSH_USER} to ${NODE_IP}."
    exit 1
  fi

  log "--- Copying '${CILIUM_MANIFEST_FILE}' to node ${NODE_NAME} (${NODE_IP}) ---"
  scp -o BatchMode=yes -o StrictHostKeyChecking=no "${CILIUM_MANIFEST_FILE}" "${SSH_USER}@${NODE_IP}:/opt/pf9/pf9-kube/conf/networkapps/"
  if [ $? -ne 0 ]; then
    log "ERROR: Failed to copy '${CILIUM_MANIFEST_FILE}' to node ${NODE_NAME}. SSH access issue. Aborting."
    log "Verify SSH setup for ${SSH_USER} to ${NODE_IP}."
    exit 1
  fi

  log "Node task script copied to ${NODE_NAME}."
done <<< "$ALL_NODES_INFO"
rm "${NODE_TASK_SCRIPT_NAME}" # Clean up local copy
log "Node preparation complete: node task script deployed to all nodes. Proceeding to apply Cilium manifests."

# --- Phase 1.6: Prepare Nodes (Pre-Cilium Manifest Application) ---
log "PHASE 1.6: Preparing Nodes for Cilium Installation (Pre-Manifest Application)."
log "Adjusting permissions on /opt/cni/bin on all nodes (required for Cilium CNI install)."
log "This requires 'kubectl debug node' permissions and access to a 'busybox' image."

ALL_NODES=$(kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers)
for NODE_NAME in ${ALL_NODES}; do
  log "--- Attempting to set /opt/cni/bin to 777 on node ${NODE_NAME} ---"
  # This command might return a non-zero exit code if permissions are insufficient or image not found.
  # Removing the 'continue' allows the command to be attempted on all nodes, including control-plane.
  kubectl debug node/${NODE_NAME} --image=busybox -- /bin/sh -c "chroot /host chmod 777 /opt/cni/bin"
  
  if [ $? -ne 0 ]; then
    log "WARNING: Automated permission adjustment failed for node ${NODE_NAME}. This is CRITICAL."
    log "You MUST manually SSH into this node and run 'sudo chmod 777 /opt/cni/bin'."
    confirm "Have you manually adjusted permissions on /opt/cni/bin on node ${NODE_NAME}? (Type 'yes' to continue)"
  else
    log "Permissions adjusted successfully on node ${NODE_NAME}."
  fi
done
log "Node preparation complete. Proceeding to apply Cilium manifests."

# --- Phase 2: Apply Cilium Manifests & Node-by-Node Migration ---
log "PHASE 2: Apply Cilium Manifests & Node-by-Node Migration..."

log "2.1. Applying Initial Cilium Kubernetes Manifests..."
kubectl apply -f "${CILIUM_MANIFEST_FILE}" || { log "Error: Failed to apply Cilium manifests."; exit 1; }
log "Cilium manifests applied. Waiting for pods to be ready..."
kubectl rollout status ds/cilium -n ${KUBE_SYSTEM_NAMESPACE} --timeout=5m || { log "Cilium DaemonSet did not become ready."; exit 1; }
kubectl rollout status deploy/cilium-operator -n ${KUBE_SYSTEM_NAMESPACE} --timeout=5m || { log "Cilium Operator did not become ready."; exit 1; }

log "2.2. Verifying Initial Cilium Status (should be mostly healthy, but not yet managing all endpoints)."
CILIUM_AGENT_POD_NAME=$(kubectl get pods -n ${KUBE_SYSTEM_NAMESPACE} -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "${CILIUM_AGENT_POD_NAME}" -n ${KUBE_SYSTEM_NAMESPACE} -- cilium status --brief

log "======================================================================"
log "STARTING NODE-BY-NODE MIGRATION"
log "======================================================================"

# Loop through all nodes, but perform specific actions based on node type
ALL_NODES_INFO=$(kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) \([.status.addresses[] | select(.type=="InternalIP") | .address][0])"') # Corrected jq
MIGRATED_NODES_COUNT=0
TOTAL_NODES=$(echo "${ALL_NODES_INFO}" | wc -l)

# Process all nodes robustly using mapfile and for-loop
mapfile -t NODE_LINES <<< "$ALL_NODES_INFO"
for NODE_INFO_LINE in "${NODE_LINES[@]}"; do
  if [[ -z "$NODE_INFO_LINE" ]]; then continue; fi # Skip empty lines

  NODE_NAME=$(echo "${NODE_INFO_LINE}" | awk '{print $1}')
  NODE_IP=$(echo "${NODE_INFO_LINE}" | awk '{print $2}')

  if [ -z "${NODE_NAME}" ] || [ -z "${NODE_IP}" ]; then
    log "WARNING: Skipping malformed node info line in migration loop: '${NODE_INFO_LINE}'. Node name or IP is missing."
    continue
  fi

  IS_CONTROL_PLANE_NODE=false
  if kubectl get node "${NODE_NAME}" -o jsonpath='{.metadata.labels}' | grep -q 'node-role.kubernetes.io/control-plane\|node-role.kubernetes.io/master'; then
    IS_CONTROL_PLANE_NODE=true
    log "--- Node ${NODE_NAME} (${NODE_IP}) is a Control-Plane node. ---"
  else
    log "--- Node ${NODE_NAME} (${NODE_IP}) is a Worker node. ---"
  fi

  log "--- Migrating Node: ${NODE_NAME} (Currently migrated: ${MIGRATED_NODES_COUNT} / ${TOTAL_NODES}) ---"

  confirm "Proceed with migration for node ${NODE_NAME} (${NODE_IP})? Ensure you are ready for a brief disruption on this node."

  log "2.3. Cordoning node: ${NODE_NAME}"
  kubectl cordon "${NODE_NAME}" || { log "Error: Failed to cordon node ${NODE_NAME}. Aborting."; exit 1; }

  log "2.4. Draining node: ${NODE_NAME}"
  # Note: Draining control-plane nodes can cause 'etcdserver: leader changed' errors and instability.
  # If this fails, investigate etcd health before proceeding.
  kubectl drain "${NODE_NAME}" --ignore-daemonsets --delete-emptydir-data --force --timeout=10m
  if [ $? -ne 0 ]; then
    log "ERROR: Failed to drain node ${NODE_NAME}. This is a critical error, often due to control-plane instability (e.g., etcd issues)."
    log "Please investigate your cluster's health (especially etcd logs) before retrying or forcing."
    confirm "Draining node ${NODE_NAME} failed. Proceeding could cause severe issues. Do you wish to continue anyway? (Type 'yes' to risk it): "
    if [[ "$ANSWER" != "yes" ]]; then
        log "Operation aborted due to drain failure and user choice."
        exit 1
    fi
  fi

  log "Waiting for drained pods to fully terminate on ${NODE_NAME} (sleeping ${SLEEP_AFTER_DRAIN}s)..."
  sleep "${SLEEP_AFTER_DRAIN}"

  log "======================================================================"
  log "AUTOMATED NODE-LEVEL CNI CONFIGURATION ON NODE: ${NODE_NAME}"
  log "======================================================================"
  log "Executing node_migration_task for prepare_node on node ${NODE_NAME}."

  if ! run_on_node_ssh "${NODE_IP}" "sudo ${REMOTE_NODE_TASK_PATH} prepare_node"; then
	  log "ERROR: Automated node-level CNI cleanup failed on ${NODE_NAME}. Manual intervention required."
	  confirm "Manual node CNI cleanup needed on ${NODE_NAME}. Proceed anyway? (HIGH RISK)"
  else
	  log "Node-level CNI cleanup and pf9-kubelet restart completed successfully on ${NODE_NAME}."
  fi

  log "Executing node_migration_task.sh for 'cleanup_cni_files' on node ${NODE_NAME}."
  # Execute the node-specific task script
  if ! run_on_node_ssh "${NODE_IP}" "sudo ${REMOTE_NODE_TASK_PATH} cleanup_cni_files"; then
    log "ERROR: Automated node-level CNI cleanup failed on ${NODE_NAME}. Manual intervention required."
    confirm "Manual node CNI cleanup needed on ${NODE_NAME}. Proceed anyway? (HIGH RISK)"
  else
    log "Node-level CNI cleanup and pf9-kubelet restart completed successfully on ${NODE_NAME}."
  fi
  
  log "======================================================================"
  log "Automated CNI config and pf9-kubelet restart complete for node ${NODE_NAME}."
  confirm "Node ${NODE_NAME} is now configured with Cilium CNI. Proceed to uncordon and test?"

  log "2.5. Uncordoning node: ${NODE_NAME}"
  kubectl uncordon "${NODE_NAME}" || { log "Error: Failed to uncordon node ${NODE_NAME}. Manual intervention required."; }

  log "2.6. Verifying Cilium status on node ${NODE_NAME} (should show it as managed by Cilium)"
  CILIUM_AGENT_POD_NAME=$(kubectl get pods -n ${KUBE_SYSTEM_NAMESPACE} -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' --field-selector spec.nodeName="${NODE_NAME}")
  kubectl exec -it "${CILIUM_AGENT_POD_NAME}" -n ${KUBE_SYSTEM_NAMESPACE} -- cilium status --brief

  log "2.7. Verifying pods on ${NODE_NAME} are getting IPs from Cilium"
  kubectl get pods -o wide --field-selector spec.nodeName="${NODE_NAME}"

  # --- AUTOMATED CONNECTIVITY TESTS ---
  log "2.8. Performing automated connectivity tests on node ${NODE_NAME}..."
  TEST_POD_NAME="cilium-test-pod-${NODE_NAME//./-}-$(date +%s)" # Sanitize node name and add timestamp for uniqueness
  TEST_FAILED=false # Reset for current node

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD_NAME}
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: "${NODE_NAME}"
  containers:
  - name: busybox
    image: busybox
    command: ["sleep", "3600"]
  restartPolicy: Never
  tolerations:
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"
EOF

  log "Waiting for test pod ${TEST_POD_NAME} to be ready on node ${NODE_NAME}..."
  if ! kubectl wait --for=condition=ready pod/"${TEST_POD_NAME}" -n default --timeout=180s; then
    log "Error: Test pod ${TEST_POD_NAME} did not become ready on node ${NODE_NAME} within timeout."
    TEST_FAILED=true
  fi

  if [ "${TEST_FAILED}" = false ]; then
    log "Testing external connectivity from ${TEST_POD_NAME} (ping 8.8.8.8)..."
    if ! kubectl exec "${TEST_POD_NAME}" -n default -- ping -c 3 8.8.8.8; then TEST_FAILED=true; fi
  fi

  if [ "${TEST_FAILED}" = true ]; then
    log "Automated connectivity tests FAILED for node ${NODE_NAME}."
    confirm "Automated connectivity tests failed for node ${NODE_NAME}. Proceed anyway? (HIGH RISK)"
  else
    log "Automated connectivity tests PASSED for node ${NODE_NAME}."
  fi

  log "Cleaning up test pod ${TEST_POD_NAME}..."
  kubectl delete pod "${TEST_POD_NAME}" --force --grace-period=0 -n default
done <<< "$ALL_NODES_INFO"

log "All eligible nodes processed. Total migrated: ${MIGRATED_NODES_COUNT}"

# --- Phase 3: Post-Migration and Cleanup ---
log "PHASE 3: Post-Migration and Cleanup..."

log "3.1. Full Cluster Verification..."
CILIUM_AGENT_POD_NAME=$(kubectl get pods -n ${KUBE_SYSTEM_NAMESPACE} -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "${CILIUM_AGENT_POD_NAME}" -n ${KUBE_SYSTEM_NAMESPACE} -- cilium status

log "Verifying all pods are now managed by Cilium."
kubectl get pods -o wide --all-namespaces | grep -v 'cilium'

log "3.2. Apply Cilium Network Policies (CNPs)..."
log "======================================================================"
log "AUTOMATING: Updating ${CILIUM_MANIFEST_FILE} for final configuration (enable-policy: default)"
log "======================================================================"
if [ ! -f "${CILIUM_MANIFEST_FILE}" ]; then log "Error: Cilium manifest file '${CILIUM_MANIFEST_FILE}' not found."; exit 1; fi
sed -i 's/enable-policy: "never"/enable-policy: "default"/' "${CILIUM_MANIFEST_FILE}"; if [ $? -ne 0 ]; then log "Error: Failed to automatically change 'enable-policy'."; confirm "Automatic policy enforcement update failed. Proceed manually? (Type 'yes' to edit and re-run script or fix file)"; fi

log "3.3. Re-applying updated Cilium Manifests..."
kubectl apply -f "${CILIUM_MANIFEST_FILE}" || { log "Error: Failed to apply updated Cilium manifests."; exit 1; }

log "3.4. Restarting Cilium DaemonSet to apply new configuration..."
kubectl -n ${KUBE_SYSTEM_NAMESPACE} rollout restart daemonset cilium
kubectl rollout status ds/cilium -n ${KUBE_SYSTEM_NAMESPACE} --timeout=5m || { log "Cilium DaemonSet did not become ready."; exit 1; }
log "Cilium has been updated with final configuration."

log "======================================================================"
log "FINAL: UNINSTALLING CALICO COMPONENTS"
log "======================================================================"
confirm "Are you ABSOLUTELY SURE you want to uninstall Calico now? Type 'yes' to proceed."

log "3.5. Deleting Calico DaemonSets and Deployments..."
kubectl delete ds/calico-node -n ${KUBE_SYSTEM_NAMESPACE}
kubectl delete deploy/calico-kube-controllers -n ${KUBE_SYSTEM_NAMESPACE}
kubectl delete deploy/calico-typha -n ${KUBE_SYSTEM_NAMESPACE} || true
kubectl delete deploy/calico-typha-autoscaler -n ${KUBE_SYSTEM_NAMESPACE} || true

log "3.6. Deleting Calico ConfigMaps and RBAC resources..."
kubectl delete cm/calico-config -n ${KUBE_SYSTEM_NAMESPACE} || true
kubectl delete cm calico-typha-autoscaler -n ${KUBE_SYSTEM_NAMESPACE} || true
kubectl delete sa/calico-node sa/calico-kube-controllers -n ${KUBE_SYSTEM_NAMESPACE} || true
kubectl delete clusterrolebinding/calico-node clusterrolebinding/calico-kube-controllers || true
kubectl delete clusterrole/calico-node clusterrole/calico-kube-controllers || true

log "3.7. Deleting Calico Custom Resource Definitions (CRDs)..."
kubectl get crd -o name | grep calico | xargs -r kubectl delete || true

log "3.8. Deleting any Calico services (e.g., typha)..."
kubectl delete svc calico-typha -n ${KUBE_SYSTEM_NAMESPACE} || true

log "3.9. Cleaning up residual Calico files on nodes (FULLY AUTOMATED VIA SSH)."
kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, (.status.addresses[] | select(.type=="InternalIP") | .address)] | @tsv' | while IFS=$'\t' read -r NODE_NAME_FINAL NODE_IP_FINAL; do

  if [ -z "${NODE_NAME_FINAL}" ] || [ -z "${NODE_IP_FINAL}" ]; then
    log "WARNING: Skipping malformed node info line in final cleanup loop: '${NODE_INFO_LINE}'. Node name or IP is missing."
    continue
  fi

  log "--- Performing final cleanup on node: ${NODE_NAME_FINAL} (${NODE_IP_FINAL}) via SSH ---"
  
  log "Executing node_migration_task.sh for 'final_cleanup' on node ${NODE_NAME_FINAL}."
  if ! run_on_node_ssh "${NODE_IP_FINAL}" "sudo ${REMOTE_NODE_TASK_PATH} final_cleanup"; then
    log "WARNING: Final node cleanup failed on ${NODE_NAME_FINAL}. Manual intervention required."
    confirm "Manual final node cleanup needed on ${NODE_NAME_FINAL}. Proceed anyway? (HIGH RISK)"
  else
    log "Final node cleanup completed successfully on ${NODE_NAME_FINAL}."
  fi
done
confirm "All node-level cleanup, including iptables, has been attempted. Verify cluster health and finalize migration."

log "======================================================================"
log "MIGRATION COMPLETE: Calico has been uninstalled, and Cilium is now the primary CNI."
log "======================================================================"
log "Final verification is still recommended."

exit 0

