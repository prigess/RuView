#!/usr/bin/env python3
"""
ruview-countd — REST bridge for the CSI person-count CNN.

    ESP32 CSI -> ruview-sensing (:3022) -> cog-person-count (Candle CNN)
                                            └─ person.count on stdout
                                               └─ [this] --REST:3028--> app

The `cog-person-count` cog prints one `person.count` JSON event per inference
to stdout. This bridge SUPERVISES it (spawns the subprocess, restarts it on
exit), parses those events, keeps the freshest count, and serves it to the
thin iOS client — the same role ruview-hrd/ruview-audiod play for their cogs.

    GET /api/v1/count   latest model count + confidence + liveness
    GET /health         liveness + stream state

Idle (`stream:"down"`) until CSI is flowing — the cog only emits person.count
when the sensing-server returns real CSI nodes. Pure stdlib.

    ruview-countd                       # supervise the real cog + serve
    ruview-countd --fake                # synthesise counts (no model/CSI)
"""
import argparse, json, subprocess, threading, time, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COG_BIN = "/usr/local/bin/cog-person-count"
COG_CFG = "/etc/ruview/cog-count.json"
REST_PORT = 3028
FRESH_SEC = 6.0

_state = {"count": None, "confidence": None, "p95_low": None, "p95_high": None,
          "tick": None, "recv_mono": 0.0, "ts": None}
_lock = threading.Lock()


def _ingest(fields, ts):
    with _lock:
        _state.update({
            "count": fields.get("count"),
            "confidence": fields.get("confidence"),
            "p95_low": fields.get("count_p95_low"),
            "p95_high": fields.get("count_p95_high"),
            "tick": fields.get("tick"),
            "recv_mono": time.monotonic(),
            "ts": ts,
        })


def _snapshot():
    now = time.monotonic()
    with _lock:
        age = now - _state["recv_mono"] if _state["recv_mono"] else None
        fresh = age is not None and age <= FRESH_SEC
        return {
            "count": _state["count"] if fresh else None,
            "confidence": _state["confidence"] if fresh else None,
            "p95_low": _state["p95_low"] if fresh else None,
            "p95_high": _state["p95_high"] if fresh else None,
            "tick": _state["tick"],
            "age_sec": round(age, 1) if age is not None else None,
            "stream": "up" if fresh else "down",
            "source": "csi-cnn",
            "timestamp": _state["ts"],
        }


def supervise(cog_bin, cog_cfg):
    """Spawn the cog, read its stdout person.count events, restart on exit."""
    while True:
        try:
            proc = subprocess.Popen(
                [cog_bin, "run", "--config", cog_cfg],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
            print(f"[countd] spawned {cog_bin} (pid {proc.pid})")
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if ev.get("event") == "person.count":
                    _ingest(ev.get("fields", {}), ev.get("ts"))
            proc.wait()
            print(f"[countd] cog exited ({proc.returncode}); restart in 5s")
        except FileNotFoundError:
            print(f"[countd] cog binary not found at {cog_bin}; retry in 10s")
            time.sleep(10)
            continue
        time.sleep(5)


def fake_loop():
    print("[countd] FAKE mode — synthesising counts")
    import itertools
    for c in itertools.cycle([0, 1, 1, 1, 2, 1, 0]):
        _ingest({"count": c, "confidence": 0.8, "count_p95_low": max(0, c - 1),
                 "count_p95_high": c + 1, "tick": int(time.monotonic())},
                time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()))
        time.sleep(1.5)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.startswith("/api/v1/count"):
            body = json.dumps(_snapshot()).encode()
        elif self.path.startswith("/health"):
            snap = _snapshot()
            body = json.dumps({"status": "ok", "stream": snap["stream"],
                               "source": "csi-cnn"}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    ap = argparse.ArgumentParser(description="RuView CSI person-count REST bridge")
    ap.add_argument("--cog-bin", default=COG_BIN)
    ap.add_argument("--cog-config", default=COG_CFG)
    ap.add_argument("--rest-port", type=int, default=REST_PORT)
    ap.add_argument("--fake", action="store_true")
    args = ap.parse_args()
    src = fake_loop if args.fake else (lambda: supervise(args.cog_bin, args.cog_config))
    threading.Thread(target=src, daemon=True).start()
    print(f"[countd] REST on :{args.rest_port}  (GET /api/v1/count, /health)")
    ThreadingHTTPServer(("0.0.0.0", args.rest_port), H).serve_forever()


if __name__ == "__main__":
    main()
