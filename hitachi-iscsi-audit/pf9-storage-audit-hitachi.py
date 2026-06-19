#!/usr/bin/env python3
"""
pf9-storage-audit-hitachi.py — Cluster-wide iSCSI live-migration BDM/host-group remediation
for Hitachi VSP storage.

Cross-references Nova, Cinder, and Hitachi VSP to find and fix stale attachment
state left behind by failed live migrations.

Detects two failure modes:
  DUAL HOST GROUP  — LDEV is mapped to both source and destination host groups.
                     Root cause: pre_live_migration ran on destination but migration
                     failed and BDM rollback was skipped (libvirt monitor timeout).
  SOURCE MISSING   — LDEV is mapped only to the destination host group; source host
                     group mapping was removed (e.g. failed terminate_connection call).

Key Hitachi differences vs NetApp:
  - Host groups are per-port: a single logical "host" appears as one host group
    on each iSCSI port (e.g. CL1-A and CL2-A). The script groups them by name.
  - LDEVs are identified by integer ID. The Hitachi Cinder driver writes the decimal
    LDEV ID into provider_location; the script reads this first, then falls back
    to label search.
  - Some VSP operations return a job ID and must be polled to completion.
  - LU path IDs use the format "portId,hostGroupNumber,lun" (e.g. "CL1-A,0,0").

Usage:
  # Detect only
  python3 pf9-storage-audit-hitachi.py --hitachi-host <ip> --hitachi-user svol_admin

  # With SSH for IQN resolution and host health
  python3 pf9-storage-audit-hitachi.py --hitachi-host <ip> --hitachi-user svol_admin \\
    --ssh-user root --ssh-key /tmp/key

  # Supply known IQNs manually (alternative to SSH)
  python3 pf9-storage-audit-hitachi.py ... \\
    --host-iqn compute-1=iqn.2004-10.com.ubuntu:01:04cd37af9c9

  # Preview remediation (safe — no changes)
  python3 pf9-storage-audit-hitachi.py ... --dry-run

  # Apply host-group fixes
  python3 pf9-storage-audit-hitachi.py ... --remediate
"""

import argparse
import base64
import getpass
import json
import re
import ssl
import subprocess
import sys
import time
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
    That UUID is regenerated on every service restart, so old attachments can't
    be resolved after a reboot. We try the hypervisor list UUIDs as best-effort.
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


# ── Hitachi VSP REST helpers ───────────────────────────────────────────────

def _hv_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE
    return ctx


def _hv_headers(user, password):
    creds = base64.b64encode(f"{user}:{password}".encode()).decode()
    return {
        "Authorization": f"Basic {creds}",
        "Accept":        "application/json",
        "Content-Type":  "application/json",
    }


