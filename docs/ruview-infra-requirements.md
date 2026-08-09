# RuView Sensing — Infrastructure Requirements

What it takes to run the RuView sensing stack on an edge node **efficiently**
(right processor for each job) and **promptly** (bounded latency), for the
Norim longevity platform.

- **Reference platform:** Orange Pi 5 Pro (RK3588S)
- **Figures measured on the live node, 2026-08-08**

---

## Summary

RuView sensing runs comfortably on a single RK3588 edge node. The infra job is
to put each workload on the *right* processor and keep the request path short.
Measured headroom on the live node:

| Metric | Value |
|--------|-------|
| Load avg / 8 cores | **0.6** |
| Every endpoint | **< 25 ms** |
| NPU (3 cores, idle) | **6 TOPS** |
| RAM free of 15 GB | **14 GB** |

**Headline:** the node is **not compute-bound** — the sensing runtime uses
< 1 core. "Efficient & prompt" is therefore about **allocation** (offload ML to
the NPU, keep DSP on CPU) and **the request path** (LAN-bound, tight poll
cadence, no runaway processes), not about raw horsepower.

---

## 1 · Hardware requirements

| Resource | Minimum | Recommended | Why |
|----------|---------|-------------|-----|
| **SoC** | RK3588S (4×A76 + 4×A55) | RK3588S / RK3588 | DSP + orchestration on CPU; must have the on-die NPU |
| **NPU** | RK3588 3-core, 6 TOPS | same | all CNN inference offloads here — *measured 308 inf/s resnet18 @ 3.24 ms* |
| **RAM** | 4 GB | 8–16 GB | runtime uses < 1 GB; headroom for models + on-device conversion |
| **Storage** | 16 GB | ≥ 32 GB (eMMC/NVMe > SD) | OS + runtimes + models (~few GB); eMMC/NVMe for I/O + endurance |
| **Network** | Wired 100M or 2.4/5 GHz Wi-Fi | Wired GbE (stable IP) | sensors + app talk over LAN; wired avoids DHCP/roam drops |
| **GPU** | Not required | — | no rendering/GPU-compute in the sensing path |

**Sensor tier (per node):** ESP32-S3 nodes over Wi-Fi — **LD2450** (X/Y
tracking), **LD2410C** (presence/distance), **INMP441** mic; **ESP32-C6 +
MR60BHA2** (60 GHz vitals). Optional BLE HR strap. Each is a few $; the Pi is
the brain.

---

## 2 · Compute allocation — the efficiency core

"Efficient" = the right silicon for each job. The rule: **neural nets → NPU;
signal processing & orchestration → CPU; nothing idles the NPU while the CPU
does ML.**

| Workload | Runs on | Runtime | Notes |
|----------|---------|---------|-------|
| CSI count / pose / fall CNNs | **NPU** | RKNN (rknn-toolkit-lite2) | convert model → `.rknn`; runs on all 3 cores |
| Radar DSP, CSI processing, fusion | **CPU** | Rust (sensing-server) | FFT/vector math — not NN ops; stays on CPU |
| Audio sound-class (YAMNet) | **CPU** | tflite_runtime | only 4.7% CPU; FFT/mel frontend isn't NPU-mappable |
| Vitals trust-gating, presence hold, bridges | **CPU** | Rust / Python | light control logic |

**NPU engagement rule:** every convertible CNN runs on the NPU (unsupported ops
fall back to CPU). The NPU was measured idle (0%) while models ran on CPU —
offloading them frees CPU for DSP and cuts inference latency. Monitor with
`cat /sys/kernel/debug/rknpu/load`. Model *conversion* (→ `.rknn`) is a
build-time step (runs on the Pi or x86 CI), never in the request path.

---

## 3 · Runtime services, ports & resource budget

| Service | Port(s) | Role | Measured cost |
|---------|---------|------|---------------|
| `ruview-sensing` | 3022 REST · 3023 WS · 5005 UDP | fusion + REST/WS + UI; radar ingestion bridges | ~2% CPU |
| `ruview-audiod` | 3025 REST · 5006 UDP | mic PCM → YAMNet → sound class | ~5% CPU |
| `ruview-npu` | 3024 REST | RKNN inference server (NPU) | NPU-bound |
| `ruview-hrd` / `ruview-countd` | 3027 / 3028 | BLE HR decode · CSI count | light |
| `mosquitto` | 1883 | MQTT broker (radar node ingest) | negligible |

**Bind + budget:** all HTTP/WS bind `0.0.0.0` (LAN) with a host-header
allowlist. Total steady-state CPU for the full stack is well under one core —
the RK3588 has 8. Provision RAM for concurrent model residency, not for the
daemons.

---

## 4 · Software base infra

