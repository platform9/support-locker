#!/usr/bin/env python3
"""
pf9-storage-audit.py — Cluster-wide iSCSI live-migration BDM/igroup remediation.

Cross-references Nova, Cinder, and NetApp ONTAP to find and fix stale
attachment state left behind by failed live migrations.

Detects two failure modes:
  DUAL IGROUP    — LUN is mapped to both source and destination igroup simultaneously.
                   Root cause: pre_live_migration ran on destination but migration
                   failed and BDM rollback was skipped (libvirt monitor timeout).
                   This is the most common production failure.
  SOURCE MISSING — LUN is mapped only to the destination igroup; source igroup
                   mapping was removed (e.g. failed terminate_connection call).

Usage:
  # Detect only
  python3 pf9-storage-audit.py --netapp-host <ip> --netapp-user admin

  # With SSH for IQN resolution and host health
  python3 pf9-storage-audit.py --netapp-host <ip> --netapp-user admin \\
    --ssh-user root --ssh-key /tmp/key

  # Supply known IQNs manually (alternative to SSH)
  python3 pf9-storage-audit.py ... --host-iqn 970-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9

  # Preview remediation
  python3 pf9-storage-audit.py ... --dry-run

  # Apply igroup fixes
  python3 pf9-storage-audit.py ... --remediate
"""

import argparse
import base64
import getpass
import json
import re
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


# ── OpenStack helpers ──────────────────────────────────────────────────────

def os_cmd(*args, allow_fail=False):
    cmd = ["openstack", *args, "-f", "json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        print("[ERROR] 'openstack' CLI not found — install python-openstackclient and source your RC file.",
              file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(f"[ERROR] openstack {' '.join(args)} timed out after 120s.", file=sys.stderr)
        if allow_fail:
            return None
        sys.exit(1)
    if result.returncode != 0:
        if allow_fail:
            return None
        print(f"[ERROR] openstack {' '.join(args)}\n{result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return []


def get_all_servers():
    servers = os_cmd("server", "list", "--all", "--long")
    return [
        {
            "id":     s.get("ID", ""),
            "name":   s.get("Name", ""),
            "host":   s.get("Host", ""),
            "status": s.get("Status", ""),
        }
        for s in servers
    ]


def get_server(server_id):
    s = os_cmd("server", "show", server_id)
    if not s or not isinstance(s, dict):
        print(f"[ERROR] Could not retrieve server '{server_id}' — check the UUID/name and RC file.",
              file=sys.stderr)
        sys.exit(1)
    host = (s.get("OS-EXT-SRV-ATTR:hypervisor_hostname")
            or s.get("OS-EXT-SRV-ATTR:host", ""))
    return {
        "id":     s.get("id", ""),
        "name":   s.get("name", ""),
        "host":   host,
        "status": s.get("status", ""),
    }


def get_server_volumes(server_id):
    vols = os_cmd("server", "volume", "list", server_id, allow_fail=True) or []
    seen = set()
    result = []
    for v in vols:
        vid = v.get("Volume ID", v.get("id", "")) if v else ""
        if vid and vid not in seen:
            seen.add(vid)
            result.append(vid)
    return result


def get_volume_info(volume_id):
    return os_cmd("volume", "show", volume_id, allow_fail=True)


def get_hypervisor_name_map():
    """Resolve Cinder host UUIDs → hostnames.

    In PF9, Cinder stores the nova-compute service UUID in attachment.host_name.
    That UUID is regenerated on every service restart, so old attachments can't be
    resolved after a reboot. We try the hypervisor list UUIDs as a best-effort;
    callers must treat unresolved UUIDs as 'unknown' rather than 'stale'.
    """
    result = {}
    hypervisors = os_cmd("hypervisor", "list", "--long", allow_fail=True) or []
    for h in hypervisors:
        uuid = str(h.get("ID", h.get("id", "")))
        name = h.get("Hypervisor Hostname", h.get("hypervisor_hostname", ""))
        if uuid and name:
            result[uuid] = name
    return result


def get_hypervisor_ip_map():
    result = {}
    hypervisors = os_cmd("hypervisor", "list", "--long", allow_fail=True) or []
    for h in hypervisors:
        name = h.get("Hypervisor Hostname", h.get("hypervisor_hostname", ""))
        ip   = h.get("Host IP", h.get("host_ip", ""))
        if name and ip:
            result[name] = ip
    return result


# ── NetApp helpers ─────────────────────────────────────────────────────────

def _netapp_request(host, user, password, path, params=None):
    url = f"https://{host}/api/{path}"
    if params:
        url += "?" + "&".join(f"{k}={v}" for k, v in params.items())
    creds = base64.b64encode(f"{user}:{password}".encode()).decode()
    req = urllib.request.Request(url, headers={
        "Authorization": f"Basic {creds}",
        "Accept":        "application/json",
    })
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"[ERROR] NetApp {e.code} on {url}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"[ERROR] Cannot reach NetApp at {host}: {e.reason}", file=sys.stderr)
        print(f"        Ensure you are on the correct network/VPN and {host} is reachable.", file=sys.stderr)
        sys.exit(1)


def _netapp_get_all(host, user, password, path, params=None):
    params = dict(params or {})
    params.setdefault("max_records", "1000")
    records = []
    while True:
        data = _netapp_request(host, user, password, path, params)
        records.extend(data.get("records", []))
        next_href = data.get("_links", {}).get("next", {}).get("href")
        if not next_href:
            break
        path   = next_href.lstrip("/")
        if path.startswith("api/"):
            path = path[4:]
        params = {}
    return records


def _netapp_post(host, user, password, path, body):
    url = f"https://{host}/api/{path}"
    data = json.dumps(body).encode()
    creds = base64.b64encode(f"{user}:{password}".encode()).decode()
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Authorization":  f"Basic {creds}",
        "Accept":         "application/json",
        "Content-Type":   "application/json",
    })
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def _do_delete(host, user, password, url):
    creds = base64.b64encode(f"{user}:{password}".encode()).decode()
    req   = urllib.request.Request(url, method="DELETE", headers={
        "Authorization": f"Basic {creds}",
        "Accept":        "application/json",
    })
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE
    with urllib.request.urlopen(req, context=ctx):
        pass


