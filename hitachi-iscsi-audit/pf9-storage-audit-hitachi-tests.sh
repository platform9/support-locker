#!/usr/bin/env bash
# pf9-storage-audit-hitachi-tests.sh — test harness for pf9-storage-audit-hitachi.py
#
# Usage: ./pf9-storage-audit-hitachi-tests.sh {setup|s1|s2|s2-inject|s2-cleanup|s3|...}
#
# Run "setup" first — it prints all the IDs you need to fill into the variables below.
# Then run scenarios in order; inject/cleanup functions bookend each scenario.

set -euo pipefail

# ── Credentials & paths ───────────────────────────────────────────────────────
HITACHI_HOST="192.168.176.64"
HITACHI_USER="openstack"
HITACHI_PASS="${HITACHI_PASS:?Set HITACHI_PASS env var before running: export HITACHI_PASS=...}"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa}"
SCRIPT="python3 $(cd "$(dirname "$0")" && pwd)/pf9-storage-audit-hitachi.py"

# ── Compute hosts (short names must match hypervisor hostnames in OpenStack) ──
HOST_00_1="pf9-n01"   # 192.168.177.210  UUID: 23c18f6c-0034-4c8e-999f-ef3ccec7307c
HOST_01="pf9-n02"     # 192.168.177.211  UUID: 3bc01cac-67f5-4809-8987-df887199d731
HOST_1_2="$HOST_00_1"    # host the test VM runs on — sanya-vm-2 is on pf9-n01

HOST_1_2_IP=$(openstack hypervisor list --long -f json 2>/dev/null \
    | python3 -c "
import sys, json
hvs = json.load(sys.stdin)
match = next((h.get('Host IP', h.get('host_ip', '')) for h in hvs
              if h.get('Hypervisor Hostname', '').startswith('${HOST_1_2}')), '')
print(match)
" 2>/dev/null) || HOST_1_2_IP=""

# ── Confirmed IQNs (fill in after running: cat /etc/iscsi/initiatorname.iscsi) ─
IQN_00_1="iqn.2016-04.com.open-iscsi:153148eab825"   # pf9-n01
IQN_01="iqn.2004-10.com.ubuntu:01:52c55542e014"      # pf9-n02
IQN_1_2="$IQN_01"
IQN_1_1="$IQN_00_1"

# ── Test VM & volumes ─────────────────────────────────────────────────────────
TEST_VM="0fdc5091-a216-4462-9222-5cce0d4dcde5"      # sanya-vm-2 on pf9-n01
TEST_VOL1="7718ffcf-276a-453c-a16a-53d05ad4276f"    # sanya-vm-bootvol
TEST_VOL2="b2c392bc-eea4-4de4-8a59-a31c088a7a14"    # sanya-vm-2-bootvol

# ── Fill these in after running: ./pf9-storage-audit-hitachi-tests.sh setup ──
STORAGE_ID="938000745751"
ISCSI_PORT1="CL1-D"
ISCSI_PORT2="CL2-D"
ISCSI_PORTS="${ISCSI_PORT1} ${ISCSI_PORT2}"

HG_1_2_NAME="HBSD-192.168.177.210"  # host group name for HOST_1_2 (pf9-n01)
HG_1_1_NAME="HBSD-192.168.177.211"  # host group name for HOST_00_1 (pf9-n02)
HG_1_2_NUMBER=6                      # host group number on CL1-D (5 on CL2-D)
HG_1_1_NUMBER=8                      # host group number on CL1-D (7 on CL2-D)

LDEV_ID1=105                     # decimal LDEV ID for TEST_VOL1 (sanya-vm-bootvol)
LDEV_ID2=129                     # decimal LDEV ID for TEST_VOL2 (sanya-vm-2-bootvol)

# Existing LU path IDs for vol1 on the correct host group (portId,hg_number,lun).
# Used in cleanup when auto-removal fails.
LUN_ID_VOL1_PORT1="CL1-D,6,0"
LUN_ID_VOL1_PORT2="CL2-D,5,0"

SVM=""  # Not used for Hitachi; kept as placeholder for script parity

# ── Hitachi REST helper ───────────────────────────────────────────────────────
hv() {
    curl -sk -u "${HITACHI_USER}:${HITACHI_PASS}" \
         -H "Accept: application/json" -H "Content-Type: application/json" \
         "https://${HITACHI_HOST}/ConfigurationManager/v1/$1" "${@:2}"
}

# ── Audit script wrapper ──────────────────────────────────────────────────────
audit() {
    $SCRIPT \
        --hitachi-host      "$HITACHI_HOST" \
        --hitachi-user      "$HITACHI_USER" \
        --hitachi-password  "$HITACHI_PASS" \
        --storage-device-id "$STORAGE_ID" \
        --host-iqn          "${HOST_00_1}=${IQN_00_1}" \
        --host-iqn          "${HOST_01}=${IQN_01}" \
        --volume-ldev       "${TEST_VOL1}=${LDEV_ID1}" \
        --volume-ldev       "${TEST_VOL2}=${LDEV_ID2}" \
        --ssh-user root     --ssh-key "$SSH_KEY" \
        "$@"
}

pass() { echo ""; echo "  ✓ PASS: $1"; echo ""; }
fail() { echo ""; echo "  ✗ FAIL: $1"; echo ""; }

check_output() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -qE "$pattern"; then
        pass "$label"
    else
        fail "$label — pattern not found: $pattern"
    fi
}

