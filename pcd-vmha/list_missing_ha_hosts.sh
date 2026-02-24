#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--help]"
    echo ""
    echo "Interactively queries a DU to list all hosts missing the 'pf9-ha-slave' role"
    echo "across HA-enabled clusters. Results are written to a timestamped file:"
    echo "  missing_hosts_<YYYYMMDD_HHMMSS>.txt"
    echo ""
    echo "Options:"
    echo "  --help    Show this help message and exit"
    echo ""
    echo "The generated file can be passed to apply_ha_role.sh to apply the role."
    exit 0
}

# Handle --help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
fi

# Colors for stderr output (verbose/debug logs go to stderr so stdout stays pipeable)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

log_info()  { echo -e "${GREEN}${LOG_PREFIX} [INFO]${NC}  $*" >&2; }
log_warn()  { echo -e "${YELLOW}${LOG_PREFIX} [WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}${LOG_PREFIX} [ERROR]${NC} $*" >&2; }
log_debug() { echo -e "${CYAN}${LOG_PREFIX} [DEBUG]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}${LOG_PREFIX} [STEP]${NC}  $*" >&2; }

update_log_prefix() { LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"; }

# Wrapper around curl that logs the request and checks for errors
do_curl() {
    local method="$1"
    local url="$2"

    update_log_prefix
    log_debug "curl -s -X ${method} '${url}' -H 'X-Auth-Token: <REDACTED>' -H 'Content-Type: application/json'"

    local http_response
    http_response=$(curl -s -w "\n%{http_code}" -X "${method}" "${url}" \
        -H "X-Auth-Token: ${TOKEN}" \
        -H "Content-Type: application/json")

    local http_code
    http_code=$(echo "$http_response" | tail -n1)
    local response_body
    response_body=$(echo "$http_response" | sed '$d')

    log_debug "HTTP response code: ${http_code}"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_error "HTTP ${method} ${url} failed with status ${http_code}"
        log_error "Response body: ${response_body}"
        return 1
    fi

    echo "$response_body"
}

# ─── Gather inputs ──────────────────────────────────────────────────────────

echo -e "${BLUE}============================================${NC}" >&2
echo -e "${BLUE}  List Hosts Missing pf9-ha-slave Role${NC}" >&2
echo -e "${BLUE}============================================${NC}" >&2
echo "" >&2

read -rp "$(echo -e "${CYAN}Enter DU FQDN (e.g. my-du.platform9.io): ${NC}")" DU_FQDN
if [[ -z "$DU_FQDN" ]]; then
    log_error "DU FQDN cannot be empty. Exiting."
    exit 1
fi
log_info "DU FQDN set to: ${DU_FQDN}"

read -rsp "$(echo -e "${CYAN}Enter Auth Token: ${NC}")" TOKEN
echo "" >&2
if [[ -z "$TOKEN" ]]; then
    log_error "Token cannot be empty. Exiting."
    exit 1
fi
log_info "Token received (hidden for security)."

BASE_URL="https://${DU_FQDN}"
log_info "Base URL: ${BASE_URL}"

# ─── Fetch clusters ─────────────────────────────────────────────────────────

log_step "Fetching clusters from ${BASE_URL}/resmgr/v2/clusters ..."
CLUSTERS_JSON=$(do_curl GET "${BASE_URL}/resmgr/v2/clusters")

CLUSTER_COUNT=$(echo "$CLUSTERS_JSON" | jq 'length')
log_info "Found ${CLUSTER_COUNT} cluster(s)."

if [[ "$CLUSTER_COUNT" -eq 0 ]]; then
    log_warn "No clusters found. Nothing to do. Exiting."
    exit 0
fi

# ─── Fetch all hosts once ───────────────────────────────────────────────────

log_step "Fetching all hosts from ${BASE_URL}/resmgr/v1/hosts ..."
ALL_HOSTS_JSON=$(do_curl GET "${BASE_URL}/resmgr/v1/hosts")
ALL_HOSTS_COUNT=$(echo "$ALL_HOSTS_JSON" | jq 'length')
log_info "Found ${ALL_HOSTS_COUNT} host(s) total."

# ─── Prepare output file ─────────────────────────────────────────────────────

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTPUT_FILE="missing_hosts_${TIMESTAMP}.txt"
log_info "Output file: ${OUTPUT_FILE}"

{
    echo "# host_id | hostname | cluster_name | responding | pf9-ostackhost-neutron_status | current_roles"
    echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S') | DU: ${DU_FQDN}"
    echo "#"
} > "${OUTPUT_FILE}"

TOTAL_MISSING=0

# ─── Process each cluster ───────────────────────────────────────────────────

for (( i=0; i<CLUSTER_COUNT; i++ )); do
    CLUSTER=$(echo "$CLUSTERS_JSON" | jq ".[$i]")
    CLUSTER_NAME=$(echo "$CLUSTER" | jq -r '.name // "unnamed"')
    HA_ENABLED=$(echo "$CLUSTER" | jq -r '(.vmHighAvailability.enabled) // false')
    HOSTLIST=$(echo "$CLUSTER" | jq -r '(.hostlist // [])[]')
    HOST_COUNT=$(echo "$CLUSTER" | jq '(.hostlist // []) | length')

    log_step "Processing cluster: ${CLUSTER_NAME} (${HOST_COUNT} host(s))"
    log_debug "vmHighAvailability.enabled = ${HA_ENABLED}"
    log_debug "Hostlist: $(echo "$CLUSTER" | jq -c '.hostlist // []')"

    # Check if HA is enabled
    if [[ "$HA_ENABLED" != "true" ]]; then
        log_warn "vmHighAvailability is NOT enabled for cluster '${CLUSTER_NAME}'. Skipping."
        continue
    fi
    log_info "vmHighAvailability is enabled for cluster '${CLUSTER_NAME}'."

    if [[ -z "$HOSTLIST" ]]; then
        log_warn "Cluster '${CLUSTER_NAME}' has an empty hostlist. Skipping."
        continue
    fi

    # Filter hosts belonging to this cluster
    log_debug "Filtering hosts for cluster '${CLUSTER_NAME}' ..."
    CLUSTER_HOSTS_JSON="[]"
    for HOST_ID in $HOSTLIST; do
        HOST_ENTRY=$(echo "$ALL_HOSTS_JSON" | jq --arg hid "$HOST_ID" '[.[] | select(.id == $hid)]')
        MATCH_COUNT=$(echo "$HOST_ENTRY" | jq 'length')
        if [[ "$MATCH_COUNT" -eq 0 ]]; then
            log_warn "Host ID ${HOST_ID} from cluster hostlist not found in /resmgr/v2/hosts response!"
        else
            CLUSTER_HOSTS_JSON=$(echo "$CLUSTER_HOSTS_JSON" "$HOST_ENTRY" | jq -s 'add')
        fi
    done

    FILTERED_COUNT=$(echo "$CLUSTER_HOSTS_JSON" | jq 'length')
    log_info "Matched ${FILTERED_COUNT} host(s) for cluster '${CLUSTER_NAME}'."

    if [[ "$FILTERED_COUNT" -eq 0 ]]; then
        log_warn "No matching hosts found for cluster '${CLUSTER_NAME}'. Skipping."
        continue
    fi

    # Print all hosts in this cluster for debugging
    log_info "Hosts in cluster '${CLUSTER_NAME}':"
    echo "$CLUSTER_HOSTS_JSON" | jq -r '.[] | "  - \(.id // "unknown")  hostname=\(.info.hostname // "unknown")  roles=\((.roles // []) | join(","))  responding=\(.info.responding // false)"' >&2

    # Find hosts missing pf9-ha-slave role
    MISSING_HA_HOSTS=$(echo "$CLUSTER_HOSTS_JSON" | jq '[.[] | select((.roles // []) | index("pf9-ha-slave") | not)]')
    MISSING_COUNT=$(echo "$MISSING_HA_HOSTS" | jq 'length')

    if [[ "$MISSING_COUNT" -eq 0 ]]; then
        log_info "All hosts in cluster '${CLUSTER_NAME}' already have the 'pf9-ha-slave' role."
        continue
    fi

    log_warn "${MISSING_COUNT} host(s) in cluster '${CLUSTER_NAME}' are MISSING the 'pf9-ha-slave' role."

    # Output each missing host to stdout (pipeable format)
    for (( j=0; j<MISSING_COUNT; j++ )); do
        HOST=$(echo "$MISSING_HA_HOSTS" | jq ".[$j]")
        HOST_ID=$(echo "$HOST" | jq -r '.id // "unknown"')
        HOSTNAME=$(echo "$HOST" | jq -r '.info.hostname // "unknown"')
        RESPONDING=$(echo "$HOST" | jq -r '(.info.responding) // false')
        HV_STATUS=$(echo "$HOST" | jq -r '(.roles_status_details."pf9-ostackhost-neutron") // "missing"')
        ROLES=$(echo "$HOST" | jq -r '(.roles // []) | join(",")')

        log_debug "  Host ${HOST_ID} (${HOSTNAME}): responding=${RESPONDING}, pf9-ostackhost-neutron=${HV_STATUS}, roles=${ROLES}"

        # Write to output file
        echo "${HOST_ID} | ${HOSTNAME} | ${CLUSTER_NAME} | ${RESPONDING} | ${HV_STATUS} | ${ROLES}" >> "${OUTPUT_FILE}"
    done

    TOTAL_MISSING=$((TOTAL_MISSING + MISSING_COUNT))
done

echo "" >&2
log_info "Total hosts missing 'pf9-ha-slave' role: ${TOTAL_MISSING}"

if [[ "$TOTAL_MISSING" -eq 0 ]]; then
    log_info "Nothing to do. All HA-enabled cluster hosts already have the role."
fi

log_info "Results written to: ${OUTPUT_FILE}"
echo "" >&2
echo -e "${GREEN}============================================${NC}" >&2
echo -e "${GREEN}  Listing complete.${NC}" >&2
echo -e "${GREEN}  Output: ${OUTPUT_FILE}${NC}" >&2
echo -e "${GREEN}============================================${NC}" >&2
