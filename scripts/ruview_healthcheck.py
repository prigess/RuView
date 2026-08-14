#!/usr/bin/env python3
"""RuView sensing-stack health check + sensor auto-detection.

Codifies the manual verification done by hand: every sensor/server API is
probed, the Orange Pi's performance + NPU are asserted healthy, and — most
usefully — each ESP32-S3's radar is *auto-detected* so a firmware/radar
mismatch (the "Max command length exceeded" failure) is caught automatically
instead of by eye.

Two entry points:

    # 1) Auto-detect map (no asserts) — prints which radar is on which board:
    python3 scripts/ruview_healthcheck.py detect

    # 2) Unit tests (stdlib unittest — no pytest/requests needed):
    python3 -m unittest scripts.ruview_healthcheck -v
    #   or:  python3 scripts/ruview_healthcheck.py

Config via env (all optional; defaults = Firefly deployment):
    RUVIEW_PI_HOST      Pi/BlueStar IP           (default 192.168.7.221)
    RUVIEW_LD2450_IP    LD2450 node IP           (default 192.168.7.254)
    RUVIEW_LD2410C_IP   LD2410C node IP          (default 192.168.7.229)
    RUVIEW_C6_IP        C6/MR60BHA2 node IP      (default 192.168.7.223)
    RUVIEW_PI_PASS      Pi SSH password          (Pi-health tests SKIP if unset)

Security: no credentials are hard-coded. Pi-health tests are skipped unless
RUVIEW_PI_PASS is provided in the environment.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import unittest
import urllib.request

# ── Config ───────────────────────────────────────────────────────────────────
PI_HOST = os.environ.get("RUVIEW_PI_HOST", "192.168.7.221")
PI_PASS = os.environ.get("RUVIEW_PI_PASS")  # None -> Pi tests skipped

RADAR_NODES = {
    "LD2450":  os.environ.get("RUVIEW_LD2450_IP",  "192.168.7.254"),
    "LD2410C": os.environ.get("RUVIEW_LD2410C_IP", "192.168.7.229"),
    "C6":      os.environ.get("RUVIEW_C6_IP",       "192.168.7.223"),
}

# The MIC (INMP441) runs ESP-IDF firmware with NO web server — it can't be
# probed like the ESPHome radars. It streams raw audio over UDP to the Pi's
# audiod, so its liveness is read from audiod's stream status instead.
MIC_IP  = os.environ.get("RUVIEW_MIC_IP",  "192.168.7.228")
MIC_MAC = os.environ.get("RUVIEW_MIC_MAC", "e0:72:a1:fc:db:78")

HTTP_TIMEOUT = 4.0

# Thermal / load ceilings for the Pi (RK3588S, 8 cores).
MAX_LOAD_AVG = 8.0        # 1-min load should stay under core count
MIN_AVAIL_MB = 512        # keep at least this much RAM available
MAX_TEMP_C   = 85.0       # RK3588 throttles ~95C; flag well before

# ── HTTP helpers (stdlib only) ───────────────────────────────────────────────
def http_get(url: str):
    """Return (status_code, body_text). status_code None on connection error."""
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        code = e.code
        e.close()
        return code, ""
    except Exception:
        return None, ""


def esphome_state(ip: str, path: str):
    """GET an ESPHome web_server entity; return (exists, state_str_or_None).

    exists  = the entity is present in the running firmware.
    state   = its reported state (may be 'NA' when no valid reading).
    """
    status, body = http_get(f"http://{ip}/{path}")
    if status != 200 or '"id"' not in body:
        return False, None
    try:
        state = json.loads(body).get("state")
    except json.JSONDecodeError:
        m = re.search(r'"state":"?([^",}]*)', body)
        state = m.group(1) if m else None
    return True, state


def _is_number(state) -> bool:
    """True if the ESPHome state carries a real numeric reading (incl. 0).

    A correctly-paired radar reports a number even when idle (e.g. count 0);
    a mismatched radar reports 'NA' / '' because the parser can't frame the
    other radar's bytes. This is the occupancy-independent pairing signal.
    """
    if state is None:
        return False
    m = re.search(r"-?\d+(\.\d+)?", str(state))
    return m is not None and str(state).strip().upper() != "NA"


# ── Auto-detection ───────────────────────────────────────────────────────────
# Each radar firmware exposes a signature entity set + a primary data sensor.
RADAR_SIGNATURES = [
    # name,      firmware-signature entities (all must exist),      primary sensor
    ("LD2450",  ["sensor/Target%20Count", "sensor/Target%201%20X"], "sensor/Target%20Count"),
    ("LD2410C", ["sensor/Detection%20Distance",
                 "sensor/Moving%20Target%20Energy"],                 "sensor/Detection%20Distance"),
    ("C6",      ["sensor/heart_rate", "sensor/breath_rate"],         "sensor/heart_rate"),
]


def detect_node(ip: str) -> dict:
    """Auto-detect a node: loaded firmware, physical-radar match, MAC.

    Returns dict: {ip, reachable, firmware, primary_state, paired_ok, mac}.
      firmware   = radar firmware flashed on the ESP ('LD2450'/'LD2410C'/'C6'/None)
      paired_ok  = True when the primary sensor carries real data (radar matches
                   firmware); False => mismatch / no data (the failure we hit).
    """
    exists_mac, mac = esphome_state(ip, "text_sensor/MAC%20Address")
    result = {
        "ip": ip, "reachable": exists_mac, "firmware": None,
        "primary_state": None, "paired_ok": False, "mac": mac,
    }
    if not exists_mac:
        # No ESPHome web server -> could be the ESP-IDF mic or offline.
        return result

    for name, sig_entities, primary in RADAR_SIGNATURES:
        if all(esphome_state(ip, e)[0] for e in sig_entities):
            result["firmware"] = name
            _, state = esphome_state(ip, primary)
            result["primary_state"] = state
            result["paired_ok"] = _is_number(state)
            break
    return result


def detect_mic() -> dict:
    """Auto-detect the MIC via audiod stream status (no web server on the board).

    Returns {ip, mac, reachable, streaming, level_db, source}.
      reachable = ARP shows the mic on the LAN (best-effort; local-net only)
      streaming = audiod reports the UDP audio stream is up + active
    """
    status, body = http_get(f"http://{PI_HOST}:3025/api/v1/audio")
    streaming, level_db = False, None
    if status == 200:
        try:
            data = json.loads(body)
            streaming = data.get("stream") == "up" and bool(data.get("active"))
            level_db = data.get("level_db")
        except json.JSONDecodeError:
            pass
    # ARP presence is a best-effort local-network signal (empty when run remotely).
    try:
        arp = subprocess.run(["arp", "-an"], capture_output=True, text=True, timeout=4).stdout
        reachable = MIC_MAC.lower() in arp.lower()
    except Exception:
        reachable = False
    return {"ip": MIC_IP, "mac": MIC_MAC, "reachable": reachable,
            "streaming": streaming, "level_db": level_db, "source": "audiod:3025"}


def detect_all() -> dict:
    out = {label: detect_node(ip) for label, ip in RADAR_NODES.items()}
    out["MIC"] = detect_mic()
    return out


# ── SSH helper for Pi-health ─────────────────────────────────────────────────
def ssh_pi(remote_cmd: str, timeout: int = 10):
    """Run a command on the Pi via sshpass+ssh. Returns (rc, stdout)."""
    if not PI_PASS or not shutil.which("sshpass"):
        return None, ""
    cmd = [
        "sshpass", "-p", PI_PASS, "ssh",
        "-o", "ConnectTimeout=6", "-o", "StrictHostKeyChecking=accept-new",
        f"orangepi@{PI_HOST}", remote_cmd,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return None, ""


# ═══════════════════════════════════════════════════════════════════════════
#  TEST SUITE 1 — APIs (direct sensors + Pi server)
# ═══════════════════════════════════════════════════════════════════════════
class TestDirectSensorAPIs(unittest.TestCase):
    """Every ESPHome node answers its web API with a valid schema."""

    def test_ld2450_target_count_is_numeric(self):
        exists, state = esphome_state(RADAR_NODES["LD2450"], "sensor/Target%20Count")
        self.assertTrue(exists, "LD2450 Target Count entity missing (wrong firmware?)")
        self.assertTrue(_is_number(state),
                        f"LD2450 Target Count not numeric: {state!r} "
                        "(radar/firmware mismatch — see TestSensorPairing)")

    def test_ld2410c_detection_distance_is_numeric(self):
        exists, state = esphome_state(RADAR_NODES["LD2410C"], "sensor/Detection%20Distance")
        self.assertTrue(exists, "LD2410C Detection Distance entity missing")
        self.assertTrue(_is_number(state),
                        f"LD2410C Detection Distance not numeric: {state!r}")

    def test_c6_vitals_endpoints_present(self):
        for path in ("sensor/heart_rate", "sensor/breath_rate",
                     "binary_sensor/person_present"):
            exists, _ = esphome_state(RADAR_NODES["C6"], path)
            self.assertTrue(exists, f"C6 endpoint missing: {path}")


class TestPiServerAPIs(unittest.TestCase):
    """The sensing-server + audiod REST contracts hold."""

    def test_health_ok(self):
        status, body = http_get(f"http://{PI_HOST}:3022/health")
        self.assertEqual(status, 200, "sensing-server /health unreachable")
        self.assertEqual(json.loads(body).get("status"), "ok")

    def test_nodes_endpoint_shape(self):
        status, body = http_get(f"http://{PI_HOST}:3022/api/v1/nodes")
        self.assertEqual(status, 200)
        data = json.loads(body)
        self.assertIn("nodes", data)
        self.assertIsInstance(data["nodes"], list)
        for n in data["nodes"]:
            self.assertIn("node_id", n)
            self.assertIn("radar_type", n)

    def test_zones_summary_shape(self):
        status, body = http_get(f"http://{PI_HOST}:3022/api/v1/pose/zones/summary")
        self.assertEqual(status, 200)
        self.assertIn("zones", json.loads(body))

    def test_audio_inference_contract(self):
        status, body = http_get(f"http://{PI_HOST}:3025/api/v1/audio")
        self.assertEqual(status, 200, "audiod :3025 unreachable")
        data = json.loads(body)
        self.assertIn("level_db", data)
        self.assertIsInstance(data["level_db"], (int, float))


# ═══════════════════════════════════════════════════════════════════════════
#  TEST SUITE 2 — Sensor pairing auto-detect (the tonight's-bug guard)
# ═══════════════════════════════════════════════════════════════════════════
class TestSensorPairing(unittest.TestCase):
    """Auto-detect each board's radar and assert firmware matches the radar."""

    def test_each_radar_firmware_matches_physical_radar(self):
        for expected, ip in RADAR_NODES.items():
            with self.subTest(node=expected, ip=ip):
                d = detect_node(ip)
                self.assertTrue(d["reachable"], f"{expected} @ {ip} unreachable")
                self.assertEqual(
                    d["firmware"], expected,
                    f"{ip}: firmware is {d['firmware']}, expected {expected}")
                self.assertTrue(
                    d["paired_ok"],
                    f"{ip}: {d['firmware']} firmware but primary sensor = "
                    f"{d['primary_state']!r} -> radar/firmware MISMATCH")

    def test_mic_streaming_to_audiod(self):
        d = detect_mic()
        self.assertTrue(
            d["streaming"],
            f"MIC {d['ip']}: audiod reports stream down/inactive "
            f"(level_db={d['level_db']})")


