# Vayyar Fall-Detection Pilot — BOM + Orange Pi Integration Plan

**Goal:** professional-grade, camera-free **fall detection** (roadmap priority #2) that drops into the existing RuView pipeline — Pi owns inference, the iOS app stays a thin REST client, exactly like the YAMNet audio pipeline.

**Date:** 2026-07-12 · **Status:** spec / pre-purchase

---

## 1. The fork: which Vayyar do we buy?

Vayyar sells two very different things. Pick deliberately.

| Path | Product | What you get | Fits RuView? |
|------|---------|--------------|--------------|
| **A — Experiment (recommended)** | **Walabot Developer Pack** — **$599.95** | Raw 3D imaging + target list + breathing, open C++/Python SDK (Win/**Linux**). You build the fall classifier. | ✅ Pi owns inference; open data; matches our architecture |
| **B — Productize (later)** | **Vayyar Care** (now via Alexa Together) | Turnkey, field-proven fall algorithm, closed | ❌ for now — closed box, cloud/Alexa-bound, no raw access on the Pi |

**Decision:** buy **Path A (Walabot Developer Pack)** to pilot. It exposes raw data the Orange Pi can run models on. Vayyar Care is the eventual *productization* path if the pilot proves out and we'd rather license their algorithm than maintain ours.

> ⚠️ **Honest caveat:** the Developer Pack does **not** include Vayyar Care's proprietary fall algorithm. We build our own fall classifier on its raw output. This is proven feasible — a public project ([elloh755/Fall-Detection-with-Vayyar-Radar](https://github.com/elloh755/Fall-Detection-with-Vayyar-Radar)) does exactly this with the Walabot SDK + a scikit-learn classifier on labeled walk/stand/fall data.

---

## 2. Bill of materials

| Item | Qty | Price | Notes |
|------|-----|------:|-------|
| Walabot Developer Pack | 1 | **$599.95** | 18-antenna imaging-radar array; Imaging + Radar + **Breathing** APIs; USB; C++/Python on Windows & Linux. From [walabot.com](https://walabot.com/products/walabot-developer-pack-new) |
| USB cable (micro-B, data) + powered USB if needed | 1 | ~$10 | Walabot is USB-powered; RK3588 USB port should source it, but a powered hub de-risks brownout |
| Wall/ceiling mount or tripod | 1 | ~$20 | Wall-mount facing the room is the deployed geometry for fall |
| **Total (pilot)** | | **~$630** | one room |

**Bonus:** the same unit's **Breathing API** means this $600 device can *also* pilot contactless vitals — it partially overlaps the Emfit/UWB vitals pilot. One device, two roadmap gaps.

---

## 3. How it wires to the Orange Pi

```
Walabot Developer ──USB──> Orange Pi 5 (RK3588)
                            └─ Walabot SDK (Python)  → raw targets + raster image + breathing
                               └─ ruview-falld daemon → feature vector → fall classifier
                                  └─ REST :3026 /api/v1/fall  → iOS app (thin client)
```

This mirrors the audio pipeline exactly: sensor → Pi SDK → inference → REST → app. No app rewrite; add a `FallClient` alongside `AudioClient`.

### ⚠️ De-risk FIRST — before relying on it
The Walabot SDK officially lists **Linux (x86)**; it historically shipped a **Raspberry Pi (ARM)** build, but the product page does **not** confirm **arm64 / RK3588**. **This is the #1 unknown and must be verified on day one:**

1. Install the Walabot SDK on the Orange Pi (arm64) and confirm the shared lib loads (`import WalabotAPI` succeeds, `ConnectAny()` finds the device over USB).
2. If the arm64 lib is missing/incompatible, fallbacks (in order):
   - Run the SDK on a **Raspberry Pi 4/5** as a sensor-head that forwards features to the Orange Pi over the LAN (keeps the Pi as the fusion/REST hub).
   - Run the SDK on a small **x86 mini-PC** likewise.
   - Ask Vayyar dev support directly for the aarch64 build.

Do not order a second room's worth until arm64 (or a fallback host) is confirmed.

---

## 4. The fall classifier (Pi-side inference)

Follow the proven pattern, then upgrade:

1. **Data collection** — a `ruview-fall-collect` script logs Walabot **Targets** (x/y/z + amplitude) and **raster image** to CSV while a person performs labeled activities: *walking, standing/sitting, falling* (use cushions). ~5-min sessions per class.
2. **v1 classifier** — scikit-learn Random Forest on windowed features (target height drop, vertical velocity, energy-at-floor, dwell-on-floor). This is what the reference project uses; good enough to prove the signal.
3. **v2 (NPU)** — once v1 confirms the signal, move to a small temporal model (range-Doppler / point-cloud sequence) converted to **RKNN** on the RK3588 NPU — the same "run the model on the Pi" story as YAMNet. This is where it becomes genuinely ML-grade.
4. **Fusion** — confirm a fall by cross-checking the existing signals: audio "thud"/impact class from YAMNet + a radar motion-spike→still transition. A fused verdict cuts false alarms (the whole point of the multi-sensor stack).

**Fall verdict → alert:** `ruview-falld` emits `fall_suspected` → `fall_confirmed`; the app surfaces it and (roadmap: caregiver alerting) fires a push notification.

---

## 5. New Pi service: `ruview-falld`

Same shape as `ruview-audiod` (systemd unit, pinned venv, REST). Per the working method: write it as a script, test on the Pi, install it as a tool.

- **Input:** Walabot SDK (USB).
- **Output:** `GET :3026/api/v1/fall` → `{ state, confidence, last_fall_ts, target: {x,y,z}, breathing_bpm }` and `GET :3026/health`.
- **App:** add `FallClient` (poll :3026) + a Fall card / alert banner; reuse the Node Health card language.

---

## 6. Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| SDK not arm64-compatible on RK3588 | Verify day one; fallback to RPi/x86 sensor-head forwarding to the Pi |
| We must build the fall algorithm (not turnkey) | Proven feasible (reference repo); start with sklearn, upgrade to NPU; fuse with audio+radar to cut false alarms |
| Single-room coverage | Pilot one room (living room / bedroom) first; expand after arm64 + accuracy confirmed |
| Walabot consumer line longevity | It's the *dev* pack (actively sold); productization path is Vayyar Care if we go commercial |

---

## 7. First steps (once the unit arrives)

1. `ruview-falld` skeleton + **arm64 SDK load test** on the Orange Pi (go/no-go gate).
2. `ruview-fall-collect` → gather labeled walk/stand/fall CSVs in the actual room.
3. Train v1 RF classifier; measure fall recall / false-alarm rate.
4. Wire `GET :3026/api/v1/fall` + iOS `FallClient` + fall card.
5. Add audio+radar fusion confirmation; then RKNN/NPU v2.

**Pilot cost: ~$630, one room.** Covers fall detection *and* (bonus) contactless breathing on the same device.
