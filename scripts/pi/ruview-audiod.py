#!/usr/bin/env python3
"""ruview-audiod — Orange Pi audio-inference daemon.

ESP32-S3 + INMP441  --UDP:5006 PCM16 16kHz mono-->  [this]  --REST:3025-->  app

Receives raw PCM streamed from the room mic, runs YAMNet sound-event
classification (tflite), FUSES the labels with live radar telemetry, and
exposes the fused result over REST for the (thin) iOS app.

REST:
  GET /api/v1/audio    latest sound-event labels + radar-fused interpretation
  GET /health          liveness + stream state

Run under the pinned venv: /opt/ruview/audiod-venv/bin/python
"""
import socket, threading, time, json, struct, urllib.request, csv
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import numpy as np

UDP_PORT = 5006
REST_PORT = 3025
SAMPLE_RATE = 16000
SENSING = "http://127.0.0.1:3022/api/v1/edge-vitals"
YAMNET = "/opt/ruview/models/yamnet.tflite"
CLASSMAP = "/opt/ruview/models/yamnet_class_map.csv"
SCORE_MIN = 0.20

_buf = deque(maxlen=SAMPLE_RATE * 2)
_lock = threading.Lock()
_last_packet_at = [0.0]
_state = {"ts": 0.0, "level_db": None, "active": False, "events": [],
          "fused": "idle", "radar_present": None, "stream": "down"}

# ── YAMNet ──────────────────────────────────────────────────────────────────
_interp = None; _labels = []; _in_idx = None; _out_idx = None; _in_len = 15600
def load_model():
    global _interp, _labels, _in_idx, _out_idx, _in_len
    try:
        from tflite_runtime.interpreter import Interpreter
        _interp = Interpreter(YAMNET); _interp.allocate_tensors()
        i, o = _interp.get_input_details()[0], _interp.get_output_details()[0]
        _in_idx, _out_idx, _in_len = i["index"], o["index"], int(i["shape"][-1])
        _labels = [r[2] for r in list(csv.reader(open(CLASSMAP)))[1:]]
        print(f"[audiod] YAMNet loaded: {len(_labels)} classes, in_len={_in_len}")
    except Exception as e:
        print(f"[audiod] YAMNet unavailable ({e}); level-only mode")

def classify(arr):
    if _interp is None:
        return []
    x = arr[-_in_len:]
    if len(x) < _in_len:
        x = np.pad(x, (_in_len - len(x), 0))
    _interp.set_tensor(_in_idx, x.astype(np.float32))
    _interp.invoke()
    scores = _interp.get_tensor(_out_idx)[0]
    top = scores.argsort()[-6:][::-1]
    return [{"label": _labels[i], "score": round(float(scores[i]), 2)}
            for i in top if scores[i] >= SCORE_MIN]

# ── UDP receiver ────────────────────────────────────────────────────────────
def udp_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", UDP_PORT))
    print(f"[audiod] UDP listening :{UDP_PORT}")
    while True:
        data, _ = s.recvfrom(4096)
        n = len(data) // 2
        if n:
            with _lock:
                _buf.extend(struct.unpack("<%dh" % n, data[: n * 2]))
            _last_packet_at[0] = time.monotonic()

# ── Inference ───────────────────────────────────────────────────────────────
def infer():
    with _lock:
        if len(_buf) < _in_len:
            return None
        arr = np.array(_buf, dtype=np.float32)[-_in_len:]
    arr /= 32768.0
    rms = float(np.sqrt(np.mean(arr * arr)) + 1e-9)
    level_db = float(20.0 * np.log10(rms))
    return {"level_db": round(level_db, 1),
            "active": bool(level_db > -45.0),
            "events": classify(arr)}

# ── Fusion with radar telemetry ─────────────────────────────────────────────
DISTRESS = {"Crying, sobbing", "Baby cry, infant cry", "Whimper", "Wail, moan",
            "Screaming", "Shout", "Yell", "Groan", "Gasp"}
SPEECH = {"Speech", "Conversation", "Narration, monologue", "Child speech, kid speaking"}
MEDIA = {"Music", "Television", "Radio", "Musical instrument", "Singing"}
ALARM = {"Glass", "Shatter", "Alarm", "Smoke detector, smoke alarm", "Thump, thud"}

LD2410_PRESENCE = "http://192.168.7.153/binary_sensor/person_present"
def radar_present():
    # Primary presence source = LD2410C (per the fusion ladder); edge-vitals fallback.
    try:
        with urllib.request.urlopen(LD2410_PRESENCE, timeout=0.4) as r:
            v = json.load(r).get("value")
            if v is not None:
                return bool(v)
    except Exception:
        pass
    try:
        with urllib.request.urlopen(SENSING, timeout=0.4) as r:
            return bool((json.load(r).get("edge_vitals") or {}).get("presence"))
    except Exception:
        return None

def fuse(audio, present):
    if audio is None:
        return "idle"
    labels = {e["label"] for e in audio["events"]}
    # The cross-modal value: the same sound means different things given presence.
    if labels & DISTRESS:
        return "distress_present" if present else "distress_sound"
    if labels & ALARM:
        return "alarm_sound"
    if labels & SPEECH:
        return "conversation" if present else "tv_or_media"      # speech + nobody = TV
    if labels & MEDIA:
        return "media_playing"
    if audio["active"] and present:
        return "activity"
    return "quiet"

def infer_loop():
    while True:
        up = (time.monotonic() - _last_packet_at[0]) < 2.0 if _last_packet_at[0] else False
        audio = infer() if up else None
        present = radar_present()
        _state.update({
            "ts": time.time(),
            "level_db": audio["level_db"] if audio else None,
            "active": audio["active"] if audio else False,
            "events": audio["events"] if audio else [],
            "radar_present": present,
            "fused": fuse(audio, present),
            "stream": "up" if up else "down",
        })
        time.sleep(0.3)

# ── REST ────────────────────────────────────────────────────────────────────
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v1/audio"):
            body = json.dumps(_state).encode()
        elif self.path.startswith("/health"):
            body = json.dumps({"status": "ok", "stream": _state["stream"],
                               "model": "yamnet" if _interp else "level-only"}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def main():
    load_model()
    threading.Thread(target=udp_loop, daemon=True).start()
    threading.Thread(target=infer_loop, daemon=True).start()
    print(f"[audiod] REST on :{REST_PORT}")
    ThreadingHTTPServer(("0.0.0.0", REST_PORT), H).serve_forever()

if __name__ == "__main__":
    main()