# ═══════════════════════════════════════════════════════════════════════════
#  TEST SUITE 3 — Orange Pi performance + NPU
# ═══════════════════════════════════════════════════════════════════════════
@unittest.skipUnless(PI_PASS and shutil.which("sshpass"),
                     "RUVIEW_PI_PASS unset or sshpass missing — Pi-health skipped")
class TestOrangePiHealth(unittest.TestCase):

    def test_load_average_under_core_count(self):
        rc, out = ssh_pi("cat /proc/loadavg")
        self.assertEqual(rc, 0, "cannot read /proc/loadavg over SSH")
        load1 = float(out.split()[0])
        self.assertLess(load1, MAX_LOAD_AVG, f"1-min load {load1} too high")

    def test_memory_available(self):
        rc, out = ssh_pi("grep MemAvailable /proc/meminfo")
        self.assertEqual(rc, 0)
        avail_mb = int(re.search(r"(\d+)", out).group(1)) // 1024
        self.assertGreater(avail_mb, MIN_AVAIL_MB, f"only {avail_mb}MB available")

    def test_thermal_under_ceiling(self):
        rc, out = ssh_pi("cat /sys/class/thermal/thermal_zone*/temp")
        self.assertEqual(rc, 0)
        temps = [int(t) / 1000.0 for t in out.split() if t.strip().isdigit()]
        self.assertTrue(temps, "no thermal zones readable")
        self.assertLess(max(temps), MAX_TEMP_C, f"max temp {max(temps)}C")

    def test_npu_runtime_and_driver_present(self):
        rc, out = ssh_pi(
            "ls /usr/lib/librknnrt.so 2>/dev/null; "
            "ls -d /sys/class/devfreq/*npu* 2>/dev/null")
        self.assertEqual(rc, 0)
        self.assertIn("librknnrt.so", out, "RKNN runtime not installed")
        self.assertIn("npu", out, "NPU devfreq node not present (driver down?)")


