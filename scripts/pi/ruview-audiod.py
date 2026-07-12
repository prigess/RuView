#!/usr/bin/env python3
"""ruview-audiod — Orange Pi audio-inference daemon.

Receives raw PCM audio streamed over UDP from the ESP32-S3 + INMP441 room mic,
runs sound-event inference (YAMNet on the NPU — stubbed as a level/energy
detector until the model is wired), FUSES the result with live radar telemetry
(from the sensing-server), and exposes the fused result over REST for the app.

  ESP32  --UDP:5006 PCM16 16kHz mono-->  [this]  --REST:3025-->  iOS app

REST:
  GET /api/v1/audio    latest audio inference + radar-fused interpretation
  GET /health          liveness

Design notes:
  - Pure stdlib (numpy only) so it runs on the Pi with no extra installs.
  - Inference is pluggable: `infer(frame)` is where YAMNet/RKNN drops in.
  - Fusion reads the sensing-server's edge-vitals so "crying" becomes
    "crying + someone present + not moving = possible distress".
"""
import socket, threading, time, json, struct, urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import numpy as np

UDP_PORT = 5006          # raw PCM in from the ESP32
REST_PORT = 3025         # fused result out to the app
SAMPLE_RATE = 16000
WINDOW_SEC = 1.0
SENSING = "http://127.0.0.1:3022/api/v1/edge-vitals"

_buf = deque(maxlen=int(SAMPLE_RATE * 2))   # ~2s ring of int16 samples
_lock = threading.Lock()
_last_packet_at = [0.0]
_state = {"ts": 0.0, "level_db": None, "active": False, "events": [],
          "fused": "idle", "radar_present": None, "stream": "down"}

# ── UDP receiver ────────────────────────────────────────────────────────────
def udp_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", UDP_PORT))
    print(f"[audiod] UDP listening :{UDP_PORT}")
    while True:
        data, _ = s.recvfrom(4096)
        # Expect little-endian int16 PCM. (A tiny header can be added later.)
        n = len(data) // 2
        if n == 0:
            continue
        samples = struct.unpack("<%dh" % n, data[: n * 2])
        with _lock:
            _buf.extend(samples)
        _last_packet_at[0] = time.monotonic()

# ── Inference (STUB → YAMNet/RKNN goes here) ────────────────────────────────
def infer():
    with _lock:
        if len(_buf) < int(SAMPLE_RATE * WINDOW_SEC):
            return None
        arr = np.array(_buf, dtype=np.float32)[-int(SAMPLE_RATE * WINDOW_SEC):]
    arr /= 32768.0
    rms = float(np.sqrt(np.mean(arr * arr)) + 1e-9)
    level_db = float(20.0 * np.log10(rms))
    active = bool(level_db > -45.0)
    # TODO: replace with YAMNet top-k classes; for now a coarse loud-event event.
    events = []
    if level_db > -20.0:
        events = [{"label": "loud_sound", "score": round(min(1.0, (level_db + 40) / 40), 2)}]
    return {"level_db": round(level_db, 1), "active": active, "events": events}

# ── Fusion with radar telemetry ─────────────────────────────────────────────
def radar_present():
    try:
        with urllib.request.urlopen(SENSING, timeout=0.5) as r:
            ev = json.load(r).get("edge_vitals") or {}
            return bool(ev.get("presence"))
    except Exception:
        return None

def fuse(audio, present):
    if audio is None:
        return "idle"
    labels = {e["label"] for e in audio["events"]}
    if "crying" in labels and present:
        return "possible_distress"
    if "loud_sound" in labels and present is False:
        return "loud_event_no_one_present"
    if "loud_sound" in labels:
        return "loud_event"
    if audio["active"] and present:
        return "activity"
    return "quiet"

def infer_loop():
    while True:
        stream_up = (time.monotonic() - _last_packet_at[0]) < 2.0 if _last_packet_at[0] else False
        audio = infer() if stream_up else None   # don't infer on a stale buffer
        present = radar_present()
        _state.update({
            "ts": time.time(),
            "level_db": audio["level_db"] if audio else None,
            "active": audio["active"] if audio else False,
            "events": audio["events"] if audio else [],
            "radar_present": present,
            "fused": fuse(audio, present),
            "stream": "up" if stream_up else "down",
        })
        time.sleep(0.25)

# ── REST ────────────────────────────────────────────────────────────────────
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v1/audio"):
            body = json.dumps(_state).encode()
        elif self.path.startswith("/health"):
            body = json.dumps({"status": "ok", "stream": _state["stream"]}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def main():
    threading.Thread(target=udp_loop, daemon=True).start()
    threading.Thread(target=infer_loop, daemon=True).start()
    print(f"[audiod] REST on :{REST_PORT}")
    ThreadingHTTPServer(("0.0.0.0", REST_PORT), H).serve_forever()

if __name__ == "__main__":
    main()