# ── Hitachi state assertion helpers ──────────────────────────────────────────
# Query the array directly so results reflect actual state, not just script output.

_hv_wait_jobs() {
    # Poll until no async jobs are in Initializing/Running state (up to 30s).
    local deadline=$(($(date +%s) + 30))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local pending
        pending=$(hv "objects/storages/${STORAGE_ID}/jobs" \
            | python3 -c "
import sys, json
jobs = json.load(sys.stdin).get('data', [])
print(sum(1 for j in jobs if j.get('status') in ('Initializing', 'Running')))
" 2>/dev/null || echo "0")
        [ "${pending:-0}" -eq 0 ] && return
        sleep 2
    done
    echo "  [WARN] Timed out waiting for Hitachi jobs"
}

_hv_lun_paths_for_ldev() {
    # Returns JSON array of LU path records for a given LDEV across all iSCSI ports.
    # VSP E1090 requires portId+hostGroupNumber on /luns — we fetch host groups first.
    local ldev_id="$1"
    python3 - <<EOF
import json, base64, ssl, urllib.request
ldev_id = int('${ldev_id}')
host       = '${HITACHI_HOST}'
storage_id = '${STORAGE_ID}'
user       = '${HITACHI_USER}'
pwd        = '${HITACHI_PASS}'
ports      = '${ISCSI_PORTS}'.split()
creds = base64.b64encode(f'{user}:{pwd}'.encode()).decode()
headers = {'Authorization': f'Basic {creds}', 'Accept': 'application/json', 'Content-Type': 'application/json'}
ctx = ssl.create_default_context(); ctx.check_hostname = False
import ssl as _ssl; ctx.verify_mode = _ssl.CERT_NONE

def hv_get(path):
    url = f'https://{host}/ConfigurationManager/v1/objects/storages/{storage_id}/{path}'
    return json.loads(urllib.request.urlopen(urllib.request.Request(url, headers=headers), context=ctx).read())

all_paths = []
for port in ports:
    for hg in hv_get(f'host-groups?portId={port}').get('data', []):
        hg_num = hg.get('hostGroupNumber')
        hg_name = hg.get('hostGroupName', '')
        luns = hv_get(f'luns?portId={port}&hostGroupNumber={hg_num}&count=500')
        for m in luns.get('data', []):
            if m.get('ldevId') == ldev_id:
                m['hostGroupName'] = hg_name  # /luns omits this field; inject from host-groups
                all_paths.append(m)
print(json.dumps(all_paths))
EOF
}

_delete_hg_paths_for_ldev() {
    # Usage: _delete_hg_paths_for_ldev <ldev_id> <hg_name>
    # Fetches all LU paths for ldev_id and DELETEs the ones belonging to hg_name.
    # Passes JSON as sys.argv[1] to avoid the pipe+heredoc stdin conflict.
    local ldev_id="$1" hg_name="$2"
    local paths_json
    paths_json=$(_hv_lun_paths_for_ldev "$ldev_id")
    python3 - "$paths_json" "$hg_name" <<EOF
import sys, json, base64, ssl, urllib.request, urllib.parse
paths   = json.loads(sys.argv[1])
hg_name = sys.argv[2]
host       = "${HITACHI_HOST}"
storage_id = "${STORAGE_ID}"
user       = "${HITACHI_USER}"
pwd        = "${HITACHI_PASS}"
creds = base64.b64encode(f'{user}:{pwd}'.encode()).decode()
headers = {'Authorization': f'Basic {creds}', 'Accept': 'application/json'}
ctx = ssl.create_default_context(); ctx.check_hostname = False
import ssl as _ssl; ctx.verify_mode = _ssl.CERT_NONE
for m in paths:
    if m.get('hostGroupName') == hg_name:
        lun_id = m.get('lunId', '')
        url = (f'https://{host}/ConfigurationManager/v1/'
               f'objects/storages/{storage_id}/luns/{urllib.parse.quote(lun_id, safe="")}')
        req = urllib.request.Request(url, method='DELETE', headers=headers)
        urllib.request.urlopen(req, context=ctx)
        print(f'Deleted {lun_id}')
EOF
}

hv_count() {
    # Usage: hv_count <ldev_id> → integer path count across all ports
    _hv_lun_paths_for_ldev "$1" \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0
}

hv_hgroups() {
    # Usage: hv_hgroups <ldev_id> → space-separated unique host group names
    _hv_lun_paths_for_ldev "$1" \
        | python3 -c "import sys,json; print(' '.join(sorted(set(m.get('hostGroupName','') for m in json.load(sys.stdin)))))" 2>/dev/null || echo ""
}

assert_hv_count() {
    local label="$1" ldev_id="$2" expected="$3"
    local actual; actual=$(hv_count "$ldev_id")
    if [ "$actual" -eq "$expected" ]; then
        pass "Hitachi: $label ($actual path(s))"
    else
        fail "Hitachi: $label — expected $expected path(s), got $actual. Groups: $(hv_hgroups "$ldev_id")"
    fi
}

assert_hv_hgroup() {
    local label="$1" ldev_id="$2" expected_hg="$3"
    local mapped; mapped=$(hv_hgroups "$ldev_id")
    if echo "$mapped" | grep -qF "$expected_hg"; then
        pass "Hitachi: $label (found '$expected_hg')"
    else
        fail "Hitachi: $label — expected '$expected_hg' in: '$mapped'"
    fi
}

assert_hv_not_hgroup() {
    local label="$1" ldev_id="$2" absent_hg="$3"
    local mapped; mapped=$(hv_hgroups "$ldev_id")
    if echo "$mapped" | grep -qF "$absent_hg"; then
        fail "Hitachi: $label — '$absent_hg' still present in: '$mapped'"
    else
        pass "Hitachi: $label ('$absent_hg' not present)"
    fi
}

# ── setup: discover and print all IDs needed above ───────────────────────────
setup() {
    echo "=== Storage devices ==="
    hv "objects/storages" | python3 -m json.tool

    echo ""
    echo "=== iSCSI ports ==="
    hv "objects/storages/${STORAGE_ID}/ports?portType=ISCSI" | python3 -m json.tool

    echo ""
    echo "=== All host groups (iSCSI ports only) ==="
    for port in $ISCSI_PORTS; do
        echo "--- Port ${port} ---"
        hv "objects/storages/${STORAGE_ID}/host-groups?portId=${port}" | python3 -m json.tool
    done

    echo ""
    echo "=== LU paths for vol1 (LDEV ${LDEV_ID1}) ==="
    _hv_lun_paths_for_ldev "${LDEV_ID1}" | python3 -m json.tool

    echo ""
    echo "=== LU paths for vol2 (LDEV ${LDEV_ID2}) ==="
    _hv_lun_paths_for_ldev "${LDEV_ID2}" | python3 -m json.tool

    echo ""
    echo "=== provider_location for TEST_VOL1 (LDEV ID) ==="
    openstack volume show "${TEST_VOL1}" -f json 2>/dev/null \
        | python3 -c "
import sys, json
data = sys.stdin.read().strip()
if not data:
    print('provider_location: NOT VISIBLE — openstack CLI not available or RC not sourced')
else:
    v = json.loads(data)
    print('provider_location:', v.get('provider_location', 'NOT VISIBLE — need admin scope'))
" || true

    echo ""
    echo "Fill in at the top of this script:"
    echo "  STORAGE_ID      — from 'Storage devices' above"
    echo "  ISCSI_PORT1/2   — port IDs from 'iSCSI ports' above"
    echo "  HG_1_2_NAME     — hostGroupName for ${HOST_1_2}"
    echo "  HG_1_1_NAME     — hostGroupName for ${HOST_00_1}"
    echo "  HG_1_2_NUMBER   — hostGroupNumber for HG_1_2"
    echo "  HG_1_1_NUMBER   — hostGroupNumber for HG_1_1"
    echo "  LDEV_ID1/2      — decimal ldevId from provider_location or LU paths above"
    echo "  LUN_ID_VOL1_*   — lunId values from LU paths for vol1"

    echo ""
    echo "=== Validating variables against Hitachi ==="
    local ok=1

    local c1; c1=$(hv_count "${LDEV_ID1}")
    local g1; g1=$(hv_hgroups "${LDEV_ID1}")
    local expected_paths; expected_paths=$(echo "$ISCSI_PORTS" | wc -w)  # 1 LU path per iSCSI port
    if echo "$g1" | grep -qF "$HG_1_2_NAME"; then
        echo "  ✓ LDEV1: mapped to ${HG_1_2_NAME}"
    else
        echo "  ✗ LDEV1: ${HG_1_2_NAME} not found in: ${g1}"
        ok=0
    fi

    local c2; c2=$(hv_count "${LDEV_ID2}")
    local g2; g2=$(hv_hgroups "${LDEV_ID2}")
    if echo "$g2" | grep -qF "$HG_1_2_NAME"; then
        echo "  ✓ LDEV2: mapped to ${HG_1_2_NAME}"
    else
        echo "  ✗ LDEV2: ${HG_1_2_NAME} not found in: ${g2}"
        ok=0
    fi

    echo ""
    if [ "$ok" -eq 1 ]; then
        echo "  ✓✓ ALL GOOD — variables match Hitachi state. Ready to run tests."
    else
        echo "  ✗✗ VARIABLES NEED UPDATING — fix the mismatches above before running scenarios."
    fi
}

# ── Scenario 1: Clean baseline ────────────────────────────────────────────────
s1() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 1 — Clean baseline"
    echo "════════════════════════════════════════════"

    # Confirm pre-condition: exactly N paths (one per port), all to correct host group
    assert_hv_hgroup "LDEV1 mapped to correct host group" "${LDEV_ID1}" "${HG_1_2_NAME}"
    assert_hv_not_hgroup "LDEV1 not mapped to wrong host group" "${LDEV_ID1}" "${HG_1_1_NAME}"

    out=$(audit 2>&1) || true
    echo "$out"
    check_output "no issues detected" "No host group mapping issues detected" "$out"
}

