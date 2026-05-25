# Orange Pi 5 Pro NPU Acceleration Guide

## Overview

The Orange Pi 5 Pro features the Rockchip RK3588 SoC with a **6 TOPS NPU** (Neural Processing Unit) that can significantly accelerate inference for WiFi sensing models.

### Hardware Specifications

| Feature | Specification |
|---------|---------------|
| SoC | Rockchip RK3588 |
| NPU Performance | 6 TOPS (INT8) |
| NPU Architecture | 3-core NPU (2x large + 1x small) |
| Supported Formats | INT8, INT16, FP16 |
| Framework | RKNN (Rockchip Neural Network) |

## Service Architecture

RuView on Orange Pi uses **two services**:

```
┌─────────────────────────────────────────────────────────────┐
│                     Orange Pi 5 Pro                         │
│                                                             │
│  ┌─────────────────────┐    ┌─────────────────────┐        │
│  │  ruview-sensing     │    │  ruview-npu         │        │
│  │  (Rust Server)      │    │  (Python Service)   │        │
│  │                     │    │                     │        │
│  │  Port 3022 (HTTP)   │───▶│  Port 3024 (HTTP)   │        │
│  │  Port 3023 (WS)     │    │                     │        │
│  │  Port 5005 (UDP)    │    │  Uses NPU cores     │        │
│  │                     │    │  0, 1, 2            │        │
│  └─────────────────────┘    └─────────────────────┘        │
│           │                          │                      │
│           │                          │                      │
│           ▼                          ▼                      │
│  ┌─────────────────────┐    ┌─────────────────────┐        │
│  │  ESP32 Nodes        │    │  /dev/rknpu0        │        │
│  │  (CSI Data)         │    │  (NPU Device)       │        │
│  └─────────────────────┘    └─────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

### Do You Need Both Services?

| Use Case | ruview-sensing | ruview-npu | Notes |
|----------|----------------|------------|-------|
| Basic CSI sensing | Required | Optional | CPU-based inference works |
| Production deployment | Required | Recommended | 10x faster inference |
| Demo with UI | Required | Optional | UI works without NPU |
| ML model development | Required | Required | Fast iteration with NPU |

**Short answer:** For the demo, `ruview-sensing` alone is sufficient. Add `ruview-npu` for faster ML inference when you have trained RKNN models.

## Complete Setup Procedure

### Step 1: Install RuView Sensing Server

```bash
# On Orange Pi
cd /root/RuView

# Install the sensing service
sudo cp scripts/ruview-sensing.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ruview-sensing
sudo systemctl start ruview-sensing

# Verify
systemctl status ruview-sensing
curl http://localhost:3022/api/v1/nodes
```

### Step 2: Setup NPU (Required for NPU Service)

```bash
# Run automated setup
sudo bash scripts/setup-npu-orangepi.sh

# Or manually:
# 1. Create device node
sudo mknod /dev/rknpu0 c 10 126 2>/dev/null || true
sudo chmod 666 /dev/rknpu0

# 2. Create udev rule for persistence
cat << 'EOF' | sudo tee /etc/udev/rules.d/99-rknpu.rules
KERNEL=="rknpu", SUBSYSTEM=="misc", MODE="0666"
SUBSYSTEM=="misc", ATTR{name}=="rknpu", MODE="0666", SYMLINK+="rknpu0"
EOF
sudo udevadm control --reload-rules

# 3. Update runtime library to v2.3.2
cd /tmp
wget -q 'https://raw.githubusercontent.com/airockchip/rknn-toolkit2/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so' -O librknnrt.so
sudo cp librknnrt.so /usr/lib/
sudo ldconfig

# 4. Install Python toolkit
pip3 install rknn-toolkit-lite2

# 5. Verify
python3 -c "from rknnlite.api import RKNNLite; print('RKNN OK')"
cat /sys/kernel/debug/rknpu/version
```

### Step 3: Install NPU Inference Service (Optional)

```bash
# Install service
sudo cp scripts/ruview-npu.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ruview-npu
sudo systemctl start ruview-npu

# Verify
systemctl status ruview-npu
curl http://localhost:3024/health
```

### Step 4: Verify Complete Setup

```bash
# Check both services
systemctl status ruview-sensing ruview-npu

# Check nodes
curl -s http://localhost:3022/api/v1/nodes | python3 -m json.tool

# Check NPU
curl -s http://localhost:3024/health
curl -s http://localhost:3024/stats

# Check NPU hardware
cat /sys/kernel/debug/rknpu/load
cat /sys/kernel/debug/rknpu/version
```

## Verified Configuration (May 2026)

| Component | Version | Status |
|-----------|---------|--------|
| RKNN Driver | v0.9.2 | Working |
| librknnrt.so | v2.3.2 | Working |
| rknn-toolkit-lite2 | v2.3.2 | Working |
| NPU Cores | 3 cores active | Working |

**Performance Results:**
- ResNet18 inference: 3.95ms average
- CSI inference: 4.37ms average
- NPU temperature: 32°C (stable)

## NPU Inference Service API

The `ruview-npu` service provides a REST API for NPU-accelerated inference.

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check and NPU status |
| `/stats` | GET | Inference statistics |
| `/infer` | POST | Run inference on CSI features |

### Example Usage

```bash
# Health check
curl http://localhost:3024/health
# Response: {"status": "ok", "model_loaded": true, "npu_available": true}

