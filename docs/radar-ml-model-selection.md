# RuView — Is there a "YAMNet for radar"? Model research & selection

**Question:** can we adopt a pretrained ML model for radar the way we adopted
YAMNet for audio, to make presence / count / activity / fall *precise* instead
of hand-tuned thresholds?

**Short answer:** **No single drop-in "YAMNet for radar" exists yet** — but the
field is converging on one, and there's a concrete path. Two things to be clear
about first:

1. **This is ML, not an LLM.** LLMs model language. Turning radar/audio feature
   streams into presence/activity is a small **classifier / temporal net** — the
   same *role* YAMNet plays for audio, running on the Pi NPU. An LLM is the wrong
   tool (slow, imprecise for numeric sensor fusion).
2. **Why no exact YAMNet analog:** YAMNet works because audio is a *standardized
   input* (a waveform) with an *AudioSet-scale* labeled corpus (~2M clips).
   Radar has **neither** — the input differs per chip (point cloud vs
   micro-Doppler spectrogram vs raw IQ vs a DSP'd target list), and there's no
   AudioSet-scale public radar corpus.

---

## The three tiers of "a model like YAMNet", mapped to our hardware

### Tier A — pretrained **foundation models** (the true YAMNet analog — emerging 2025–26)
Freeze a pretrained encoder, attach a lightweight classifier head — exactly
YAMNet's transfer pattern. Research-stage, not a packaged download yet, and
mostly need raw radar/CSI:
- **X-Fi** — modality-invariant foundation model for multimodal human sensing.
- **"Towards a Foundation Model for Wireless Sensing"** (pilot), **"Foundational
  Models for Single-Chip Radar"** (self-supervised), **RF-MAE** (masked
  autoencoder on unlabeled RF).

**Verdict:** watch these; the packaged "download-and-fine-tune" radar model is
~1–2 years out. Adopt when it matures.

### Tier B — datasets + strong baselines (what you'd actually fine-tune *today* with a real radar)
- **MM-Fi** ⭐ — the one that matters for us. TI **IWR6843** 60 GHz mmWave (the
  *exact* radar in our fall-pilot spec) + WiFi + LiDAR + RGB, **27 actions, 320k
  frames**, NeurIPS 2023 — and it's **already in our roadmap (ADR-015)**. A model
  trained on MM-Fi transfers to an IWR6843 we buy.
- **MiliPoint / RadHAR / MMActivity** — point-cloud HAR datasets/baselines.
- **Lightweight models proven at the edge:** **Tac-Mamba** (0.86M params, ~1.9 ms
  inference, ~87% radar-only — edge-ready), **1D-CNN on mmWave point clouds**
  (2026), **mPCT-LSTM**, **SEdgeNet** (ICASSP 2026 SOTA on MiliPoint/MMActivity),
  **SelaFD** (ViT fine-tune on micro-Doppler).

**Verdict:** this is the real "YAMNet for radar" for us — *once we have a
point-cloud radar (IWR6843)*. MM-Fi + a lightweight model → RKNN on the RK3588
NPU. Directly ties to the [Vayyar/IWR6843 fall pilot](pilots/vayyar-fall-pilot.md).

### Tier C — our **current** cheap radars (HLK LD2410C / LD2450)
The catch: these output an **already-DSP'd target list** (positions, speeds,
energies) — **not** point clouds or raw IQ. So Tier-A/B models **don't apply** —
there's nothing raw to feed them. (There's a 24 GHz FMCW fall-detection line of
work, but it needs point-cloud enhancement the HLK modules don't expose.)

**Verdict:** the right model here is a **small classifier trained on OUR data**:
gradient-boosted trees (LightGBM/XGBoost) or a tiny MLP / 1D-CNN over short
feature windows. Tiny (<KB–MB), <2 ms on the Pi, needs only a few thousand
labeled rows — and it *learns* the fusion the hand-tuned gates approximate,
fixing the borderline cases (the still-energy≈20 reflector, C6 phantom, LD2450
still-person dropout). **This is the immediate, precise win.**

---

## The plan (learn-from-data flywheel → model → NPU)

1. **Collect (now):** `ruview-featlog` (deployed on the Pi) logs the full fused
   feature vector — raw **and** gated — at 2 Hz to `/var/lib/ruview/featlog/*.jsonl`,
   with a live label file. Run labeled sessions: `empty`, `present_1`,
   `present_2`, `sitting`, `walking`, `fall` (on cushions). A few hours of
   labeled data is enough.
2. **Train v1 (HLK / Tier C):** LightGBM on windowed features → presence + count.
   Target: beat the gates on the empty↔occupied edge cases. Export to ONNX; run
   on the Pi (CPU is plenty; NPU optional).
3. **Serve:** a Pi bridge (mirror `ruview-hrd`/`ruview-audiod`) exposes the
   model's verdict at REST; the app reads it — same thin-client pattern.
4. **Upgrade (Tier B, with the fall-pilot radar):** when the IWR6843 lands,
   switch input to point clouds, fine-tune a lightweight model on **MM-Fi**
   (+ our data) → convert to **RKNN** for the RK3588 NPU. That's the genuine
   YAMNet-grade radar model, for activity + fall.
5. **Watch (Tier A):** adopt a wireless-sensing foundation model when one ships
   packaged.

**Bottom line:** there's no radar YAMNet to download today. For our cheap radars
the precise path is a small model trained on `ruview-featlog` data; the true
pretrained-model tier arrives *with the IWR6843* via **MM-Fi** — which is already
the radar and dataset in our fall pilot and ADR-015. The hardware choice and the
model choice converge on the same box.

---

## Sources
- MM-Fi (NeurIPS 2023): https://arxiv.org/abs/2305.10345
- awesome-mmwave-radar-perception: https://github.com/Armorhtk/awesome-mmwave-radar-perception
- SEdgeNet (ICASSP 2026) / MiliPoint / MMActivity — via the awesome list above
- X-Fi (foundation model): https://arxiv.org/pdf/2410.10167
- Towards a Foundation Model for Wireless Sensing (pilot): https://openreview.net/pdf?id=LMufK3vzE5
- 24 GHz FMCW fall detection (point-cloud enhancement): https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10820484/
- Tac-Mamba / edge HAR, SelaFD (ViT radar HAR): https://arxiv.org/pdf/2502.04740