def _hv_get(host, user, password, path, params=None):
    """Authenticated GET — sys.exit on error (used for discovery queries)."""
    url = f"https://{host}/ConfigurationManager/v1/{path}"
    if params:
        url += "?" + "&".join(
            f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in params.items()
        )
    req = urllib.request.Request(url, headers=_hv_headers(user, password))
    try:
        with urllib.request.urlopen(req, context=_hv_ctx(), timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 404:
            return {}  # resource doesn't exist (e.g. host group with no iSCSI names)
        print(f"[ERROR] Hitachi GET {url} → {e.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"[ERROR] Cannot reach Hitachi at {host}: {e.reason}", file=sys.stderr)
        print(f"        Ensure you are on the correct network/VPN and {host} is reachable.",
              file=sys.stderr)
        sys.exit(1)


def _hv_get_all(host, user, password, path, params=None):
    """Paginated GET — follows nextPageId until exhausted."""
    params = dict(params or {})
    params.setdefault("count", "500")
    records = []
    while True:
        data    = _hv_get(host, user, password, path, params)
        records.extend(data.get("data", []))
        next_id = data.get("nextPageId")
        if not next_id:
            break
        params = {"nextPageId": next_id, "count": params.get("count", "500")}
    return records


def _hv_delete(host, user, password, path):
    """DELETE — raises HTTPError/URLError on failure (handled by callers)."""
    url = f"https://{host}/ConfigurationManager/v1/{path}"
    req = urllib.request.Request(url, method="DELETE", headers=_hv_headers(user, password))
    with urllib.request.urlopen(req, context=_hv_ctx(), timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def _hv_post(host, user, password, path, body):
    """POST — raises HTTPError/URLError on failure (handled by callers)."""
    url  = f"https://{host}/ConfigurationManager/v1/{path}"
    data = json.dumps(body).encode()
    req  = urllib.request.Request(url, data=data, method="POST",
                                   headers=_hv_headers(user, password))
    with urllib.request.urlopen(req, context=_hv_ctx(), timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def _wait_for_job(host, user, password, storage_id, job_id, timeout=60):
    """Poll until job Completed or Failed. Returns True on success."""
    path     = f"objects/storages/{storage_id}/jobs/{job_id}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp   = _hv_get(host, user, password, path)
        status = resp.get("status", "")
        if status == "Completed":
            return True
        if status == "Failed":
            print(f"    [ERROR] Hitachi job {job_id} failed: {resp.get('error', {})}",
                  file=sys.stderr)
            return False
        time.sleep(2)
    print(f"    [ERROR] Hitachi job {job_id} timed out after {timeout}s", file=sys.stderr)
    return False


def _hv_mutate_ok(host, user, password, storage_id, resp):
    """Resolve a write response — wait for job if async, else return True."""
    if isinstance(resp, dict) and resp.get("jobId"):
        return _wait_for_job(host, user, password, storage_id, resp["jobId"])
    return True


# ── Hitachi discovery ──────────────────────────────────────────────────────

def get_storage_device_id(host, user, password):
    """Auto-discover the first storage device ID from the VSP management host."""
    data    = _hv_get(host, user, password, "objects/storages")
    devices = data.get("data", [])
    if not devices:
        print("[ERROR] No storage devices found on Hitachi management host.", file=sys.stderr)
        sys.exit(1)
    if len(devices) > 1:
        ids = [str(d.get("storageDeviceId", "?")) for d in devices]
        print(f"[WARN] Multiple storage devices: {', '.join(ids)} — using first.", file=sys.stderr)
    sid   = str(devices[0].get("storageDeviceId", ""))
    model = devices[0].get("model", "")
    print(f"  Storage device: {sid}  model={model}")
    return sid


def get_iscsi_ports(host, user, password, storage_id):
    """Return list of iSCSI port IDs (e.g. ['CL1-A', 'CL2-A'])."""
    ports = _hv_get_all(host, user, password, f"objects/storages/{storage_id}/ports")
    ids   = [p["portId"] for p in ports if p.get("portType") == "ISCSI"]
    print(f"  iSCSI ports: {', '.join(ids) or '(none found)'}")
    return ids


def get_host_groups(host, user, password, storage_id, port_ids):
    """Return host groups grouped by name across all iSCSI ports.

    {hg_name: {"iqns": set, "ports": {port_id: {"hg_number": int}}}}

    The Hitachi Cinder driver creates identically-named host groups on each
    iSCSI port for the same compute host (multi-path). Grouping by name lets
    callers treat the host group name as a unique host identity.
    """
    result = {}
    for port_id in port_ids:
        hgs = _hv_get_all(host, user, password,
                          f"objects/storages/{storage_id}/host-groups",
                          {"portId": port_id})
        for hg in hgs:
            name   = hg.get("hostGroupName", "")
            number = hg.get("hostGroupNumber", 0)
            if not name:
                continue
            result.setdefault(name, {"iqns": set(), "ports": {}})
            result[name]["ports"][port_id] = {"hg_number": number}

    for hg_name, hg_data in result.items():
        for port_id, port_data in hg_data["ports"].items():
            iscsi_list = _hv_get_all(
                host, user, password,
                f"objects/storages/{storage_id}/iscsi-names",
                {"portId": port_id, "hostGroupNumber": str(port_data["hg_number"])},
            )
            for entry in iscsi_list:
                iqn = entry.get("iscsiName", "")
                if iqn:
                    hg_data["iqns"].add(iqn)

    return result


def get_lun_paths(host, user, password, storage_id, host_groups):
    """Return {ldev_id (int): [list of LU path dicts]} across all iSCSI ports.

    Each dict: {hg_name, hg_number, port_id, lun, lun_id}
    lun_id is the VSP composite key "portId,hostGroupNumber,lun" used in DELETE URLs.

    VSP E1090 requires both portId AND hostGroupNumber on the /luns endpoint.
    host_groups must be the output of get_host_groups() so we can iterate
    port+hostgroup combinations rather than ports alone.
    """
    result = {}
    seen = set()  # (port_id, hg_number) already queried — avoid duplicates
    for hg_name, hg_data in host_groups.items():
        for port_id, port_data in hg_data["ports"].items():
            hg_number = port_data["hg_number"]
            key = (port_id, hg_number)
            if key in seen:
                continue
            seen.add(key)
            paths = _hv_get_all(host, user, password,
                                f"objects/storages/{storage_id}/luns",
                                {"portId": port_id, "hostGroupNumber": str(hg_number)})
            for p in paths:
                ldev_id = p.get("ldevId")
                if ldev_id is None:
                    continue
                result.setdefault(ldev_id, []).append({
                    "hg_name":   hg_name,
                    "hg_number": p.get("hostGroupNumber", hg_number),
                    "port_id":   p.get("portId", port_id),
                    "lun":       p.get("lun"),
                    "lun_id":    p.get("lunId", ""),
                })
    return result


def find_ldev_for_volume(volume_id, provider_location, ldev_label_map, manual_ldevs=None):
    """Find LDEV ID (int) for a Cinder volume.

    Priority order:
      1. --volume-ldev override (when provider_location not visible without admin scope)
      2. provider_location (decimal LDEV ID written by Hitachi Cinder driver)
      3. LDEV label search (fallback — requires driver to embed volume UUID in label)
    """
    if manual_ldevs and volume_id in manual_ldevs:
        return manual_ldevs[volume_id]
    if provider_location:
        try:
            return int(str(provider_location).strip())
        except ValueError:
            pass
    for ldev_id, ldev in ldev_label_map.items():
        if volume_id in ldev.get("label", ""):
            return ldev_id
    return None


# ── Hitachi write operations ───────────────────────────────────────────────

def remove_lun_path_entry(host, user, password, storage_id, lun_id, hg_name, dry_run=False):
    """DELETE one LU path (port + host-group mapping for an LDEV)."""
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}Hitachi: remove LU path {lun_id}  (host-group '{hg_name}')")
    if dry_run:
        return True
    encoded = urllib.parse.quote(lun_id, safe="")
    path    = f"objects/storages/{storage_id}/luns/{encoded}"
    try:
        resp = _hv_delete(host, user, password, path)
        ok   = _hv_mutate_ok(host, user, password, storage_id, resp)
        if ok:
            print("    Done.")
        return ok
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 404:
            print("    Done (mapping was already absent).")
            return True
        print(f"    [ERROR] {e.code}: {body}", file=sys.stderr)
        return False
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error: {e.reason}", file=sys.stderr)
        return False


def add_lun_path_entry(host, user, password, storage_id, port_id, hg_number, ldev_id, hg_name,
                       dry_run=False):
    """POST to add one LU path (one port/host-group mapping for an LDEV)."""
    label = "[DRY-RUN] " if dry_run else ""
    print(f"    {label}Hitachi: add LU path  LDEV {ldev_id} → port {port_id} / hg {hg_number}"
          f"  ('{hg_name}')")
    if dry_run:
        return True
    body = {"portId": port_id, "hostGroupNumber": hg_number, "ldevId": ldev_id}
    path = f"objects/storages/{storage_id}/luns"
    try:
        resp = _hv_post(host, user, password, path, body)
        ok   = _hv_mutate_ok(host, user, password, storage_id, resp)
        if ok:
            print("    Done.")
        return ok
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        if e.code == 409:
            print("    Done (mapping already present).")
            return True
        print(f"    [ERROR] {e.code}: {body_text}", file=sys.stderr)
        return False
    except urllib.error.URLError as e:
        print(f"    [ERROR] Network error: {e.reason}", file=sys.stderr)
        return False


# ── SSH helpers ────────────────────────────────────────────────────────────

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


# ── Orphaned mpath helpers ─────────────────────────────────────────────────

def _parse_orphaned_mpath(output):
    """Parse `multipath -ll` output; return WWIDs where every path is failed/ghost."""
    orphaned   = []
    current    = None
    total_paths = 0
    bad_paths   = 0

    for line in output.splitlines():
        m = re.match(r'^([0-9a-f]{33})\s', line)
        if m:
            if current is not None and total_paths > 0 and total_paths == bad_paths:
                orphaned.append(current)
            current     = m.group(1)
            total_paths = 0
            bad_paths   = 0
        elif current is not None:
            path_m = re.search(r'\d+:\d+:\d+:\d+\s+\S+\s+\d+:\d+\s+(\w+)', line)
            if path_m:
                total_paths += 1
                if path_m.group(1) in ('failed', 'ghost'):
                    bad_paths += 1

    if current is not None and total_paths > 0 and total_paths == bad_paths:
        orphaned.append(current)
    return orphaned


def get_orphaned_mpath_on_host(hostname, ssh_user, ssh_key=None, host_ip=None):
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


# ── Host health checks ─────────────────────────────────────────────────────

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
            "libvirtd":      health.get("LIBVIRTD", "unknown"),
            "mp_failed":     int(health.get("MPFAIL", "0") or "0"),
            "dstate_procs":  [p for p in health.get("DSTATE", "").split() if p],
            "virsh_domains": health.get("VIRSH", "unknown"),
        }
    except Exception:
        return None


def run_host_health_checks(nova_hosts, ssh_user, ssh_key=None, hyp_ip_map=None):
    hyp_ip_map = hyp_ip_map or {}
    results    = {}
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
    if is_ubuntu_iqn(iqn):
        return False
    return hostname.split(".")[0].lower() in iqn_to_hostname(iqn)


def find_hg_for_host(nova_host, host_iqn_map, host_groups, host_hg_map=None):
    """Return (hg_name, hg_data) for nova_host's host group, or (None, None).

    Match priority:
      1. IQN-based: hg_iqns intersects the host's known IQNs (works when iscsi-names
         API is populated, e.g. non-HBSD deployments).
      2. IP-in-name: host group name contains the host's management IP (HBSD naming
         convention: HBSD-<ip>).  Uses host_hg_map built from hypervisor list.
    """
    nova_s     = nova_host.split(".")[0].lower()
    known_iqns = host_iqn_map.get(nova_s, set())

    if known_iqns:
        matches = [
            (name, data) for name, data in host_groups.items()
            if known_iqns & data.get("iqns", set())
        ]
        if len(matches) > 1:
            names = ", ".join(n for n, _ in matches)
            print(f"  [WARN] {nova_s}: multiple host groups share the same IQN — {names}",
                  file=sys.stderr)
            print(f"         Using '{matches[0][0]}' (first match). Verify this is correct.",
                  file=sys.stderr)
        if matches:
            return matches[0]

    if host_hg_map and nova_s in host_hg_map:
        hg_name = host_hg_map[nova_s]
        if hg_name in host_groups:
            return hg_name, host_groups[hg_name]

    return None, None


# ── Detection ──────────────────────────────────────────────────────────────

def _fetch_server_items(server, hyp_map, host_groups, lun_paths, ldev_label_map, manual_ldevs=None):
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
                raw         = att.get("host_name", "")
                cinder_host = hyp_map.get(raw, raw)
                attachment_id = att.get("attachment_id", att.get("id", ""))
                break

        provider_location = vol.get("provider_location", "")
        ldev_id = find_ldev_for_volume(volume_id, provider_location, ldev_label_map, manual_ldevs)
        lun_maps_for_ldev = lun_paths.get(ldev_id, []) if ldev_id is not None else []

        items.append({
            "server":        server,
            "nova_host":     nova_host,
            "volume_id":     volume_id,
            "cinder_host":   cinder_host,
            "attachment_id": attachment_id,
            "ldev_id":       ldev_id,
            "lun_maps":      lun_maps_for_ldev,
        })
    return items


def _classify_lun_maps(lun_maps, host_groups, nova_host, host_iqn_map):
    """Split LU paths by host group name into nova / stale / unknown.

    Groups per-port entries by hg_name first: a single "host group identity"
    spans multiple ports, so we classify the name rather than individual ports.
    Each returned entry has a 'paths' list with all per-port LU path records.
    """
    nova_s          = nova_host.split(".")[0].lower()
    known_nova_iqns = host_iqn_map.get(nova_s, set())
    nova_maps    = []
    stale_maps   = []
    unknown_maps = []

    by_hg = {}
    for m in lun_maps:
        by_hg.setdefault(m["hg_name"], []).append(m)

    for hg_name, paths in by_hg.items():
        hg_data  = host_groups.get(hg_name, {})
        hg_iqns  = hg_data.get("iqns", set())
        enriched = {
            "hg_name":  hg_name,
            "hg_data":  hg_data,
            "hg_iqns":  list(hg_iqns),
            "paths":    paths,
        }

        if known_nova_iqns:
            if known_nova_iqns & hg_iqns:
                nova_maps.append(enriched)
            else:
                stale_maps.append(enriched)
        else:
            matchable = [q for q in hg_iqns if not is_ubuntu_iqn(q)]
            if matchable:
                if any(hostname_matches_iqn(nova_host, q) for q in matchable):
                    nova_maps.append(enriched)
                else:
                    stale_maps.append(enriched)
            else:
                unknown_maps.append(enriched)

    return nova_maps, stale_maps, unknown_maps


def detect(servers, hitachi_host, hitachi_user, hitachi_password, storage_id,
           ssh_user=None, ssh_key=None, hyp_ip_map=None, manual_iqns=None, manual_ldevs=None):
    print("\nQuerying Hitachi VSP...")
    port_ids = get_iscsi_ports(hitachi_host, hitachi_user, hitachi_password, storage_id)
    if not port_ids:
        print("[ERROR] No iSCSI ports found on the storage device.", file=sys.stderr)
        sys.exit(1)

    # get_host_groups must run first — get_lun_paths needs the port+hostgroup
    # combinations because VSP E1090 requires hostGroupNumber on /luns queries.
    host_groups = get_host_groups(hitachi_host, hitachi_user, hitachi_password,
                                  storage_id, port_ids)
    lun_paths   = get_lun_paths(hitachi_host, hitachi_user, hitachi_password,
                                storage_id, host_groups)

    # Pre-load LDEV labels for fallback volume matching (only LDEVs that have LU paths)
    ldev_label_map = {}
    ldev_ids_in_use = set(lun_paths.keys())
    if ldev_ids_in_use:
        print(f"  Loading {len(ldev_ids_in_use)} LDEV label(s) for volume matching...")
        for ldev_id in ldev_ids_in_use:
            resp = _hv_get(hitachi_host, hitachi_user, hitachi_password,
                           f"objects/storages/{storage_id}/ldevs/{ldev_id}")
            ldev_label_map[ldev_id] = {"label": resp.get("label", "")}

    hyp_map = get_hypervisor_name_map()
    print(f"Checking {len(servers)} VM(s)...\n")

    collected = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {
            pool.submit(_fetch_server_items, s, hyp_map, host_groups, lun_paths, ldev_label_map, manual_ldevs): s
            for s in servers
        }
        done = 0
        for future in as_completed(futures):
            done   += 1
            server  = futures[future]
            print(f"  [{done}/{len(servers)}] {server['name']}", flush=True)
            try:
                collected.extend(future.result())
            except Exception as exc:
                print(f"  [WARN] {server['name']}: {exc}", file=sys.stderr)

    # Pass 2b: manual --host-iqn entries (run first — authoritative, never overridden)
    host_iqn_map = {}
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

    # Pass 2a: infer IQNs from clean (nova == cinder) attachments for hosts not
    # covered by --host-iqn.  Skipped for covered hosts: a VM with a stale dual
    # mapping would add the stale host's IQN into the nova host's set, causing
    # _classify_lun_maps to treat the stale group as "correct" and miss the issue.
    for item in collected:
        nova_s   = item["nova_host"].split(".")[0].lower()
        cinder_s = item["cinder_host"].split(".")[0].lower() if item["cinder_host"] else ""
        if nova_s in host_iqn_map:
            continue  # explicit --host-iqn takes precedence — do not infer
        if cinder_s and nova_s == cinder_s:
            for m in item["lun_maps"]:
                hg_data = host_groups.get(m["hg_name"], {})
                for iqn in hg_data.get("iqns", set()):
                    host_iqn_map.setdefault(nova_s, set()).add(iqn)

    # Pass 2c: SSH for hosts still without IQNs
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
                    h     = ssh_futures[future]
                    short = h.split(".")[0].lower()
                    iqn   = future.result()
                    if iqn:
                        host_iqn_map[short] = {iqn}
                        print(f"  {short}: {iqn}", flush=True)
                    else:
                        print(f"  [WARN] {short}: SSH failed — host group check will be skipped "
                              f"for Ubuntu hosts", flush=True)

    # Pass 3: classify per item
    findings     = []
    warned_hosts = set()
    for item in collected:
        server    = item["server"]
        nova_host = item["nova_host"]
        lun_maps  = item["lun_maps"]

        nova_maps, stale_maps, unknown_maps = _classify_lun_maps(
            lun_maps, host_groups, nova_host, host_iqn_map
        )

        dual_mapping   = bool(nova_maps and stale_maps)
        source_missing = bool(not nova_maps and stale_maps)

        if lun_maps and not nova_maps and not stale_maps and unknown_maps:
            warned_hosts.add(nova_host)

        if not (dual_mapping or source_missing):
            continue

        stale_iqns = []
        for m in stale_maps:
            stale_iqns.extend(m["hg_iqns"])

        findings.append({
            "vm_id":          server["id"],
            "vm_name":        server["name"],
            "vm_status":      server["status"],
            "nova_host":      nova_host,
            "cinder_host":    item["cinder_host"],
            "volume_id":      item["volume_id"],
            "attachment_id":  item["attachment_id"],
            "ldev_id":        item["ldev_id"],
            "lun_maps":       lun_maps,
            "nova_maps":      nova_maps,
            "stale_maps":     stale_maps,
            "unknown_maps":   unknown_maps,
            "stale_iqns":     stale_iqns,
            "dual_mapping":   dual_mapping,
            "source_missing": source_missing,
        })

    for host in sorted(warned_hosts):
        short = host.split(".")[0]
        print(f"  [WARN] {short}: host group check skipped — "
              f"pass --host-iqn {short}=<IQN> (get via: cat /etc/iscsi/initiatorname.iscsi)",
              flush=True)

    all_nova_hosts = {item["nova_host"] for item in collected if item["nova_host"]}
    return findings, host_groups, host_iqn_map, all_nova_hosts


# ── Reporting ──────────────────────────────────────────────────────────────

def print_report(findings):
    if not findings:
        print("✓  No host group mapping issues detected.")
        return

    print(f"\n{'='*80}")
    print(f"ISSUES FOUND: {len(findings)}")
    print(f"{'='*80}")

    for f in findings:
        tags = []
        if f.get("dual_mapping"):     tags.append("DUAL HOST GROUP")
        elif f.get("source_missing"): tags.append("SOURCE MISSING")

        print(f"\n  [{' + '.join(tags) or 'UNKNOWN'}]")
        print(f"  VM       : {f['vm_name']} ({f['vm_id']})  status={f['vm_status']}")
        print(f"  Volume   : {f['volume_id']}")
        print(f"  LDEV ID  : {f['ldev_id']}")
        print(f"  Nova host: {f['nova_host']}")

        if f.get("dual_mapping"):
            total_paths = sum(len(m.get("paths", [])) for m in f["lun_maps"]) if isinstance(f["lun_maps"], list) else 0
            print(f"  LU paths : {len(f['lun_maps'])} mapping(s) across "
                  f"{len(f['nova_maps']) + len(f['stale_maps'])} host group(s)  "
                  f"← DUAL HOST GROUP (most common production failure)")
            for m in f.get("nova_maps", []):
                iqns  = m.get("hg_iqns", [])
                hosts = ", ".join(iqn_to_hostname(q) for q in iqns) or "(none)"
                ports = ", ".join(p["port_id"] for p in m.get("paths", []))
                print(f"    ✓ {m['hg_name']}  ports={ports}  IQN hosts: {hosts}  [correct]")
            for m in f.get("stale_maps", []):
                iqns  = m.get("hg_iqns", [])
                hosts = ", ".join(iqn_to_hostname(q) for q in iqns) or "(none)"
                ports = ", ".join(p["port_id"] for p in m.get("paths", []))
                print(f"    ✗ {m['hg_name']}  ports={ports}  IQN hosts: {hosts}  [stale — destination]")
        elif f.get("source_missing"):
            print(f"  LU paths : source host group mapping is MISSING")
            for m in f.get("stale_maps", []):
                iqns  = m.get("hg_iqns", [])
                hosts = ", ".join(iqn_to_hostname(q) for q in iqns) or "(none)"
                ports = ", ".join(p["port_id"] for p in m.get("paths", []))
                print(f"    ✗ {m['hg_name']}  ports={ports}  IQN hosts: {hosts}  [wrong host]")


# ── Remediation ────────────────────────────────────────────────────────────

def remediate(findings, host_groups, host_iqn_map, hitachi_host, hitachi_user, hitachi_password,
              storage_id, dry_run):
    if not findings:
        return

    prefix = "[DRY-RUN] " if dry_run else ""
    print(f"\n{'='*80}")
    print(f"{prefix}REMEDIATION")
    print(f"{'='*80}")
    print("Steps per finding:")
    print("  1. Fix Hitachi LU paths  (automated here — removes/adds per-port path entries)")
    print("  2. iSCSI rescan          (commands to run on the correct host)")
    print("  3. Nova BDM target_lun fix (SQL to run — review before applying)")
    print()

    by_vm = {}
    for f in findings:
        by_vm.setdefault(f["vm_id"], []).append(f)

    for vm_id, vm_findings in by_vm.items():
        first     = vm_findings[0]
        nova_host = first["nova_host"]
        nova_s    = nova_host.split(".")[0].lower()

        print(f"\n── {first['vm_name']} ({vm_id}) ──")
        print(f"   Nova host: {nova_host}")

        print(f"\n  STEP 1: Fix Hitachi LU paths")
        step1_ok = True

        for f in vm_findings:
            print(f"\n    Volume  : {f['volume_id']}")
            print(f"    LDEV ID : {f['ldev_id']}")
            if f["ldev_id"] is None:
                print(f"    (skip — LDEV not found on storage)")
                continue

            if f.get("dual_mapping"):
                for m in f["stale_maps"]:
                    for path_entry in m.get("paths", []):
                        ok = remove_lun_path_entry(
                            hitachi_host, hitachi_user, hitachi_password, storage_id,
                            path_entry["lun_id"], m["hg_name"], dry_run=dry_run,
                        )
                        if not ok:
                            step1_ok = False

                if f["nova_maps"]:
                    nm      = f["nova_maps"][0]
                    lun_ids = list({p.get("lun") for p in nm.get("paths", [])
                                    if p.get("lun") is not None})
                    if lun_ids:
                        print(f"    Correct LUN ID (nova host's mapping): {lun_ids[0]}"
                              f"  ← use this for BDM fix in Step 3")

            elif f.get("source_missing"):
                nova_hg_name, nova_hg_data = find_hg_for_host(nova_host, host_iqn_map, host_groups)

                if not nova_hg_name:
                    print(f"    [WARN] Cannot find host group for {nova_host} — "
                          f"IQN unknown. Pass --host-iqn {nova_s}=<IQN> or --ssh-user.")
                    print(f"    Get IQN: ssh {nova_host} 'cat /etc/iscsi/initiatorname.iscsi'")
                    step1_ok = False
                    continue

                # Add source mapping on each port first — worst case on partial failure
                # is DUAL HOST GROUP, not data loss.
                for port_id, port_data in nova_hg_data.get("ports", {}).items():
                    ok = add_lun_path_entry(
                        hitachi_host, hitachi_user, hitachi_password, storage_id,
                        port_id, port_data["hg_number"], f["ldev_id"], nova_hg_name,
                        dry_run=dry_run,
                    )
                    if not ok:
                        step1_ok = False

                if step1_ok or dry_run:
                    for m in f["stale_maps"]:
                        for path_entry in m.get("paths", []):
                            ok = remove_lun_path_entry(
                                hitachi_host, hitachi_user, hitachi_password, storage_id,
                                path_entry["lun_id"], m["hg_name"], dry_run=dry_run,
                            )
                            if not ok:
                                step1_ok = False

        if not step1_ok and not dry_run:
            print(f"\n  ✗ STEP 1 FAILED — manual Hitachi action required (see above).")
            print(f"    Re-run with --remediate after fixing manually.")
            continue

        print(f"\n  STEP 2: iSCSI rescan — run on {nova_host}:")
        print(f"    iscsiadm -m session -R")
        print(f"    iscsiadm -m node --login")
        print(f"    multipath -r")
        print(f"    multipath -ll | grep -E 'failed|faulty|0 paths'")

        print(f"\n  STEP 3: Nova BDM target_lun fix")
        any_dual    = any(f.get("dual_mapping")   for f in vm_findings)
        any_missing = any(f.get("source_missing") for f in vm_findings)

        if any_dual or any_missing:
            print(f"    # target_lun / target_luns in Nova BDM may point to the destination LUN ID.")
            print(f"    # First, check current values:")
            for f in vm_findings:
                print(f"    mysql> SELECT instance_uuid,")
                print(f"                  JSON_EXTRACT(connection_info, '$.data.target_lun')  AS lun,")
                print(f"                  JSON_EXTRACT(connection_info, '$.data.target_luns') AS luns")
                print(f"           FROM block_device_mapping")
                print(f"           WHERE volume_id = '{f['volume_id']}'")
                print(f"             AND instance_uuid = '{vm_id}'")
                print(f"             AND deleted = 0;")
            print()
            for f in vm_findings:
                if f.get("dual_mapping") and f["nova_maps"]:
                    nm      = f["nova_maps"][0]
                    lun_ids = list({p.get("lun") for p in nm.get("paths", [])
                                    if p.get("lun") is not None})
                    if lun_ids:
                        correct_lun_id = lun_ids[0]
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
                        print(f"    # Volume {f['volume_id']}: LUN ID unknown — check Hitachi and set manually")
        else:
            print(f"    # Host group was the only issue — no BDM change needed.")

    print(f"\n{'='*80}")
    print("After all steps, verify:")
    print("  virsh list --all           (on affected host — should not hang)")
    print("  multipath -ll              (no failed/faulty maps)")
    print("  openstack volume list      (volumes should be 'in-use')")
    print("  openstack server list      (VMs should be 'ACTIVE')")


# ── Entry point ────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Detect and remediate stale Cinder BDM/host-group state after failed migrations "
                    "(Hitachi VSP)"
    )
    parser.add_argument("--hitachi-host",      required=True,
                        help="Hitachi VSP management IP or hostname")
    parser.add_argument("--hitachi-user",      default="openstack",
                        help="Hitachi storage admin user (default: svol_admin)")
    parser.add_argument("--hitachi-password",  help="Prompted if omitted")
    parser.add_argument("--storage-device-id", default=None,
                        help="VSP storage device ID (auto-discovered if omitted)")
    parser.add_argument("--server",            help="Check a single VM by UUID or name")
    parser.add_argument("--ssh-user",          default=None,
                        help="SSH user for compute host health checks and IQN fetching")
    parser.add_argument("--ssh-key",           default=None, metavar="PATH",
                        help="SSH private key file (optional if default key works)")
    parser.add_argument("--host-iqn",          action="append", default=[], metavar="HOST=IQN",
                        help="Known IQN for a compute host, e.g. compute-1=iqn.xxx. Repeat per host.")
    parser.add_argument("--volume-ldev",       action="append", default=[], metavar="UUID=LDEV_ID",
                        help="Override LDEV ID for a Cinder volume when provider_location is not "
                             "visible, e.g. <volume-uuid>=105. Repeat per volume.")
    parser.add_argument("--dry-run",           action="store_true",
                        help="Preview all remediation steps without making changes")
    parser.add_argument("--remediate",         action="store_true",
                        help="Apply host-group LU path fixes and print iSCSI rescan + BDM SQL steps")
    parser.add_argument("--clean-mpath",       action="store_true",
                        help="Scan compute hosts for mpath devices with all paths failed and flush them. "
                             "Requires --ssh-user. Use with --dry-run to preview.")
    args = parser.parse_args()

    manual_iqns = {}
    for entry in args.host_iqn:
        if "=" not in entry:
            print(f"[ERROR] --host-iqn must be HOST=IQN format, got: {entry}", file=sys.stderr)
            sys.exit(1)
        h, iqn = entry.split("=", 1)
        manual_iqns[h.strip()] = iqn.strip()

    manual_ldevs = {}
    for entry in args.volume_ldev:
        if "=" not in entry:
            print(f"[ERROR] --volume-ldev must be UUID=LDEV_ID format, got: {entry}", file=sys.stderr)
            sys.exit(1)
        vol_uuid, ldev_str = entry.split("=", 1)
        try:
            manual_ldevs[vol_uuid.strip()] = int(ldev_str.strip())
        except ValueError:
            print(f"[ERROR] --volume-ldev LDEV_ID must be an integer, got: {ldev_str}", file=sys.stderr)
            sys.exit(1)

    if not args.hitachi_password:
        args.hitachi_password = getpass.getpass(
            f"Hitachi password for {args.hitachi_user}@{args.hitachi_host}: "
        )

    print("Querying OpenStack...")
    servers = [get_server(args.server)] if args.server else get_all_servers()
    print(f"Found {len(servers)} VM(s).")

    hyp_ip_map = get_hypervisor_ip_map()

    storage_id = args.storage_device_id or get_storage_device_id(
        args.hitachi_host, args.hitachi_user, args.hitachi_password
    )

    findings, host_groups, host_iqn_map, all_nova_hosts = detect(
        servers, args.hitachi_host, args.hitachi_user, args.hitachi_password, storage_id,
        ssh_user=args.ssh_user, ssh_key=args.ssh_key, hyp_ip_map=hyp_ip_map,
        manual_iqns=manual_iqns or None,
        manual_ldevs=manual_ldevs or None,
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
        remediate(findings, host_groups, host_iqn_map,
                  args.hitachi_host, args.hitachi_user, args.hitachi_password, storage_id,
                  dry_run=args.dry_run)
    elif findings:
        print("\nRun with --dry-run to preview remediation steps.")
        print("Run with --remediate to apply host-group fixes and print iSCSI/BDM steps.")

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
