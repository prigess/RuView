# RuView — Phase 2: Health ML Exploration

**Status:** Planned / not started. **Gate:** begins only **after the current
branch (`feat/ld2450-server-ingestion-fall`, PR #34) is cleanly tested and
merged to `main`.** Phase 2 is an *exploration* phase — the bar is "pull an
existing model or public dataset and try it," not "train from scratch."

Mission anchor: RuView is the multimodal **sensing layer** of Norim's longevity
platform — *reduce unnecessary suffering every day, together.* Every candidate
below must serve a real health outcome for the person being sensed, not just
exercise the NPU.

---

## 0 · Why this phase exists (the NPU reality)

- The **RK3588 6-TOPS NPU is provisioned and proven** (RKNN 2.3.2, 308 inf/s
  across 3 cores) but sits **idle at 0%** — nothing is wired to it.
- On **current sensors, audio is the only place a real pretrained model earns
  the NPU today.** Radar streams (LD2450/LD2410C/C6) are low-dimensional — any
  model is tiny and belongs on the CPU. WiFi **CSI** is the NPU's natural home
  (count/pose/fall/breathing) but is **capture-starved** (v0.6.6 MGMT-only
  trickle) and only has a degenerate count scaffold.
- So Phase 2 = **use the mic + NPU to explore real health models now**, while
  the CSI/radar **data flywheel** (`ruview-featlog`, 2 Hz) matures toward the
  flagship CSI models.

The NPU is a *means*, not the goal. The biggest wins are **multimodal fusion**
and **temporal/behavioral modeling**, where each modality's model can stay small.

---

## Track A · Health ML models on existing sensors

The mic (INMP441) is the goldmine — most of these have public datasets and run
as MobileNet-class CNNs that convert cleanly to `.rknn`.

| Health signal | Existing model / dataset | Sensor | NPU fit | Caveat |
|---|---|---|---|---|
| **Cough detection & counting** | FluSense · COUGHVID · Coswara | mic | ✅ | Room-mic compatible; cough-rate trend = respiratory marker |
| **Snore / sleep-disordered breathing (apnea screen)** | PSG-Audio + apnea-audio CNNs | mic | ✅ | Nocturnal; high longevity value; far-field OK |
| **Acoustic distress / safety events** (scream, "help", fall-thud, glass-break) | AudioSet / YAMNet fine-tune | mic | ✅ (base already live) | Easiest to stand up |
| **Speech emotion / agitation** | RAVDESS · IEMOCAP | mic | ✅ CRNN | Needs speech; moderate far-field accuracy |
| **Vocal biomarker — cognitive decline (Alzheimer's)** | ADReSS / ADReSSo challenge | mic | ✅ | Research-grade; needs clean speech; **privacy-sensitive** |
| **Vocal biomarker — Parkinson's** | UCI Parkinson voice · mPower | mic | ✅ small net | Research-grade; usually sustained-vowel protocol |
| **Vocal biomarker — depression/mood** | DAIC-WOZ | mic | ✅ | Research-grade; privacy-sensitive |
| **Respiratory lung sounds (wheeze/crackle)** | ICBHI 2017 | mic | ✅ | ⚠️ trained on **stethoscope/contact** audio — large domain gap to a room mic; likely poor |
| **CSI human sensing — count / pose / fall / breathing** | MM-Fi · Wi-Pose · WiAR | WiFi CSI | ✅✅ **NPU flagship** | Fix CSI capture + collect data first |
| **Sleep staging** | PSG-derived resp/motion models | C6 BR + LD2410 motion | ⚠️ small | Approximate; C6 emits cooked BR only |
| **Gait-speed / activity decline** (longevity biomarker) | radar-HAR datasets | LD2450 tracks | ⚠️ tiny (CPU) | No drop-in pretrained; needs flywheel data |

> **Verify before use:** dataset licenses, pretrained-weight availability, and
> exact sources must be re-checked when this phase starts (some are
> research-challenge datasets with usage terms). This doc names them; it does
> not vouch for current links.

---

## Track B · Smarter jobs (no new hardware, mostly fusion)

1. **Multimodal fall detection** — audio *thud* + LD2450 *"target dropped to
   floor + stopped"* + C6 *"breathing present, no motion"* → high-confidence
   fall, far fewer false alarms than any single sensor. Roadmap priority #2.
   The fusion logic is the innovation; each model stays small.
2. **Gait & activity from radar** — LD2450 tracks over time → gait speed,
   sit-to-stand time, pacing/wandering (dementia signal). **Gait-speed decline
   is a clinically validated healthspan biomarker** — squarely on-mission.
3. **Behavioral-routine anomaly detection** (highest value / most innovative) —
   fuse presence + location + audio over **days** → learn the person's normal
   rhythm (wake, bathroom trips, kitchen activity, sleep) → flag deviations
   (didn't get up; more night bathroom trips → UTI/fall risk; declining
   movement). Temporal autoencoder/forecaster; existing sensors only.

---

## Track C · One sensor to add — thermal array (MLX90640, 32×24 IR)

- Gives the NPU a **real image-like tensor** (768 px) → a proper small CNN for
  **fall, posture, occupancy count, febrile/fever screen** — the image-CNN
  workload currently missing.
- **Privacy-preserving** — thermal blobs aren't identifiable images (matters for
  elder homes; cameras were de-scoped for this reason).
- ~$10, I²C, drops onto the existing ESP32-S3 wiring pattern.
- Heavier tier (later): TI IWR6843 / Infineon BGT60 raw-radar-cube → CNN
  fall/vitals/gesture.

---

## Recommended pilot order (exploration ROI)

1. **Acoustic distress / fall-thud** — cheapest; YAMNet base already live,
   fine-tune the head. First real NPU health workload.
2. **Cough counting** + **3. Snore/apnea** — public room-audio datasets, genuine
   digital-health signals, true MobileNet-class NPU models.
3. **Multimodal fall (Track B.1)** — the differentiating feature.
4. **Behavioral-routine anomaly (Track B.3)** — the intelligence leap.
5. **Vocal cognitive/Parkinson biomarkers** — highest longevity payoff and most
   innovative, but **research-grade + privacy-sensitive**: explore controlled,
   not passive always-on.
6. **CSI human sensing** — flagship NPU justification; unblock by fixing CSI
   capture + data collection first.

---

## Cross-cutting caveats & dependencies

- **Quantization accuracy** — `.rknn` int8 conversion needs a calibration set;
  multi-class audio scores can shift. Every model gets an accuracy check vs its
  float/tflite baseline before it's trusted.
- **Domain gap** — models trained on contact/clinical audio (ICBHI) or scripted
  speech will underperform on a far-field room mic. Validate on our own captures.
- **Privacy** — vocal biomarkers imply recording speech. Decide the consent /
  on-device-only / no-retention policy **before** any speech model ships.
- **Data flywheel** — `ruview-featlog` (2 Hz fused features) is the substrate for
  radar/CSI models. Radar-track and CSI models are gated on collecting + labeling
  this. "Data is the bottleneck" — Phase 2 should also grow the labeled set.
- **NPU service** — needs `ruview-npu` (:3024) wired (task #19) using
  `rknn-toolkit-lite2`; version-lock lite2 ↔ librknnrt ↔ conversion toolkit.

## Definition of done for Phase 2 (exploration)

- ≥1 audio health model running on the **NPU** end-to-end via `ruview-npu`, with
  a measured accuracy-vs-baseline number and latency.
- A ranked, evidence-backed shortlist of which models graduate to a real feature.
- A labeled-data collection plan for the radar/CSI flagship models.

---

*Gated behind PR #34 clean-test-and-merge. See `docs/ruview-infra-requirements.md`
for the compute/runtime substrate this runs on.*