def get_igroups(host, user, password, svm=None):
    params = {"fields": "name,uuid,initiators,svm.name"}
    if svm:
        params["svm.name"] = svm
    raw = _netapp_get_all(host, user, password, "protocols/san/igroups", params)
    return {
        ig["name"]: {
            "uuid":       ig.get("uuid", ""),
            "initiators": [i.get("name", "") for i in ig.get("initiators", [])],
            "svm":        ig.get("svm", {}).get("name", ""),
        }
        for ig in raw
    }


def get_lun_map(host, user, password, svm=None):
    """Return {lun_path: [list of mapping dicts]} — preserves dual mappings."""
    params = {"fields": "lun.name,lun.uuid,igroup.name,igroup.uuid,logical_unit_number,svm.name"}
    if svm:
        params["svm.name"] = svm
    raw = _netapp_get_all(host, user, password, "protocols/san/lun-maps", params)
    result = {}
    for m in raw:
        lun_path = m.get("lun", {}).get("name", "")
        result.setdefault(lun_path, []).append({
            "igroup":      m.get("igroup", {}).get("name", ""),
            "igroup_uuid": m.get("igroup", {}).get("uuid", ""),
            "lun_uuid":    m.get("lun", {}).get("uuid", ""),
            "lun_id":      m.get("logical_unit_number"),
            "svm":         m.get("svm", {}).get("name", ""),
        })
    return result


def remove_igroup_initiator(host, user, password, ig_uuid, iqn, dry_run=False):
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}NetApp: remove initiator {iqn} from igroup {ig_uuid}")
    if dry_run:
        return True

    base_url = f"https://{host}/api/protocols/san/igroups/{ig_uuid}/initiators/{urllib.parse.quote(iqn, safe='')}"

    # Try with allow_delete_while_lun_mapped first (ONTAP 9.9+)
    try:
        _do_delete(host, user, password, base_url + "?allow_delete_while_lun_mapped=true")
        print("    Done.")
        return True
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 400 and "allow_delete_while_lun_mapped" in body:
            pass  # Older ONTAP — retry without the parameter
        else:
            print(f"    [ERROR] {e.code}: {body}", file=sys.stderr)
            return False
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error during igroup DELETE: {e.reason}", file=sys.stderr)
        return False

    try:
        _do_delete(host, user, password, base_url)
        print("    Done.")
        return True
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 409:
            print(f"    [MANUAL ACTION REQUIRED] NetApp rejected automatic removal.")
            print(f"    This ONTAP version requires LUN maps to be removed first.")
            print(f"    Remove manually via NetApp System Manager:")
            print(f"      Storage → Igroups → search '{ig_uuid}' → Initiators → remove {iqn}")
            print(f"    Then re-run --remediate to continue.")
        else:
            print(f"    [ERROR] {e.code}: {body}", file=sys.stderr)
        return False
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error during igroup DELETE: {e.reason}", file=sys.stderr)
        return False


def remove_lun_map(host, user, password, lun_uuid, igroup_uuid, igroup_name, dry_run=False):
    """Remove one LUN→igroup mapping (DELETE /api/protocols/san/lun-maps/{lun_uuid}/{igroup_uuid})."""
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}NetApp: remove LUN map → igroup '{igroup_name}' ({igroup_uuid})")
    if dry_run:
        return True
    url = f"https://{host}/api/protocols/san/lun-maps/{lun_uuid}/{igroup_uuid}"
    try:
        _do_delete(host, user, password, url)
        print("    Done.")
        return True
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 404:
            print("    Done (mapping was already absent).")
            return True
        print(f"    [ERROR] {e.code}: {body}", file=sys.stderr)
        return False
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error during LUN map DELETE: {e.reason}", file=sys.stderr)
        return False


def add_lun_map(host, user, password, lun_path, igroup_name, svm_name, dry_run=False):
    """Add a LUN→igroup mapping (POST /api/protocols/san/lun-maps)."""
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}NetApp: map LUN '{lun_path}' → igroup '{igroup_name}'")
    if dry_run:
        return True
    body = {
        "lun":    {"name": lun_path},
        "igroup": {"name": igroup_name},
        "svm":    {"name": svm_name},
    }
    try:
        _netapp_post(host, user, password, "protocols/san/lun-maps", body)
        print("    Done.")
        return True
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        if e.code == 409:
            print("    Done (mapping already present).")
            return True
        print(f"    [ERROR] {e.code}: {body_text}", file=sys.stderr)
        return False
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error during LUN map POST: {e.reason}", file=sys.stderr)
        return False


def create_igroup(host, user, password, ig_name, svm_name, iqn, dry_run=False):
    """Create a new igroup with one initiator (POST /api/protocols/san/igroups)."""
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}NetApp: create igroup '{ig_name}' (svm={svm_name}, iqn={iqn})")
    if dry_run:
        return ig_name
    body = {
        "name":       ig_name,
        "protocol":   "iscsi",
        "os_type":    "linux",
        "svm":        {"name": svm_name},
        "initiators": [{"name": iqn}],
    }
    try:
        resp = _netapp_post(host, user, password, "protocols/san/igroups", body)
        print("    Done.")
        return ig_name
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        if e.code == 409:
            print("    Done (igroup already exists).")
            return ig_name
        print(f"    [ERROR] {e.code}: {body_text}", file=sys.stderr)
        return None
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error during igroup POST: {e.reason}", file=sys.stderr)
        return None