# ── Scenario 2: DUAL HOST GROUP ───────────────────────────────────────────────
s2-inject() {
    echo "=== S2: inject DUAL HOST GROUP (adding HG_1_1 paths for LDEV1) ==="
    for port in $ISCSI_PORTS; do
        hg_num=$( hv "objects/storages/${STORAGE_ID}/host-groups?portId=${port}" \
            | python3 -c "
import sys, json
d = json.load(sys.stdin)
match = next((r['hostGroupNumber'] for r in d.get('data', [])
              if r.get('hostGroupName') == '${HG_1_1_NAME}'), None)
print(match if match is not None else '${HG_1_1_NUMBER}')
" 2>/dev/null || echo "${HG_1_1_NUMBER}" )
        hv "objects/storages/${STORAGE_ID}/luns" -X POST \
            -d "{\"portId\": \"${port}\", \"hostGroupNumber\": ${hg_num}, \"ldevId\": ${LDEV_ID1}}" \
            | python3 -m json.tool
    done
    echo ""
    assert_hv_hgroup "stale HG_1_1 now present" "${LDEV_ID1}" "${HG_1_1_NAME}"
    assert_hv_hgroup "correct HG_1_2 still present" "${LDEV_ID1}" "${HG_1_2_NAME}"
}

s2-cleanup() {
    echo "=== S2: cleanup — removing injected HG_1_1 paths for LDEV1 ==="
    _delete_hg_paths_for_ldev "${LDEV_ID1}" "${HG_1_1_NAME}"
    echo "Done."
    assert_hv_not_hgroup "HG_1_1 paths removed" "${LDEV_ID1}" "${HG_1_1_NAME}"
    assert_hv_hgroup "HG_1_2 paths intact" "${LDEV_ID1}" "${HG_1_2_NAME}"
}

s2() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 2 — DUAL HOST GROUP"
    echo "════════════════════════════════════════════"

    echo "--- Detect ---"
    out=$(audit --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "dual mapping detected" "DUAL HOST GROUP" "$out"

    echo "--- Dry run ---"
    out=$(audit --server "$TEST_VM" --dry-run 2>&1) || true
    echo "$out"
    check_output "dry-run shows remove step" "DRY-RUN.*Hitachi: remove LU path" "$out"
    assert_hv_hgroup "HG_1_1 still present after dry-run" "${LDEV_ID1}" "${HG_1_1_NAME}"

    echo "--- Remediate ---"
    out=$(audit --server "$TEST_VM" --remediate 2>&1) || true
    echo "$out"
    check_output "remediate removes stale paths" "Hitachi: remove LU path.*${HG_1_1_NAME}" "$out"
    assert_hv_not_hgroup "HG_1_1 removed after remediate" "${LDEV_ID1}" "${HG_1_1_NAME}"
    assert_hv_hgroup "HG_1_2 intact after remediate" "${LDEV_ID1}" "${HG_1_2_NAME}"

    echo "--- Verify clean ---"
    out=$(audit --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "clean after remediate" "No host group mapping issues detected" "$out"
}

# ── Scenario 3: SOURCE MISSING ────────────────────────────────────────────────
# Inject: add HG_1_1 paths then remove HG_1_2 paths (source host loses access)
s3-inject() {
    echo "=== S3: inject — add HG_1_1 paths, remove HG_1_2 paths for LDEV1 ==="
    for port in $ISCSI_PORTS; do
        hv "objects/storages/${STORAGE_ID}/luns" -X POST \
            -d "{\"portId\": \"${port}\", \"hostGroupNumber\": ${HG_1_1_NUMBER}, \"ldevId\": ${LDEV_ID1}}" \
            | python3 -m json.tool
    done
    _hv_wait_jobs  # wait for async LU path create jobs before deleting source paths
    # Remove the correct (source) paths
    _delete_hg_paths_for_ldev "${LDEV_ID1}" "${HG_1_2_NAME}"
    echo "Done — only HG_1_1 (wrong) paths remain."
    assert_hv_hgroup     "wrong HG_1_1 present"  "${LDEV_ID1}" "${HG_1_1_NAME}"
    assert_hv_not_hgroup "correct HG_1_2 gone"   "${LDEV_ID1}" "${HG_1_2_NAME}"
}

s3-cleanup() {
    echo "=== S3: cleanup — restore HG_1_2 paths, remove HG_1_1 paths ==="
    for port in $ISCSI_PORTS; do
        hv "objects/storages/${STORAGE_ID}/luns" -X POST \
            -d "{\"portId\": \"${port}\", \"hostGroupNumber\": ${HG_1_2_NUMBER}, \"ldevId\": ${LDEV_ID1}}" \
            | python3 -m json.tool
    done
    _delete_hg_paths_for_ldev "${LDEV_ID1}" "${HG_1_1_NAME}"
    echo "Done."
    assert_hv_hgroup     "HG_1_2 restored" "${LDEV_ID1}" "${HG_1_2_NAME}"
    assert_hv_not_hgroup "HG_1_1 removed"  "${LDEV_ID1}" "${HG_1_1_NAME}"
}

s3() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 3 — SOURCE MISSING"
    echo "════════════════════════════════════════════"

    echo "--- Detect ---"
    out=$(audit --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "source missing detected" "SOURCE MISSING" "$out"

    echo "--- Remediate ---"
    out=$(audit --server "$TEST_VM" --remediate 2>&1) || true
    echo "$out"
    check_output "re-added source paths" "Hitachi: add LU path.*${HG_1_2_NAME}" "$out"
    assert_hv_hgroup     "HG_1_2 restored" "${LDEV_ID1}" "${HG_1_2_NAME}"
    assert_hv_not_hgroup "HG_1_1 removed"  "${LDEV_ID1}" "${HG_1_1_NAME}"

    echo "--- Verify clean ---"
    out=$(audit --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "clean after remediate" "No host group mapping issues detected" "$out"
}

# ── Scenario 4: Ubuntu IQN warning (no --host-iqn) ───────────────────────────
s4() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 4 — Ubuntu IQN warning (no --host-iqn)"
    echo "════════════════════════════════════════════"
    out=$($SCRIPT \
        --hitachi-host      "$HITACHI_HOST" \
        --hitachi-user      "$HITACHI_USER" \
        --hitachi-password  "$HITACHI_PASS" \
        --storage-device-id "$STORAGE_ID" \
        --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "IQN warning shown" "host group check skipped|pass --host-iqn" "$out"
}

# ── Scenario 5: Single VM mode ────────────────────────────────────────────────
s5() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 5 — Single VM mode"
    echo "════════════════════════════════════════════"
    out=$(audit --server "$TEST_VM" 2>&1) || true
    echo "$out"
    local test_vm_name
    test_vm_name=$(openstack server show "$TEST_VM" -f value -c name 2>/dev/null || echo "test-vm")
    other_vms=$(openstack server list --all -f json 2>/dev/null \
        | python3 -c "import sys,json; [print(s['Name']) for s in json.load(sys.stdin) if s.get('ID') != '${TEST_VM}']" 2>/dev/null || true)
    leaked=0
    while IFS= read -r vmname; do
        [ -z "$vmname" ] && continue
        if echo "$out" | grep -qE "(^|[[:space:]])${vmname}([[:space:](]|$)"; then leaked=1; break; fi
    done <<< "$other_vms"
    if [ "$leaked" -eq 1 ]; then
        fail "other VMs leaked into single-VM output"
    else
        pass "output scoped to $test_vm_name only"
    fi
}

# ── Scenario 6: Multiple volumes, partial DUAL HOST GROUP ────────────────────
s6-inject() {
    echo "=== S6: inject DUAL HOST GROUP on LDEV1 only ==="
    for port in $ISCSI_PORTS; do
        hv "objects/storages/${STORAGE_ID}/luns" -X POST \
            -d "{\"portId\": \"${port}\", \"hostGroupNumber\": ${HG_1_1_NUMBER}, \"ldevId\": ${LDEV_ID1}}" \
            | python3 -m json.tool
    done
    assert_hv_hgroup     "LDEV1 has stale HG_1_1 after inject"   "${LDEV_ID1}" "${HG_1_1_NAME}"
    assert_hv_not_hgroup "LDEV2 unchanged (no HG_1_1)"            "${LDEV_ID2}" "${HG_1_1_NAME}"
}

s6-cleanup() {
    echo "=== S6: cleanup ==="
    _delete_hg_paths_for_ldev "${LDEV_ID1}" "${HG_1_1_NAME}"
    echo "Done."
    assert_hv_not_hgroup "LDEV1 HG_1_1 removed" "${LDEV_ID1}" "${HG_1_1_NAME}"
}

s6() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 6 — Multiple volumes, partial issue"
    echo "════════════════════════════════════════════"
    out=$(audit --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "dual on LDEV1 detected" "DUAL HOST GROUP" "$out"
    if echo "$out" | grep -A5 "${TEST_VOL2}" | grep -q "DUAL HOST GROUP\|SOURCE MISSING"; then
        fail "LDEV2 incorrectly flagged"
    else
        pass "LDEV2 is clean"
    fi
    echo "--- Cleanup ---"
    s6-cleanup
}

# ── Scenario 7: SSH IQN auto-fetch (no --host-iqn) ───────────────────────────
s7() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 7 — SSH IQN auto-fetch"
    echo "════════════════════════════════════════════"
    out=$($SCRIPT \
        --hitachi-host      "$HITACHI_HOST" \
        --hitachi-user      "$HITACHI_USER" \
        --hitachi-password  "$HITACHI_PASS" \
        --storage-device-id "$STORAGE_ID" \
        --ssh-user root --ssh-key "$SSH_KEY" \
        --server "$TEST_VM" 2>&1) || true
    echo "$out"
    check_output "IQNs fetched via SSH" "Fetching IQNs via SSH" "$out"
    check_output "host health section printed" "HOST HEALTH" "$out"
    if echo "$out" | grep -q "host group check skipped"; then
        fail "IQN warning still present — SSH fetch failed"
    fi
}

# ── Scenario 8: Orphaned mpath cleanup ───────────────────────────────────────
# Inject: remove all HG_1_2 LU paths for LDEV1 so the compute host loses all
# paths to that device. The VM continues running via vol2.

_ssh_host() {
    local target="${HOST_1_2_IP:-${HOST_1_2}}"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@${target}" "$@"
}

s8-inject() {
    echo "=== S8: inject — remove HG_1_2 LU paths for LDEV1 to orphan mpath on ${HOST_1_2} ==="
    _hv_wait_jobs  # wait for async LU path create jobs before removing source paths
    _delete_hg_paths_for_ldev "${LDEV_ID1}" "${HG_1_2_NAME}"
    echo "Paths removed. Polling up to 60s for paths to go failed on ${HOST_1_2}..."
    local deadline=$(($(date +%s) + 60))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        failed=$(_ssh_host "multipath -ll 2>/dev/null | grep -cE 'failed|faulty'; true" 2>/dev/null) || failed=0
        if [ "${failed:-0}" -gt 0 ]; then
            echo "Paths failed (${failed} line(s) found)."
            break
        fi
        sleep 5
    done
    assert_hv_count "LDEV1 has 0 maps after inject" "${LDEV_ID1}" 0
}

s8-cleanup() {
    echo "=== S8: cleanup — restore HG_1_2 LU paths and rescan ==="
    for port in $ISCSI_PORTS; do
        hv "objects/storages/${STORAGE_ID}/luns" -X POST \
            -d "{\"portId\": \"${port}\", \"hostGroupNumber\": ${HG_1_2_NUMBER}, \"ldevId\": ${LDEV_ID1}}" \
            | python3 -m json.tool
    done
    _ssh_host "iscsiadm -m session -R 2>/dev/null; multipath -r 2>/dev/null" || true
    assert_hv_hgroup "LDEV1 map restored" "${LDEV_ID1}" "${HG_1_2_NAME}"
    echo "Done."
}

s8() {
    echo "════════════════════════════════════════════"
    echo "SCENARIO 8 — Orphaned mpath cleanup"
    echo "════════════════════════════════════════════"

    echo "--- Detect (no flush) ---"
    out=$(audit --server "$TEST_VM" --clean-mpath 2>&1) || true
    echo "$out"
    check_output "orphaned mpath device reported" "orphaned mpath device" "$out"
    still_failing=$(_ssh_host "multipath -ll 2>/dev/null | grep -cE 'failed|faulty'; true" 2>/dev/null) || still_failing=0
    if [ "${still_failing:-0}" -gt 0 ]; then
        pass "detect-only left device in place"
    else
        fail "detect-only appears to have flushed the device (unexpected)"
    fi

    echo "--- Dry run ---"
    out=$(audit --server "$TEST_VM" --clean-mpath --dry-run 2>&1) || true
    echo "$out"
    check_output "dry-run shows flush command" "DRY-RUN.*multipath -f" "$out"
    still_failing=$(_ssh_host "multipath -ll 2>/dev/null | grep -cE 'failed|faulty'; true" 2>/dev/null) || still_failing=0
    if [ "${still_failing:-0}" -gt 0 ]; then
        pass "dry-run left device in place"
    else
        fail "dry-run appears to have flushed the device (unexpected)"
    fi

    echo "--- Remediate (flush) ---"
    out=$(audit --server "$TEST_VM" --clean-mpath --remediate 2>&1) || true
    echo "$out"
    check_output "flush executed" "multipath -f" "$out"
    remaining=$(_ssh_host "multipath -ll 2>/dev/null | grep -cE 'failed|faulty'; true" 2>/dev/null) || remaining=0
    if echo "$out" | grep -q "Cannot flush\|map in use"; then
        pass "flush correctly reported device in use (stop VM first to flush)"
    elif [ "${remaining:-0}" -eq 0 ]; then
        pass "orphaned mpath device flushed"
    else
        fail "orphaned mpath device still present after flush (${remaining} failed path line(s))"
    fi

    echo "--- Cleanup ---"
    s8-cleanup

    echo "--- Verify clean ---"
    out=$(audit --server "$TEST_VM" --clean-mpath 2>&1) || true
    echo "$out"
    check_output "no orphans after restore" "No orphaned mpath devices" "$out"
}

# ── All VMs scan: false positive check ───────────────────────────────────────
all-vms() {
    echo "════════════════════════════════════════════"
    echo "ALL-VMS — Full cluster scan (false positive check)"
    echo "════════════════════════════════════════════"
    echo "Running audit against all VMs (no --server filter)..."
    out=$(audit 2>&1) || true
    echo "$out"
    if echo "$out" | grep -q "ISSUES FOUND"; then
        echo ""
        echo "  ↑ Issues found — review above to determine if real or false positive."
        echo ""
    else
        pass "no false positives detected across full cluster"
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:-help}" in
    setup)       setup ;;
    s1)          s1 ;;
    s2)          s2 ;;
    s2-inject)   s2-inject ;;
    s2-cleanup)  s2-cleanup ;;
    s3)          s3 ;;
    s3-inject)   s3-inject ;;
    s3-cleanup)  s3-cleanup ;;
    s4)          s4 ;;
    s5)          s5 ;;
    s6)          s6 ;;
    s6-inject)   s6-inject ;;
    s6-cleanup)  s6-cleanup ;;
    s7)          s7 ;;
    s8)          s8 ;;
    s8-inject)   s8-inject ;;
    s8-cleanup)  s8-cleanup ;;
    all-vms)     all-vms ;;
    *)
        echo "Usage: $0 {setup|s1|s2|s2-inject|s2-cleanup|s3|s3-inject|s3-cleanup|s4|s5|s6|s6-inject|s6-cleanup|s7|s8|s8-inject|s8-cleanup|all-vms}"
        echo ""
        echo "Order:"
        echo "  1. Fill in credentials/hosts at top, then run 'setup' to discover IDs"
        echo "  2. Fill in STORAGE_ID, ISCSI_PORT1/2, HG names/numbers, LDEV_ID1/2"
        echo "  3. s1 — clean baseline"
        echo "  4. s2-inject → s2 → (s2-cleanup if remediate fails)"
        echo "  5. s3-inject → s3 → (s3-cleanup if remediate fails)"
        echo "  6. s4, s5, s7 — no injection needed"
        echo "  7. s6-inject → s6 (s6 cleans up itself)"
        echo "  8. s8-inject → s8 → (s8-cleanup if remediate fails)"
        echo "  9. all-vms — full cluster scan to check for false positives"
        ;;
esac
