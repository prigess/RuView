#!/usr/bin/env python3
"""
ruview-hrd — BLE Heart-Rate REST bridge for the RuView sensing pipeline.

    BLE HR strap/ring --0x180D--> ruview-ble-hr-decoder --MQTT--> [this] --REST:3027--> app
                                  (ruview-ble/hr/<mac>)

The Rust ruview-ble-hr-decoder GATT-subscribes to the standard Heart Rate
Service and republishes each frame to MQTT as JSON:

    { "mac": "..", "bpm": 62, "sensor_contact": "detected",
      "energy_expended_kj": 12, "rr_intervals_s": [0.83, 0.81],
      "seen_at": "2026-..T..Z" }

This bridge subscribes to `ruview-ble/hr/#`, keeps the freshest reading per
device, computes HRV (RMSSD, ms) from the RR-intervals, and serves it to the
thin iOS client — exactly the shape/role of ruview-audiod's :3025 surface.

    GET /api/v1/hr    latest HR + HRV + sensor-contact + liveness
    GET /health       liveness + stream state

Run on the Pi (systemd). Test anywhere with `--fake` (synthesises a strap,
no broker/BLE needed) to validate the REST contract the app depends on.
"""
import argparse, json, math, threading, time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MQTT_HOST   = "127.0.0.1"
MQTT_PORT   = 1883
MQTT_TOPIC  = "ruview-ble/hr/#"
REST_PORT   = 3027
FRESH_SEC   = 8.0     # reading older than this ⇒ stream "down"
RR_WINDOW_S = 30.0    # RR-interval history kept for HRV

# Per-device state: mac -> dict(bpm, sensor_contact, seen_at, recv_mono, rr deque)
_devices = {}
_lock = threading.Lock()


def _ingest(mac, bpm, sensor_contact, rr_intervals_s, seen_at):
    """Fold one decoded HR frame into per-device state (thread-safe)."""
    now = time.monotonic()
    with _lock:
        d = _devices.get(mac)
        if d is None:
            d = {"rr": deque()}   # rr: deque of (recv_mono, interval_seconds)
            _devices[mac] = d
        d["bpm"] = bpm
        d["sensor_contact"] = sensor_contact or "not_supported"
        d["seen_at"] = seen_at
        d["recv_mono"] = now
        for rr in (rr_intervals_s or []):
            if rr and rr > 0:
                d["rr"].append((now, float(rr)))
        # prune RR history to the window
        while d["rr"] and now - d["rr"][0][0] > RR_WINDOW_S:
            d["rr"].popleft()


def _rmssd_ms(rr_deque):
    """HRV as RMSSD in milliseconds over the RR-interval window (None if <2)."""
    rr = [v for _, v in rr_deque]
    if len(rr) < 2:
        return None
    diffs = [(rr[i] - rr[i - 1]) * 1000.0 for i in range(1, len(rr))]  # ms
    if not diffs:
        return None
    return round(math.sqrt(sum(d * d for d in diffs) / len(diffs)), 1)


def _snapshot():
    """Freshest device → the REST payload the app consumes."""
    now = time.monotonic()
    with _lock:
        if not _devices:
            return {"bpm": None, "hrv_ms": None, "sensor_contact": "not_supported",
                    "device": None, "age_sec": None, "rr_count": 0, "stream": "down",
                    "timestamp": None}
        mac, d = max(_devices.items(), key=lambda kv: kv[1].get("recv_mono", 0))
        age = now - d.get("recv_mono", 0)
        fresh = age <= FRESH_SEC
        return {
            "bpm": d.get("bpm") if fresh else None,
            "hrv_ms": _rmssd_ms(d["rr"]) if fresh else None,
            "sensor_contact": d.get("sensor_contact", "not_supported"),
            "device": mac,
            "age_sec": round(age, 1),
            "rr_count": len(d["rr"]),
            "stream": "up" if fresh else "down",
            "timestamp": d.get("seen_at"),
        }


# ── MQTT ─────────────────────────────────────────────────────────────────
def mqtt_loop(host, port):
    import paho.mqtt.client as mqtt

    def on_connect(c, u, flags, rc, *a):
        c.subscribe(MQTT_TOPIC)
        print(f"[hrd] mqtt connected {host}:{port} · sub {MQTT_TOPIC}")

    def on_message(c, u, msg):
        try:
            p = json.loads(msg.payload.decode())
        except Exception as e:
            print(f"[hrd] bad payload on {msg.topic}: {e}")
            return
        mac = p.get("mac") or msg.topic.rsplit("/", 1)[-1]
        _ingest(mac, p.get("bpm"), p.get("sensor_contact"),
                p.get("rr_intervals_s"), p.get("seen_at"))

    try:
        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    except Exception:
        c = mqtt.Client()   # older paho
    c.on_connect = on_connect
    c.on_message = on_message
    while True:
        try:
            c.connect(host, port, 60)
            c.loop_forever()
        except Exception as e:
            print(f"[hrd] mqtt reconnect in 5s: {e}")
            time.sleep(5)


def fake_loop():
    """Synthesise a strap so the REST contract can be tested without hardware."""
    print("[hrd] FAKE mode — synthesising a BLE HR strap")
    import random
    bpm = 64
    while True:
        bpm = max(48, min(96, bpm + random.randint(-2, 2)))
        rr = round(60.0 / bpm + random.uniform(-0.02, 0.02), 3)
        rr2 = round(60.0 / bpm + random.uniform(-0.02, 0.02), 3)
        _ingest("fa:ke:00:00:00:01", bpm, "detected", [rr, rr2],
                time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()))
        time.sleep(1.0)


# ── REST ─────────────────────────────────────────────────────────────────
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.startswith("/api/v1/hr"):
            body = json.dumps(_snapshot()).encode()
        elif self.path.startswith("/health"):
            snap = _snapshot()
            body = json.dumps({"status": "ok", "stream": snap["stream"],
                               "devices": len(_devices)}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    ap = argparse.ArgumentParser(description="RuView BLE Heart-Rate REST bridge")
    ap.add_argument("--mqtt-host", default=MQTT_HOST)
    ap.add_argument("--mqtt-port", type=int, default=MQTT_PORT)
    ap.add_argument("--rest-port", type=int, default=REST_PORT)
    ap.add_argument("--fake", action="store_true",
                    help="synthesise a strap instead of subscribing to MQTT (testing)")
    args = ap.parse_args()

    src = fake_loop if args.fake else (lambda: mqtt_loop(args.mqtt_host, args.mqtt_port))
    threading.Thread(target=src, daemon=True).start()
    print(f"[hrd] REST on :{args.rest_port}  (GET /api/v1/hr, /health)")
    ThreadingHTTPServer(("0.0.0.0", args.rest_port), H).serve_forever()


if __name__ == "__main__":
    main()