# ── SSH helpers ───────────────────────────────────────────────────────────

def _ssh_cmd(ssh_user, ssh_key, target, command):
    cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
    if ssh_key:
        cmd += ["-i", ssh_key]
    cmd += [f"{ssh_user}@{target}", command]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return result.stdout, result.returncode
    except Exception:
        return None, -1


def get_host_iqn_via_ssh(hostname, ssh_user, ssh_key=None, host_ip=None):
    for target in filter(None, [host_ip, hostname.split(".")[0]]):
        out, rc = _ssh_cmd(ssh_user, ssh_key, target, "cat /etc/iscsi/initiatorname.iscsi")
        if rc == 0 and out:
            for line in out.splitlines():
                if line.startswith("InitiatorName="):
                    return line.split("=", 1)[1].strip()
    return None


# ── Orphaned mpath helpers ────────────────────────────────────────────────

def _parse_orphaned_mpath(output):
    """Parse `multipath -ll` output; return WWIDs where every path is failed/ghost."""
    orphaned = []
    current = None
    total_paths = 0
    bad_paths = 0

    for line in output.splitlines():
        # New device block: line starts with a 33-char hex WWID
        m = re.match(r'^([0-9a-f]{33})\s', line)
        if m:
            if current is not None and total_paths > 0 and total_paths == bad_paths:
                orphaned.append(current)
            current = m.group(1)
            total_paths = 0
            bad_paths = 0
        elif current is not None:
            # Path lines: H:C:T:L sdX M:N <dm_status> <checker_state> ...
            path_m = re.search(r'\d+:\d+:\d+:\d+\s+\S+\s+\d+:\d+\s+(\w+)', line)
            if path_m:
                total_paths += 1
                if path_m.group(1) in ('failed', 'ghost'):
                    bad_paths += 1

    if current is not None and total_paths > 0 and total_paths == bad_paths:
        orphaned.append(current)

    return orphaned


def get_orphaned_mpath_on_host(hostname, ssh_user, ssh_key=None, host_ip=None):
    """SSH to host and return list of orphaned mpath WWIDs (all paths failed/ghost).

    Returns None if SSH failed, [] if SSH succeeded but no orphans found.
    """
    target = host_ip or hostname.split(".")[0]
    out, rc = _ssh_cmd(ssh_user, ssh_key, target, "multipath -ll 2>/dev/null")
    if rc != 0 or out is None:
        return None
    return _parse_orphaned_mpath(out)


def flush_mpath_via_ssh(hostname, ssh_user, ssh_key, host_ip, wwid, dry_run=False):
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}multipath -f {wwid}")
    if dry_run:
        return True
    target = host_ip or hostname.split(".")[0]
    out, rc = _ssh_cmd(ssh_user, ssh_key, target, f"multipath -f {wwid} 2>&1")
    if rc == 0:
        print("    Done.")
        return True
    msg = (out or "").strip()
    if "map in use" in msg:
        print(f"    [WARN] Cannot flush {wwid}: device is held open by a running process "
              f"(stop or live-migrate the VM first, then re-run --remediate).", file=sys.stderr)
    else:
        print(f"    [WARN] rc={rc}: {msg}", file=sys.stderr)
    return False


def run_mpath_cleanup(nova_hosts, ssh_user, ssh_key, hyp_ip_map, dry_run, remediate):
    """Scan compute hosts for orphaned mpath devices and optionally flush them.

    detect-only (remediate=False, dry_run=False): report WWIDs, no flush.
    dry-run     (dry_run=True):                   show flush commands, no changes.
    remediate   (remediate=True):                 flush each orphaned device via SSH.
    """
    hyp_ip_map = hyp_ip_map or {}
    prefix = "[DRY-RUN] " if dry_run else ""

    print(f"\n{'='*80}")
    print(f"{prefix}ORPHANED MPATH CLEANUP")
    print(f"{'='*80}")
    print("Scanning compute hosts for mpath devices with all paths failed...\n")

    any_found = False
    for host in sorted(nova_hosts):
        short = host.split(".")[0]
        wwids = get_orphaned_mpath_on_host(host, ssh_user, ssh_key, hyp_ip_map.get(host))
        if wwids is None:
            print(f"  {short}: SSH failed — skipping")
            continue
        if not wwids:
            print(f"  {short}: no orphaned mpath devices")
            continue
        any_found = True
        print(f"\n  {short}: {len(wwids)} orphaned mpath device(s)")
        for wwid in wwids:
            if remediate or dry_run:
                flush_mpath_via_ssh(host, ssh_user, ssh_key, hyp_ip_map.get(host),
                                    wwid, dry_run=dry_run)
            else:
                print(f"    {wwid}")

    if not any_found:
        print("\n✓  No orphaned mpath devices found across all hosts.")
    elif not (remediate or dry_run):
        print("\nRun with --dry-run to preview or --remediate to flush.")


# ── Host health checks ────────────────────────────────────────────────────

