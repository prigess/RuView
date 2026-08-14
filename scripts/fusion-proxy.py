#!/usr/bin/env python3
"""
RuView Fusion Proxy - Cross-Node Person Count Aggregation

Aggregates per-node sensing data to provide a unified room-level view.
Implements multi-sensor fusion to avoid double-counting the same person
seen by multiple nodes.

Usage:
    python3 fusion-proxy.py --port 3025

    # Then query:
    curl http://localhost:3025/api/v1/room
"""

import argparse
import json
import time
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import deque
from threading import Lock
import math

# Configuration
SENSING_SERVER = "http://localhost:3022"
HISTORY_SIZE = 30  # Frames for temporal smoothing
DEBOUNCE_FRAMES = 5  # Frames before accepting count change

# Global state
lock = Lock()
score_history = deque(maxlen=HISTORY_SIZE)
count_history = deque(maxlen=HISTORY_SIZE)
current_count = 0
debounce_candidate = 0
debounce_counter = 0


def fetch_nodes():
    """Fetch node data from sensing server."""
    try:
        with urllib.request.urlopen(f"{SENSING_SERVER}/api/v1/nodes", timeout=2) as resp:
            return json.loads(resp.read()).get("nodes", [])
    except Exception as e:
        return []


def calculate_fused_count(nodes):
    """
    Calculate fused person count from multiple nodes.

    Strategy:
    1. Don't sum per-node counts (same person seen by multiple nodes)
    2. Use signal strength correlation to identify overlapping views
    3. Apply spatial diversity scoring
    """
    global current_count, debounce_candidate, debounce_counter

    if not nodes:
        return {"count": 0, "confidence": 0, "method": "no_nodes"}

    # Collect per-node data
    node_data = []
    for n in nodes:
        if n.get("status") != "active":
            continue

        motion = n.get("motion_level", "absent")
        rssi = n.get("rssi_dbm", -100)
        count = n.get("person_count", 0)
        radar_present = n.get("radar_present", False)
        radar_targets = n.get("radar_targets", 0)

        # Convert motion level to score
        motion_scores = {
            "absent": 0.0,
            "present_still": 0.3,
            "present_moving": 0.6,
            "active": 0.9,
        }
        motion_score = motion_scores.get(motion, 0.1)

        # RSSI weight (closer = more reliable)
        rssi_weight = max(0.2, min(1.0, (rssi + 90) / 60))

        node_data.append({
            "motion_score": motion_score,
            "rssi_weight": rssi_weight,
            "count": count,
            "radar_targets": radar_targets if radar_present else 0,
            "has_radar": radar_present,
        })

    if not node_data:
        return {"count": 0, "confidence": 0, "method": "no_active_nodes"}

    # Method 1: Radar-based (most accurate if available)
    radar_nodes = [n for n in node_data if n["has_radar"]]
    if radar_nodes:
        radar_count = max(n["radar_targets"] for n in radar_nodes)
        if radar_count > 0:
            return {
                "count": radar_count,
                "confidence": 0.9,
                "method": "radar",
            }

    # Method 2: Cross-node motion correlation
    motion_scores = [n["motion_score"] for n in node_data]

    # High correlation (all nodes see similar motion) = same person(s)
    # Low correlation (different motion levels) = might be different areas
    mean_motion = sum(motion_scores) / len(motion_scores)
    variance = sum((s - mean_motion) ** 2 for s in motion_scores) / len(motion_scores)
    std_dev = math.sqrt(variance) if variance > 0 else 0

    # Correlation factor: 0 = all same, 1 = very different
    correlation = min(1.0, std_dev / 0.3)

    # Weighted max motion score (not sum!)
    weighted_scores = [n["motion_score"] * n["rssi_weight"] for n in node_data]
    max_weighted = max(weighted_scores)

    # Convert to count with thresholds
    # Account for spatial diversity when motion patterns differ
    if max_weighted < 0.15:
        raw_count = 0
    elif max_weighted < 0.35:
        raw_count = 1
    elif max_weighted < 0.55:
        # At this level, check if different nodes see different patterns
        raw_count = 1 if correlation < 0.3 else 2
    else:
        # High motion - check diversity
        raw_count = 2 if correlation > 0.2 else 1

    # Special case: if most nodes show high motion, likely 2+ people
    high_motion_nodes = sum(1 for s in motion_scores if s >= 0.5)
    if high_motion_nodes >= 3 and mean_motion > 0.5:
        raw_count = max(raw_count, 2)

    # Debounce to prevent flicker
    with lock:
        if raw_count == current_count:
            debounce_counter = 0
            debounce_candidate = raw_count
        elif raw_count == debounce_candidate:
            debounce_counter += 1
            if debounce_counter >= DEBOUNCE_FRAMES:
                current_count = raw_count
                debounce_counter = 0
        else:
            debounce_candidate = raw_count
            debounce_counter = 1

        final_count = current_count

    # Confidence based on agreement
    agreement = 1.0 - std_dev / (mean_motion + 0.01)
    confidence = max_weighted * 0.6 + agreement * 0.4
    confidence = max(0.3, min(0.85, confidence))  # Cap without radar

    return {
        "count": final_count,
        "confidence": round(confidence, 2),
        "method": "csi_fusion",
        "raw_count": raw_count,
        "mean_motion": round(mean_motion, 3),
        "correlation": round(correlation, 3),
        "nodes_active": len(node_data),
    }


class FusionHandler(BaseHTTPRequestHandler):
    """HTTP handler for fusion API."""

    def log_message(self, format, *args):
        pass  # Suppress logging

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.end_headers()

    def do_GET(self):
        if self.path == "/api/v1/room" or self.path == "/":
            nodes = fetch_nodes()
            result = calculate_fused_count(nodes)

            # Build room-level summary
            response = {
                "room": {
                    "person_count": result["count"],
                    "confidence": result["confidence"],
                    "method": result["method"],
                },
                "nodes": {
                    "total": len(nodes),
                    "active": result.get("nodes_active", 0),
                },
                "debug": {
                    "mean_motion": result.get("mean_motion"),
                    "correlation": result.get("correlation"),
                    "raw_count": result.get("raw_count"),
                }
            }
            self._send_json(response)

        elif self.path == "/health":
            self._send_json({"status": "ok"})

        else:
            self._send_json({"error": "Not found"}, 404)


def main():
    parser = argparse.ArgumentParser(description="RuView Fusion Proxy")
    parser.add_argument("--port", type=int, default=3025)
    args = parser.parse_args()

    print(f"Fusion Proxy starting on port {args.port}")
    print(f"  GET /api/v1/room - Fused room-level person count")
    print(f"  GET /health - Health check")
    print(f"")
    print(f"Upstream: {SENSING_SERVER}")

    server = HTTPServer(("0.0.0.0", args.port), FusionHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutdown")


if __name__ == "__main__":
    main()