### OS & system
- Ubuntu 22.04 aarch64 (glibc 2.35)
- Rockchip BSP kernel (5.10-rk3588) — ships the **RKNPU driver** (v0.9.2, NPU
  via DRM render node — no `/dev/rknpu0` needed)
- `mosquitto`, `bluez`, `libgomp1` / `liblapack`

### Three ML runtimes
- **RKNN** — `librknnrt.so` + `rknn-toolkit-lite2` (version-matched, e.g.
  2.3.2); NPU inference
- **tflite** — python venv + **`numpy<2`** (numpy 2 breaks tflite) +
  `tflite-runtime`; YAMNet
- **onnxruntime** (python, optional) — ONNX models not converted to RKNN

**Model store:** `/opt/ruview/models/` — `.rknn` / `.tflite` / `.onnx`
**vendored/delivered, never downloaded at runtime.**
**Rust build:** pinned `rustc 1.89` (or ship a prebuilt arm64 binary so the
device carries no toolchain).

**Base vs app split (for OTA):**
- **Base** (install-once / golden image): OS, kernel + NPU driver, the 3 ML
  runtimes, mosquitto, bluez, model store, toolchain.
- **App** (OTA-updated): the sensing daemons + models.

Keeps updates fast, offline, deterministic.

---

## 5 · Network requirements

- **Single LAN** for Pi + all sensors + the app. Stable Pi address — **wired
  static** or DHCP reservation; prefer **mDNS hostname** so a router/subnet
  change doesn't break sensor→Pi links.
- **Ports open on the LAN:** 3022/3023 (app), 3024/3025/3027/3028 (feature
  REST), 1883 (MQTT from radar nodes), 5005/5006 (UDP CSI/mic).
- **Bandwidth** is tiny: mic PCM ≈ 50 pkt/s (640 B), radar MQTT + REST are
  sparse. Any home LAN suffices; Wi-Fi packet loss (not bandwidth) is the risk
  for the mic — keep the mic node near the AP.
- **mDNS/multicast** must be allowed (home routers: yes; enterprise/guest:
  often blocked → fall back to DHCP reservation).

---

## 6 · Latency targets (promptly)

"Prompt" = bounded end-to-end from event → app. The path is:
sensor → (ingest) → server/daemon → app poll/WS.

| Stage | Target | Measured |
|-------|--------|----------|
| Any REST/WS request round-trip (LAN) | < 50 ms | 8–25 ms ✓ |
| App refresh cadence (live cards) | ≤ 0.5 s | 0.5 s (tuned from 1.0–1.5 s) ✓ |
| CNN inference (per frame, NPU) | < 10 ms | 3.24 ms (resnet18) ✓ |
| Presence assert / clear | 1–3 s | sticky window + node filter tuned |
| Vitals stabilization (mmWave) | ~30 s warmup | trust-gated |

**The lag lever:** with sub-25 ms endpoints, perceived lag is dominated by
**poll cadence**, not compute — tighten client poll intervals before reaching
for more hardware.

---

## 7 · Efficiency & promptness rules (operational)

1. **Offload NN to the NPU.** Any CNN in the pipeline → `.rknn`; keep the CPU
   for DSP + orchestration.
2. **Tight, cheap poll cadence.** Live cards ~0.5 s; endpoints are < 25 ms so
   this is nearly free.
3. **Guard against runaway processes.** A stuck `agetty` was found pegging a
   full core at 99% — audit `top`; disable unused serial gettys. One rogue
   process silently taxes the whole node.
4. **LAN-bound, no cloud in the loop.** All inference + fusion on-device; no
   runtime downloads (models vendored). Sub-second, offline, private.
5. **Version-lock the ML runtimes.** `rknn-toolkit-lite2` ↔ `librknnrt` ↔
   conversion toolkit must match; `numpy<2` for tflite.
6. **Right-size the hold/gate windows.** De-split, presence-hold, and
   trust-gates trade latency for stability — tune per scenario, don't stack
   redundant filters (a doubled `delayed_off` added ~2 s of latency).

---

## 8 · Explicitly NOT on the sensing node

- **No desktop GUI stack** (GTK/libsoup/WebKit) — the desktop app is a separate
  x86 product.
- **No Rust `candle` / `ort` (ONNX) / `gemm` ML crates** — that's the
  off-device (x86/CI) training path; doesn't build on aarch64 and isn't the
  device's inference route.
- **Full model-conversion toolkit is build-time only** — it may run on the Pi
  for convenience, but the deployed runtime carries only the lite runtime + the
  `.rknn` output.
- **No compiler on a production device** — ship prebuilt binaries via OTA.

---

*RuView Sensing infrastructure requirements · reference node RK3588S OPi 5 Pro ·
figures measured on the live deployment 2026-08-08 · efficient = right processor
per job · prompt = short request path*