def check_host_health_via_ssh(hostname, ssh_user, ssh_key=None, host_ip=None):
    cmd = (
        "printf 'MPFAIL:%s\\n' \"$(multipath -ll 2>/dev/null | grep -cE 'failed|faulty' || echo 0)\"; "
        "printf 'DSTATE:%s\\n' \"$(ps -eo stat,comm 2>/dev/null | awk '$1~/^D/{print $2}' | sort -u | tr '\\n' ' ')\"; "
        "printf 'LIBVIRTD:%s\\n' \"$(systemctl is-active libvirtd 2>/dev/null || echo unknown)\"; "
        "printf 'VIRSH:%s\\n' \"$(timeout 5 virsh list --all --name 2>/dev/null | grep -vc '^$' || echo timeout)\""
    )
    target = host_ip or hostname.split(".")[0]
    out, rc = _ssh_cmd(ssh_user, ssh_key, target, cmd)
    try:
        if rc != 0 or not out:
            return None
        health = {}
        for line in out.splitlines():
            key, _, val = line.partition(":")
            health[key.strip()] = val.strip()
        return {
            "libvirtd":     health.get("LIBVIRTD", "unknown"),
            "mp_failed":    int(health.get("MPFAIL", "0") or "0"),
            "dstate_procs": [p for p in health.get("DSTATE", "").split() if p],
            "virsh_domains": health.get("VIRSH", "unknown"),
        }
    except Exception:
        return None


def run_host_health_checks(nova_hosts, ssh_user, ssh_key=None, hyp_ip_map=None):
    hyp_ip_map = hyp_ip_map or {}
    results = {}
    with ThreadPoolExecutor(max_workers=min(len(nova_hosts), 8)) as pool:
        futures = {
            pool.submit(check_host_health_via_ssh, h, ssh_user, ssh_key, hyp_ip_map.get(h)): h
            for h in nova_hosts
        }
        for future in as_completed(futures):
            results[futures[future]] = future.result()
    return results


def print_health_report(health_results):
    if not health_results:
        return
    print(f"\n{'='*80}")
    print("HOST HEALTH")
    print(f"{'='*80}")
    for host, h in sorted(health_results.items()):
        short = host.split(".")[0]
        if h is None:
            print(f"\n  {short}: SSH failed — health check skipped")
            continue
        mp_str     = f"{h['mp_failed']} failed path(s)" if h["mp_failed"] else "OK"
        dstate_str = ", ".join(h["dstate_procs"]) if h["dstate_procs"] else "none"
        print(f"\n  {short}")
        print(f"    libvirtd     : {h['libvirtd']}{'  ← ATTENTION' if h['libvirtd'] != 'active' else ''}")
        print(f"    multipath    : {mp_str}{'  ← ATTENTION' if h['mp_failed'] else ''}")
        print(f"    D-state procs: {dstate_str}{'  ← ATTENTION' if h['dstate_procs'] else ''}")
        print(f"    virsh        : {h['virsh_domains']} domain(s) visible")


# ── Cross-reference helpers ────────────────────────────────────────────────

def iqn_to_hostname(iqn):
    parts = iqn.rsplit(":", 1)
    return parts[-1].lower() if len(parts) > 1 else iqn.lower()


def is_ubuntu_iqn(iqn):
    return "com.ubuntu" in iqn.lower()


def hostname_matches_iqn(hostname, iqn):
    # Only valid for RHEL/Rocky — Ubuntu IQNs encode a hardware ID, not a hostname.
    if is_ubuntu_iqn(iqn):
        return False
    return hostname.split(".")[0].lower() in iqn_to_hostname(iqn)


def find_lun_for_volume(volume_id, lun_map):
    for lun_path in lun_map:
        if volume_id in lun_path:
            return lun_path
    return None


def find_igroup_for_host(nova_host, host_iqn_map, igroups):
    """Return (igroup_name, igroup_data) whose initiators match nova_host, or (None, None).

    Warns if multiple igroups match the same host IQN — this indicates duplicate igroups
    (e.g. left behind by VMHA or a failed migration that created a second igroup).
    """
    nova_s     = nova_host.split(".")[0].lower()
    known_iqns = host_iqn_map.get(nova_s, set())
    if not known_iqns:
        return None, None
    matches = [
        (name, data) for name, data in igroups.items()
        if known_iqns & set(data.get("initiators", []))
    ]
    if len(matches) > 1:
        names = ", ".join(n for n, _ in matches)
        print(f"  [WARN] {nova_s}: multiple igroups share the same IQN — {names}",
              file=sys.stderr)
        print(f"         Duplicate igroups indicate a prior VMHA or failed-migration side effect.",
              file=sys.stderr)
        print(f"         Using '{matches[0][0]}' (first match). Verify this is correct.",
              file=sys.stderr)
    if matches:
        return matches[0]
    return None, None


# ── Detection ──────────────────────────────────────────────────────────────

def _fetch_server_items(server, hyp_map, igroups, lun_map):
    """Fetch volume/attachment data for one server. Runs in a worker thread."""
    nova_host = hyp_map.get(server["host"], server["host"])
    if not nova_host:
        return []
    items = []
    for volume_id in get_server_volumes(server["id"]):
        vol = get_volume_info(volume_id)
        if not vol:
            continue
        attachments = vol.get("attachments", [])
        if isinstance(attachments, str):
            try:
                attachments = json.loads(attachments)
            except json.JSONDecodeError:
                attachments = []
        cinder_host = attachment_id = ""
        for att in attachments:
            if att.get("server_id") == server["id"]:
                raw           = att.get("host_name", "")
                cinder_host   = hyp_map.get(raw, raw)
                attachment_id = att.get("attachment_id", att.get("id", ""))
                break
        lun_path = find_lun_for_volume(volume_id, lun_map)
        mappings = lun_map.get(lun_path, []) if lun_path else []
        items.append({
            "server":        server,
            "nova_host":     nova_host,
            "volume_id":     volume_id,
            "cinder_host":   cinder_host,
            "attachment_id": attachment_id,
            "lun_path":      lun_path,
            "lun_maps":      mappings,   # list of {igroup, igroup_uuid, lun_uuid, lun_id, svm}
        })
    return items


