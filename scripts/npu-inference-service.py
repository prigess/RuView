#!/usr/bin/env python3
"""
RuView NPU Inference Service for Orange Pi 5 Pro

Runs as a sidecar to the main sensing-server, providing NPU-accelerated
inference for presence detection and activity classification.

Usage:
    python3 npu-inference-service.py --port 3024

API Endpoints:
    POST /infer - Run inference on CSI features
    GET /health - Health check
    GET /stats - Inference statistics
"""

import argparse
import json
import time
import threading
import numpy as np
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import deque

# Global state
rknn = None
model_loaded = False
inference_times = deque(maxlen=100)
inference_count = 0
lock = threading.Lock()

# Model configuration
MODEL_PATH = "/opt/ruview/models/presence_detector.rknn"
FALLBACK_MODEL = "/tmp/resnet18_rk3588.rknn"  # For demo
INPUT_SHAPE = (1, 224, 224, 3)  # ResNet18 shape for demo


class InferenceHandler(BaseHTTPRequestHandler):
    """HTTP request handler for NPU inference."""

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass

    def _send_json(self, data, status=200):
        """Send JSON response."""
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        """Handle GET requests."""
        if self.path == "/health":
            self._send_json({
                "status": "ok",
                "model_loaded": model_loaded,
                "npu_available": rknn is not None
            })
        elif self.path == "/stats":
            with lock:
                times = list(inference_times)
            avg_ms = np.mean(times) if times else 0
            self._send_json({
                "inference_count": inference_count,
                "avg_latency_ms": round(avg_ms, 2),
                "min_latency_ms": round(min(times), 2) if times else 0,
                "max_latency_ms": round(max(times), 2) if times else 0,
                "model_loaded": model_loaded
            })
        else:
            self._send_json({"error": "Not found"}, 404)

    def do_POST(self):
        """Handle POST requests."""
        global inference_count

        if self.path == "/infer":
            if not model_loaded:
                self._send_json({"error": "Model not loaded"}, 503)
                return

            # Read request body
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)

            try:
                data = json.loads(body)
                features = data.get("features", [])

                # Convert to numpy array and reshape for model
                # For demo, we'll create a dummy image input from CSI features
                if len(features) < 56:
                    features = features + [0] * (56 - len(features))
                features = np.array(features[:224*224*3] if len(features) >= 224*224*3
                                    else features + [0] * (224*224*3 - len(features)))
                input_data = features.reshape(INPUT_SHAPE).astype(np.uint8)

                # Run inference
                start = time.time()
                with lock:
                    outputs = rknn.inference(inputs=[input_data])
                latency_ms = (time.time() - start) * 1000

                with lock:
                    inference_times.append(latency_ms)
                    inference_count += 1

                # Process output (softmax probabilities for ResNet18)
                probs = outputs[0].flatten()
                # Map top classes to presence states (demo mapping)
                # In production, use a custom-trained presence model
                presence_score = float(np.max(probs))
                top_class = int(np.argmax(probs))

                # Simple heuristic: high confidence = detected
                presence = "detected" if presence_score > 0.3 else "absent"
                motion = "moving" if top_class % 2 == 0 else "still"

                self._send_json({
                    "presence": presence,
                    "motion": motion,
                    "confidence": round(presence_score, 3),
                    "latency_ms": round(latency_ms, 2),
                    "class_id": top_class
                })

            except Exception as e:
                self._send_json({"error": str(e)}, 500)
        else:
            self._send_json({"error": "Not found"}, 404)


def load_model(model_path):
    """Load RKNN model."""
    global rknn, model_loaded

    try:
        from rknnlite.api import RKNNLite
    except ImportError:
        print("ERROR: rknn-toolkit-lite2 not installed")
        return False

    print(f"Loading model: {model_path}")
    rknn = RKNNLite(verbose=False)

    # Try primary model, fallback to demo model
    import os
    if not os.path.exists(model_path):
        print(f"  Model not found, using fallback: {FALLBACK_MODEL}")
        model_path = FALLBACK_MODEL

    if not os.path.exists(model_path):
        print("ERROR: No model file found")
        return False

    ret = rknn.load_rknn(model_path)
    if ret != 0:
        print(f"ERROR: load_rknn failed: {ret}")
        return False

    # Initialize with all 3 NPU cores
    ret = rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0_1_2)
    if ret != 0:
        print(f"ERROR: init_runtime failed: {ret}")
        return False

    model_loaded = True
    print(f"Model loaded successfully (3 NPU cores)")
    return True


def main():
    parser = argparse.ArgumentParser(description="RuView NPU Inference Service")
    parser.add_argument("--port", type=int, default=3024, help="HTTP port")
    parser.add_argument("--model", default=MODEL_PATH, help="RKNN model path")
    args = parser.parse_args()

    # Load model
    if not load_model(args.model):
        print("WARNING: Running without NPU inference")

    # Start HTTP server
    server = HTTPServer(("0.0.0.0", args.port), InferenceHandler)
    print(f"NPU Inference Service listening on port {args.port}")
    print(f"  POST /infer - Run inference")
    print(f"  GET /health - Health check")
    print(f"  GET /stats - Statistics")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        if rknn:
            rknn.release()


if __name__ == "__main__":
    main()
