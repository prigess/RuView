#!/usr/bin/env python3
"""
ruview-featlog — the RuView "learn from the data" logger.

Polls every direct sensor (LD2450, LD2410C, C6, audio daemon) at a fixed rate
and appends ONE flat feature row per tick to a daily JSONL file. Records BOTH
the raw sensor values AND the physics-gated features, so a model can learn a
better decision boundary than the hand-tuned thresholds it will replace.

Labelling: each tick reads the current label from a control file, so you can
label a session live from another shell —

    echo empty     > /run/ruview/featlog.label     # before you leave
    echo present_1 > /run/ruview/featlog.label     # one person walking in
    echo present_2 > /run/ruview/featlog.label     # two people
    echo sitting   > /run/ruview/featlog.label
    echo fall      > /run/ruview/featlog.label      # (on cushions!)

Output: /var/lib/ruview/featlog/YYYY-MM-DD.jsonl  (append-only, one JSON/line).
Pure stdlib — no numpy/deps — so it runs anywhere.
"""
import urllib.request, json, time, math, os, argparse

L50 = "192.168.8.184"; LD = "192.168.8.132"; C6 = "192.168.8.228"; PI = "192.168.8.11"
LABEL_FILES = ["/run/ruview/featlog.label", "/etc/ruview/featlog.label"]
OUT_DIR = "/var/lib/ruview/featlog"

# Gates (kept in sync with the iOS app — the model gets both raw + gated).
SPEED_MAX = 350.0     # LD2450 |speed| cm/s ghost gate
RANGE_MAX = 6.0       # LD2450 range gate, m
DESPLIT_M = 0.7       # LD2450 near-field de-split, m
LD_MOVE_FLOOR = 35.0  # LD2410 moving-energy presence floor
LD_STILL_FLOOR = 20.0 # LD2410 still-energy presence floor


def _get(host, path, port=None):
    url = f"http://{host}{':'+str(port) if port else ''}{path}"
    try:
        return json.load(urllib.request.urlopen(url, timeout=1))
    except Exception:
        return None


def _val(host, path):
    d = _get(host, path)
    return d.get("value") if isinstance(d, dict) else None


def read_label():
    for p in LABEL_FILES:
        try:
            with open(p) as f:
                s = f.read().strip()
                if s:
                    return s
        except Exception:
            pass
    return "unlabeled"


def ld2450():
    targets = []
    for k in (1, 2, 3):
        x = _val(L50, f"/sensor/target_{k}_x"); y = _val(L50, f"/sensor/target_{k}_y")
        s = _val(L50, f"/sensor/target_{k}_speed")
        if x is None or y is None or (x == 0 and y == 0):
            continue
        dist = math.hypot(x, y) / 1000.0
        targets.append({"x": x, "y": y, "speed": s, "dist_m": round(dist, 3)})
    raw = len(targets)
    # gated: range + nonphysical-speed
    gated = [t for t in targets if t["dist_m"] <= RANGE_MAX and (t["speed"] is None or abs(t["speed"]) <= SPEED_MAX)]
    # de-split
    used = [False] * len(gated); count = 0
    for i in range(len(gated)):
        if used[i]:
            continue
        count += 1
        for j in range(i + 1, len(gated)):
            if not used[j] and math.hypot(gated[i]["x"] - gated[j]["x"], gated[i]["y"] - gated[j]["y"]) / 1000.0 < DESPLIT_M:
                used[j] = True
    nearest = min((t["dist_m"] for t in gated), default=None)
    return {"raw_count": raw, "gated_count": count, "nearest_m": nearest, "targets": targets}


def sample():
    me = _val(LD, "/sensor/moving_target_energy"); se = _val(LD, "/sensor/still_target_energy")
    mp = _get(LD, "/binary_sensor/moving_target_present"); sp = _get(LD, "/binary_sensor/still_target_present")
    c6p = _get(C6, "/binary_sensor/person_present")
    audio = _get(PI, "/api/v1/audio", 3025) or {}
    ev = (audio.get("events") or [])
    l = ld2450()
    return {
        "ts": round(time.time(), 2),
        "label": read_label(),
        # LD2450
        "ld2450_raw_count": l["raw_count"],
        "ld2450_gated_count": l["gated_count"],
        "ld2450_nearest_m": l["nearest_m"],
        "ld2450_targets": l["targets"],
        # LD2410C
        "ld2410_move_e": me, "ld2410_still_e": se,
        "ld2410_move_present": (mp or {}).get("value"),
        "ld2410_still_present": (sp or {}).get("value"),
        "ld2410_move_dist_cm": _val(LD, "/sensor/moving_target_distance"),
        "ld2410_still_dist_cm": _val(LD, "/sensor/still_target_distance"),
        "ld2410_present_gated": bool((me or 0) >= LD_MOVE_FLOOR or (se or 0) >= LD_STILL_FLOOR),
        # C6 (phantom-prone — logged raw for the model to learn to distrust)
        "c6_present": (c6p or {}).get("value"),
        "c6_hr": _val(C6, "/sensor/heart_rate"),
        "c6_br": _val(C6, "/sensor/breath_rate"),
        "c6_dist_cm": _val(C6, "/sensor/target_distance"),
        # audio
        "audio_level_db": audio.get("level_db"),
        "audio_fused": audio.get("fused"),
        "audio_top_event": ev[0]["label"] if ev else None,
        "audio_top_score": ev[0]["score"] if ev else None,
    }


def main():
    ap = argparse.ArgumentParser(description="RuView sensor feature logger (JSONL)")
    ap.add_argument("--hz", type=float, default=2.0, help="samples per second")
    ap.add_argument("--out-dir", default=OUT_DIR)
    ap.add_argument("--seconds", type=float, default=0, help="stop after N s (0 = forever)")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    period = 1.0 / args.hz
    t0 = time.time(); n = 0
    print(f"[featlog] logging @ {args.hz} Hz -> {args.out_dir}/<date>.jsonl")
    while True:
        row = sample()
        day = time.strftime("%Y-%m-%d", time.gmtime())
        with open(os.path.join(args.out_dir, f"{day}.jsonl"), "a") as f:
            f.write(json.dumps(row) + "\n")
        n += 1
        if n % 20 == 0:
            print(f"[featlog] {n} rows · label={row['label']} · ld2450={row['ld2450_gated_count']} "
                  f"ld2410_present={row['ld2410_present_gated']}")
        if args.seconds and time.time() - t0 >= args.seconds:
            print(f"[featlog] done, {n} rows"); break
        time.sleep(period)


if __name__ == "__main__":
    main()