def _classify_lun_maps(lun_maps, igroups, nova_host, host_iqn_map):
    """Split LUN map entries into nova_maps (correct) / stale_maps / unknown_maps."""
    nova_s         = nova_host.split(".")[0].lower()
    known_nova_iqns = host_iqn_map.get(nova_s, set())
    nova_maps    = []
    stale_maps   = []
    unknown_maps = []

    for m in lun_maps:
        ig_data  = igroups.get(m["igroup"], {})
        ig_iqns  = set(ig_data.get("initiators", []))
        enriched = {**m, "igroup_data": ig_data, "igroup_iqns": list(ig_iqns)}

        if known_nova_iqns:
            if known_nova_iqns & ig_iqns:
                nova_maps.append(enriched)
            else:
                stale_maps.append(enriched)
        else:
            matchable = [q for q in ig_iqns if not is_ubuntu_iqn(q)]
            if matchable:
                if any(hostname_matches_iqn(nova_host, q) for q in matchable):
                    nova_maps.append(enriched)
                else:
                    stale_maps.append(enriched)
            else:
                unknown_maps.append(enriched)

    return nova_maps, stale_maps, unknown_maps


def detect(servers, netapp_host, netapp_user, netapp_password, svm,
           ssh_user=None, ssh_key=None, hyp_ip_map=None, manual_iqns=None):
    print("\nQuerying NetApp ONTAP...")
    with ThreadPoolExecutor(max_workers=2) as pool:
        ig_future  = pool.submit(get_igroups,  netapp_host, netapp_user, netapp_password, svm)
        lun_future = pool.submit(get_lun_map,  netapp_host, netapp_user, netapp_password, svm)
        igroups = ig_future.result()
        lun_map = lun_future.result()
    hyp_map = get_hypervisor_name_map()
    print(f"Checking {len(servers)} VM(s)...\n")

    # Pass 1: fetch per-VM data in parallel; print progress so screen isn't blank
    collected = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(_fetch_server_items, s, hyp_map, igroups, lun_map): s for s in servers}
        done = 0
        for future in as_completed(futures):
            done += 1
            server = futures[future]
            print(f"  [{done}/{len(servers)}] {server['name']}", flush=True)
            try:
                collected.extend(future.result())
            except Exception as exc:
                print(f"  [WARN] {server['name']}: {exc}", file=sys.stderr)

    # Pass 2a: infer ground-truth IQNs from clean (non-stale) attachments.
    host_iqn_map = {}
    for item in collected:
        nova_s   = item["nova_host"].split(".")[0].lower()
        cinder_s = item["cinder_host"].split(".")[0].lower() if item["cinder_host"] else ""
        if cinder_s and nova_s == cinder_s:
            for m in item["lun_maps"]:
                ig_data = igroups.get(m["igroup"], {})
                for iqn in ig_data.get("initiators", []):
                    host_iqn_map.setdefault(nova_s, set()).add(iqn)

    # Pass 2b: seed from --host-iqn entries (substring match on short hostname)
    if manual_iqns:
        nova_shorts = {item["nova_host"].split(".")[0].lower() for item in collected}
        for key, iqn in manual_iqns.items():
            matched = [s for s in nova_shorts if key.lower() in s]
            if matched:
                for s in matched:
                    host_iqn_map.setdefault(s, set()).add(iqn)
                    print(f"  --host-iqn: {s} → {iqn}", flush=True)
            else:
                print(f"  [WARN] --host-iqn: no host matched '{key}' (known: {', '.join(nova_shorts)})",
                      file=sys.stderr)

    # Pass 2c: SSH to fetch IQNs for hosts not yet covered
    if ssh_user:
        ssh_hosts = {h for h in {item["nova_host"] for item in collected if item["nova_host"]}
                     if h.split(".")[0].lower() not in host_iqn_map}
        if ssh_hosts:
            hyp_ip_map = hyp_ip_map or {}
            print(f"\nFetching IQNs via SSH ({ssh_user}@host)...")
            with ThreadPoolExecutor(max_workers=min(len(ssh_hosts), 8)) as pool:
                ssh_futures = {
                    pool.submit(get_host_iqn_via_ssh, h, ssh_user, ssh_key, hyp_ip_map.get(h)): h
                    for h in ssh_hosts
                }
                for future in as_completed(ssh_futures):
                    host  = ssh_futures[future]
                    short = host.split(".")[0].lower()
                    iqn   = future.result()
                    if iqn:
                        host_iqn_map[short] = {iqn}
                        print(f"  {short}: {iqn}", flush=True)
                    else:
                        print(f"  [WARN] {short}: SSH failed — igroup check will be skipped for Ubuntu hosts",
                              flush=True)

    # Pass 3: classify LUN maps per item and build findings
    findings     = []
    warned_hosts = set()
    for item in collected:
        server      = item["server"]
        nova_host   = item["nova_host"]
        cinder_host = item["cinder_host"]
        nova_s   = nova_host.split(".")[0].lower()
        lun_maps = item["lun_maps"]

        nova_maps, stale_maps, unknown_maps = _classify_lun_maps(
            lun_maps, igroups, nova_host, host_iqn_map
        )

        dual_mapping   = bool(nova_maps and stale_maps)
        source_missing = bool(not nova_maps and stale_maps)
        igroup_stale   = bool(stale_maps)

        # Warn about Ubuntu-IQN hosts we can't classify
        if lun_maps and not nova_maps and not stale_maps and unknown_maps:
            warned_hosts.add(nova_host)

        if not (dual_mapping or source_missing):
            continue

        stale_iqns = []
        for m in stale_maps:
            stale_iqns.extend(m["igroup_iqns"])

        # Primary map for legacy display fields (prefer stale for backward compat)
        primary      = (stale_maps or nova_maps or unknown_maps or [{}])[0]
        prim_ig_data = primary.get("igroup_data", {})

        findings.append({
            "vm_id":          server["id"],
            "vm_name":        server["name"],
            "vm_status":      server["status"],
            "nova_host":      nova_host,
            "cinder_host":    cinder_host,
            "volume_id":      item["volume_id"],
            "attachment_id":  item["attachment_id"],
            "lun_path":       item["lun_path"],
            "lun_maps":       lun_maps,
            "nova_maps":      nova_maps,
            "stale_maps":     stale_maps,
            "unknown_maps":   unknown_maps,
            # Legacy display fields
            "igroup":         primary.get("igroup", ""),
            "igroup_uuid":    prim_ig_data.get("uuid", primary.get("igroup_uuid", "")),
            "igroup_svm":     prim_ig_data.get("svm", primary.get("svm", "")),
            "igroup_iqns":    list(prim_ig_data.get("initiators", [])),
            "stale_iqns":     stale_iqns,
            "dual_mapping":   dual_mapping,
            "source_missing": source_missing,
            "igroup_stale":   igroup_stale,
        })

    for host in sorted(warned_hosts):
        short = host.split(".")[0]
        print(f"  [WARN] {short}: igroup check skipped — "
              f"pass --host-iqn {short}=<IQN> (get via: cat /etc/iscsi/initiatorname.iscsi)",
              flush=True)

    all_nova_hosts = {item["nova_host"] for item in collected if item["nova_host"]}
    return findings, igroups, host_iqn_map, all_nova_hosts