# ── CLI: auto-detect map ─────────────────────────────────────────────────────
def _print_detect_map():
    print(f"RuView sensor auto-detection (Pi={PI_HOST})\n" + "=" * 58)
    data = detect_all()
    for label in ("LD2450", "LD2410C", "C6"):
        d = data[label]
        if not d["reachable"]:
            print(f"  {label:8} {d['ip']:16} UNREACHABLE")
            continue
        verdict = "OK" if d["paired_ok"] else "MISMATCH/NO-DATA"
        print(f"  {label:8} {d['ip']:16} mac={d['mac']}")
        print(f"           firmware={d['firmware']}  primary={d['primary_state']!r}"
              f"  pairing={verdict}")
    m = data["MIC"]
    print(f"  {'MIC':8} {m['ip']:16} mac={m['mac']}")
    print(f"           firmware=esp32-audio-streamer (UDP, no web)  "
          f"stream={'up' if m['streaming'] else 'DOWN'}  level_db={m['level_db']}"
          f"  arp={'seen' if m['reachable'] else 'n/a'}")
    print("=" * 58)
    print("A MISMATCH means the ESP runs the wrong radar's firmware "
          "(Max-command-length failure).")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "detect":
        _print_detect_map()
    else:
        unittest.main(argv=[sys.argv[0], "-v"])