# Run inference
curl -X POST http://localhost:3024/infer \
  -H "Content-Type: application/json" \
  -d '{"features": [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56]}'
# Response: {"presence": "detected", "motion": "moving", "confidence": 0.95, "latency_ms": 4.5}

# Get statistics
curl http://localhost:3024/stats
# Response: {"inference_count": 100, "avg_latency_ms": 4.37, "min_latency_ms": 2.28, "max_latency_ms": 6.76}
```

## Why Use NPU Acceleration?

| Task | CPU (ms) | NPU (ms) | Speedup |
|------|----------|----------|---------|
| CSI Feature Extraction | 15-20 | 2-3 | 6-8x |
| Person Counting Model | 50-100 | 5-10 | 10x |
| Pose Estimation | 200-500 | 20-50 | 10x |
| Vital Signs Detection | 30-50 | 5-8 | 5-6x |

## Converting Models for NPU

### Requirements

- **x86 machine** (Mac Intel or Linux) for model conversion
- `rknn-toolkit2` (not available on ARM64)
- Source model in ONNX format

### Conversion Pipeline

```
PyTorch Model → ONNX Export → RKNN Converter (x86) → .rknn Model → Deploy to Orange Pi
```

### Convert ONNX to RKNN

Run on x86 machine:

```bash
# Install converter (x86 only)
pip install rknn-toolkit2

# Convert
python scripts/convert-model-to-rknn.py \
  --input model.onnx \
  --output model.rknn \
  --input-shape 1,56

# Deploy to Orange Pi
scp model.rknn root@192.168.7.205:/opt/ruview/models/
```

### Create Sample Model

```bash
# Create and convert a sample presence detection model
python scripts/convert-model-to-rknn.py --create-sample -o presence_detector.rknn
```

## Performance Tuning

### Multi-Core NPU

```python
from rknnlite.api import RKNNLite

# Use all 3 NPU cores (best performance)
rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0_1_2)

# Or use specific cores
rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_0)  # Core 0 only
```

### Power Management

```bash
# Check NPU frequency
cat /sys/class/devfreq/fdab0000.npu/cur_freq

# Set performance governor (max frequency)
echo performance | sudo tee /sys/class/devfreq/fdab0000.npu/governor

# Monitor utilization
watch -n 1 cat /sys/kernel/debug/rknpu/load
```

## Troubleshooting

### NPU Not Detected

```bash
# Check device exists
ls -la /dev/rknpu0

# If missing, create it
sudo mknod /dev/rknpu0 c 10 126
sudo chmod 666 /dev/rknpu0

# Check driver
dmesg | grep rknpu
cat /sys/kernel/debug/rknpu/version
```

### Version Mismatch Error

```
E RKNN: Invalid RKNN format
E RKNN: rknn_init, load model failed!
```

**Solution:** Update librknnrt.so to match toolkit version:

```bash
# Download matching runtime
wget -O /tmp/librknnrt.so \
  'https://raw.githubusercontent.com/airockchip/rknn-toolkit2/master/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so'
sudo cp /tmp/librknnrt.so /usr/lib/
sudo ldconfig

# Verify versions match
python3 -c "from rknnlite.api import RKNNLite; RKNNLite(verbose=True).release()"
```

### Service Won't Start

```bash
# Check logs
journalctl -u ruview-npu -n 50

# Common issues:
# 1. NPU device missing - run setup-npu-orangepi.sh
# 2. Model file missing - check /opt/ruview/models/
# 3. Python dependency missing - pip3 install rknn-toolkit-lite2
```

## Quick Reference

### Service Management

```bash
# Start/stop sensing server
sudo systemctl start ruview-sensing
sudo systemctl stop ruview-sensing

# Start/stop NPU service
sudo systemctl start ruview-npu
sudo systemctl stop ruview-npu

# Check status
systemctl status ruview-sensing ruview-npu

# View logs
journalctl -u ruview-sensing -f
journalctl -u ruview-npu -f
```

### Health Checks

```bash
# Sensing server
curl http://localhost:3022/api/v1/nodes

# NPU service
curl http://localhost:3024/health
curl http://localhost:3024/stats

# NPU hardware
cat /sys/kernel/debug/rknpu/load
cat /sys/kernel/debug/rknpu/version
```

## Future Work

- [x] NPU runtime working (v2.3.2)
- [x] NPU inference service deployed
- [ ] Pre-trained RKNN models for RuView presence detection
- [ ] Integrate NPU calls into main sensing server (eliminate second service)
- [ ] Rust native RKNN bindings
- [ ] Real-time NPU monitoring in UI

## References

- [RKNN Toolkit2 (Active Repo)](https://github.com/airockchip/rknn-toolkit2) - Official maintained repository
- [RKNN Toolkit2 (Legacy)](https://github.com/rockchip-linux/rknn-toolkit2) - No longer maintained
- [RK3588 NPU Programming Guide](https://wiki.t-firefly.com/en/ROC-RK3588S-PC/usage_npu.html)
- [Orange Pi 5 Pro Wiki](http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-5-Pro.html)
- [ezrknn-toolkit2](https://github.com/Pelochus/ezrknn-toolkit2) - Simplified installation for Orange Pi