# ── Reporting ──────────────────────────────────────────────────────────────

def print_report(findings):
    if not findings:
        print("✓  No igroup mapping issues detected.")
        return

    print(f"\n{'='*80}")
    print(f"ISSUES FOUND: {len(findings)}")
    print(f"{'='*80}")

    for f in findings:
        tags = []
        if f.get("dual_mapping"):     tags.append("DUAL IGROUP")
        elif f.get("source_missing"): tags.append("SOURCE MISSING")
        elif f.get("igroup_stale"):   tags.append("STALE IGROUP")

        print(f"\n  [{' + '.join(tags) or 'UNKNOWN'}]")
        print(f"  VM           : {f['vm_name']} ({f['vm_id']})  status={f['vm_status']}")
        print(f"  Volume       : {f['volume_id']}")
        print(f"  Nova host    : {f['nova_host']}")

        if f.get("dual_mapping"):
            print(f"  LUN maps     : {len(f['lun_maps'])} igroup(s)  ← DUAL MAPPING (most common production failure)")
            for m in f.get("nova_maps", []):
                ig_iqns = m.get("igroup_iqns", [])
                hosts   = ", ".join(iqn_to_hostname(q) for q in ig_iqns) or "(none)"
                print(f"    ✓ {m['igroup']}  →  IQN hosts: {hosts}  [correct — nova host]")
            for m in f.get("stale_maps", []):
                ig_iqns = m.get("igroup_iqns", [])
                hosts   = ", ".join(iqn_to_hostname(q) for q in ig_iqns) or "(none)"
                print(f"    ✗ {m['igroup']}  →  IQN hosts: {hosts}  [stale — destination igroup]")
        elif f.get("source_missing"):
            print(f"  LUN maps     : source igroup mapping is MISSING (removed by failed terminate_connection)")
            for m in f.get("stale_maps", []):
                ig_iqns = m.get("igroup_iqns", [])
                hosts   = ", ".join(iqn_to_hostname(q) for q in ig_iqns) or "(none)"
                print(f"    ✗ {m['igroup']}  →  IQN hosts: {hosts}  [wrong host — destination only]")
        elif f["igroup"]:
            hosts = ", ".join(iqn_to_hostname(q) for q in f["igroup_iqns"]) or "(none)"
            print(f"  igroup       : {f['igroup']}  →  IQN hosts: {hosts}")
            for iqn in f["stale_iqns"]:
                print(f"  Stale IQN    : {iqn}")


# ── Remediation ────────────────────────────────────────────────────────────

def remediate(findings, igroups, host_iqn_map, netapp_host, netapp_user, netapp_password, dry_run):
    if not findings:
        return

    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"\n{'='*80}")
    print(f"{prefix}REMEDIATION")
    print(f"{'='*80}")
    print("Steps per finding:")
    print("  1. Fix NetApp LUN maps / igroup initiators  (automated here)")
    print("  2. iSCSI rescan                             (commands to run on the correct host)")
    print("  3. Nova BDM target_lun fix                  (SQL to run — review before applying)")
    print()

    by_vm = {}
    for f in findings:
        by_vm.setdefault(f["vm_id"], []).append(f)

    for vm_id, vm_findings in by_vm.items():
        first      = vm_findings[0]
        nova_host  = first["nova_host"]
        nova_s     = nova_host.split(".")[0].lower()
        known_iqns = host_iqn_map.get(nova_s, set())
        correct_iqn = next(iter(known_iqns), None)

        print(f"\n── {first['vm_name']} ({vm_id}) ──")
        print(f"   Nova host  : {nova_host}")

        # ── Step 1: Fix NetApp ────────────────────────────────────────────
        print(f"\n  STEP 1: Fix NetApp LUN maps")
        step1_ok = True

        for f in vm_findings:
            print(f"\n    Volume  : {f['volume_id']}")
            print(f"    LUN path: {f['lun_path'] or '(not found on NetApp)'}")
            if not f["lun_path"]:
                print(f"    (skip — LUN not found)")
                continue

            lun_uuid = (f["nova_maps"] or f["stale_maps"] or [{}])[0].get("lun_uuid", "")

            if f.get("dual_mapping"):
                # Remove the stale (destination) LUN map entries
                for m in f["stale_maps"]:
                    ok = remove_lun_map(
                        netapp_host, netapp_user, netapp_password,
                        m.get("lun_uuid", lun_uuid), m["igroup_uuid"], m["igroup"],
                        dry_run=dry_run,
                    )
                    if not ok:
                        step1_ok = False

                # Print the correct LUN ID from nova_maps for BDM fix reference
                if f["nova_maps"]:
                    nm = f["nova_maps"][0]
                    print(f"    Correct LUN ID (nova host's mapping): {nm.get('lun_id')}  "
                          f"← use this for BDM fix in Step 3")

            elif f.get("source_missing"):
                # Need to re-add the source (nova_host) LUN map.
                # If the igroup was deleted entirely (e.g. by VMHA), create it first.
                nova_ig_name, nova_ig_data = find_igroup_for_host(nova_host, host_iqn_map, igroups)
                svm_name = (f["stale_maps"] or [{}])[0].get("svm", "")

                if not nova_ig_name and correct_iqn:
                    # Igroup is gone — create a recovery igroup for this host.
                    recovery_ig_name = f"openstack-recovery-{nova_s}"
                    print(f"    igroup for {nova_host} not found on NetApp — will create one.")
                    created = create_igroup(
                        netapp_host, netapp_user, netapp_password,
                        recovery_ig_name, svm_name, correct_iqn,
                        dry_run=dry_run,
                    )
                    if created:
                        nova_ig_name = created
                        # Refresh local igroups cache so subsequent volumes find it
                        igroups[nova_ig_name] = {
                            "uuid": "",
                            "initiators": [correct_iqn],
                            "svm": svm_name,
                        }
                    else:
                        step1_ok = False

                if nova_ig_name:
                    # Add the correct (source) mapping first — if this fails the stale
                    # map is still in place and the VM retains disk access.
                    ok = add_lun_map(
                        netapp_host, netapp_user, netapp_password,
                        f["lun_path"], nova_ig_name, svm_name,
                        dry_run=dry_run,
                    )
                    if not ok:
                        step1_ok = False
                    else:
                        # Only remove the stale destination mapping after the correct
                        # one is confirmed present — worst case is DUAL IGROUP, not data loss.
                        for m in f["stale_maps"]:
                            ok = remove_lun_map(
                                netapp_host, netapp_user, netapp_password,
                                m.get("lun_uuid", lun_uuid), m["igroup_uuid"], m["igroup"],
                                dry_run=dry_run,
                            )
                            if not ok:
                                step1_ok = False
                elif not step1_ok:
                    pass  # create_igroup already printed the error
                else:
                    print(f"    [WARN] Cannot find or create igroup for {nova_host} — "
                          f"IQN unknown. Pass --host-iqn {nova_s}=<IQN> or --ssh-user.")
                    print(f"    Get IQN: ssh {nova_host} 'cat /etc/iscsi/initiatorname.iscsi'")
                    step1_ok = False

            elif f.get("igroup_stale") and f["stale_iqns"]:
                # Legacy: igroup exists but has wrong initiator
                print(f"    igroup  : {f['igroup']}")
                for iqn in f["stale_iqns"]:
                    ok = remove_igroup_initiator(
                        netapp_host, netapp_user, netapp_password,
                        f["igroup_uuid"], iqn, dry_run=dry_run,
                    )
                    if not ok:
                        step1_ok = False

                if correct_iqn:
                    print(f"    Add correct IQN for {nova_host}: {correct_iqn}")
                    print(f"    curl -sk -u {netapp_user}:<pass> -X POST \\")
                    print(f"      https://{netapp_host}/api/protocols/san/igroups/{f['igroup_uuid']}/initiators \\")
                    print(f"      -H 'Content-Type: application/json' -d '{{\"name\": \"{correct_iqn}\"}}'")
                else:
                    print(f"    IQN not found — retrieve manually:")
                    print(f"    ssh {nova_host} 'cat /etc/iscsi/initiatorname.iscsi'")
                    print(f"    Then: python3 pf9-storage-audit.py ... --host-iqn {nova_s}=<IQN> --remediate")
            else:
                print(f"    NetApp igroup OK — no changes needed")

        if not step1_ok and not dry_run:
            print(f"\n  ✗ STEP 1 FAILED — manual NetApp action required (see above).")
            print(f"    Re-run with --remediate after fixing NetApp manually.")
            continue

        # ── Step 2: iSCSI rescan ──────────────────────────────────────────
        print(f"\n  STEP 2: iSCSI rescan — run on {nova_host}:")
        print(f"    iscsiadm -m session -R")
        print(f"    iscsiadm -m node --login")
        print(f"    multipath -r")
        print(f"    multipath -ll | grep -E 'failed|faulty|0 paths'")

        # ── Step 3: Nova BDM target_lun fix ──────────────────────────────
        print(f"\n  STEP 3: Nova BDM target_lun fix")

        any_dual    = any(f.get("dual_mapping")   for f in vm_findings)
        any_missing = any(f.get("source_missing") for f in vm_findings)

        if any_dual or any_missing:
            print(f"    # target_lun / target_luns in Nova BDM may point to the destination LUN ID.")
            print(f"    # First, check current values and path count:")
            for f in vm_findings:
                print(f"    mysql> SELECT instance_uuid,")
                print(f"                  JSON_EXTRACT(connection_info, '$.data.target_lun')  AS lun,")
                print(f"                  JSON_EXTRACT(connection_info, '$.data.target_luns') AS luns")
                print(f"           FROM block_device_mapping")
                print(f"           WHERE volume_id = '{f['volume_id']}'")
                print(f"             AND instance_uuid = '{vm_id}'")
                print(f"             AND deleted = 0;")
            print(f"")
            print(f"    # Then update — adjust JSON_ARRAY() length to match the path count above:")
            for f in vm_findings:
                correct_lun_id = (f["nova_maps"] or [{}])[0].get("lun_id")
                if correct_lun_id is not None:
                    lun_array = ", ".join([str(correct_lun_id)] * 4)
                    print(f"    # Volume {f['volume_id']}  →  correct LUN ID = {correct_lun_id}")
                    print(f"    mysql> UPDATE block_device_mapping")
                    print(f"           SET connection_info = JSON_SET(")
                    print(f"               JSON_SET(connection_info, '$.data.target_lun', {correct_lun_id}),")
                    print(f"               '$.data.target_luns', JSON_ARRAY({lun_array})")
                    print(f"           )")
                    print(f"           WHERE volume_id = '{f['volume_id']}'")
                    print(f"             AND instance_uuid = '{vm_id}'")
                    print(f"             AND deleted = 0;")
                else:
                    print(f"    # Volume {f['volume_id']}: LUN ID unknown — check NetApp and set manually")
        else:
            print(f"    # Igroup was the only issue — no BDM change needed.")

    print(f"\n{'='*80}")
    print("After all steps, verify:")
    print("  virsh list --all           (on affected host — should not hang)")
    print("  multipath -ll              (no failed/faulty maps)")
    print("  openstack volume list      (volumes should be 'in-use')")
    print("  openstack server list      (VMs should be 'ACTIVE')")


# ── Entry point ────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Detect and remediate stale Cinder BDM/igroup state after failed migrations"
    )
    parser.add_argument("--netapp-host",     required=True)
    parser.add_argument("--netapp-user",     default="admin")
    parser.add_argument("--netapp-password", help="Prompted if omitted")
    parser.add_argument("--svm",             help="Filter by SVM name (e.g. vs.5)")
    parser.add_argument("--server",          help="Check a single VM by ID or name")
    parser.add_argument("--ssh-user",        default=None,
                        help="SSH user for host health checks and IQN fetching (e.g. root)")
    parser.add_argument("--ssh-key",         default=None, metavar="PATH",
                        help="SSH private key file (optional if default key works)")
    parser.add_argument("--host-iqn",        action="append", default=[], metavar="HOST=IQN",
                        help="Known IQN for a compute host, e.g. 970-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9. "
                             "Repeat for each host. Run: cat /etc/iscsi/initiatorname.iscsi on each host.")
    parser.add_argument("--dry-run",         action="store_true",
                        help="Preview all remediation steps without making changes")
    parser.add_argument("--remediate",       action="store_true",
                        help="Apply igroup fixes and print Cinder/iSCSI steps")
    parser.add_argument("--clean-mpath",     action="store_true",
                        help="Scan compute hosts for orphaned mpath devices (all paths failed) "
                             "and flush them. Requires --ssh-user. Use with --dry-run to preview.")
    args = parser.parse_args()

    manual_iqns = {}
    for entry in args.host_iqn:
        if "=" not in entry:
            print(f"[ERROR] --host-iqn must be HOST=IQN format, got: {entry}", file=sys.stderr)
            sys.exit(1)
        host, iqn = entry.split("=", 1)
        manual_iqns[host.strip()] = iqn.strip()

    if not args.netapp_password:
        args.netapp_password = getpass.getpass(
            f"NetApp password for {args.netapp_user}@{args.netapp_host}: "
        )

    print("Querying OpenStack...")
    servers = [get_server(args.server)] if args.server else get_all_servers()
    print(f"Found {len(servers)} VM(s).")

    hyp_ip_map = get_hypervisor_ip_map()

    findings, igroups, host_iqn_map, all_nova_hosts = detect(
        servers, args.netapp_host, args.netapp_user, args.netapp_password, args.svm,
        ssh_user=args.ssh_user, ssh_key=args.ssh_key, hyp_ip_map=hyp_ip_map,
        manual_iqns=manual_iqns or None,
    )

    if args.ssh_user and all_nova_hosts:
        health_results = run_host_health_checks(
            all_nova_hosts, args.ssh_user, args.ssh_key, hyp_ip_map)
        print_health_report(health_results)

    print_report(findings)

    stale_vms = len({f["vm_id"] for f in findings})
    if findings:
        dual    = sum(1 for f in findings if f.get("dual_mapping"))
        missing = sum(1 for f in findings if f.get("source_missing"))
        print(f"\nSummary: {stale_vms} VM(s), {len(findings)} volume(s) with issues "
              f"[dual_mapping={dual}, source_missing={missing}]")

    if args.remediate or args.dry_run:
        remediate(findings, igroups, host_iqn_map, args.netapp_host, args.netapp_user,
                  args.netapp_password, dry_run=args.dry_run)
    elif findings:
        print("\nRun with --dry-run to preview remediation steps.")
        print("Run with --remediate to apply igroup fixes and print Cinder/iSCSI steps.")

    if args.clean_mpath:
        if not args.ssh_user:
            print("[ERROR] --clean-mpath requires --ssh-user", file=sys.stderr)
            sys.exit(1)
        run_mpath_cleanup(all_nova_hosts, args.ssh_user, args.ssh_key, hyp_ip_map,
                          dry_run=args.dry_run, remediate=args.remediate)

    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[Interrupted]", file=sys.stderr)
        sys.exit(130)
