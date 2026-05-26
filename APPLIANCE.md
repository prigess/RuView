# RuView Appliance — Device Inspection & Deployment Log

> **Living document** for the Orange Pi 5 Pro appliance deployment.
> Target: `.deb` package with sensing-server, NFC daemon, and GooseBit client.

---

## Device Summary

| Property | Value |
|----------|-------|
| **Hostname** | `simha` |
| **IP Address** | 192.168.7.205 |
| **SSH Access** | `root@192.168.7.205` (password: `orangepi`) |
| **Model** | Orange Pi 5 Pro (RK3588S) |
| **OS** | Ubuntu 22.04.4 LTS (Jammy) — Orange Pi 1.0.2 |
| **Kernel** | 5.10.160-rockchip-rk3588 (vendor, not mainline) |
| **Architecture** | aarch64 |
| **CPU** | 8-core big.LITTLE (4x Cortex-A76 @ 2.4GHz + 4x Cortex-A55 @ 1.8GHz) |
| **RAM** | 16GB |
| **Storage** | 226GB eMMC (34GB used, 191GB free) |
| **Swap** | 8GB (zram) |

---

## Network Interfaces

| Interface | Status | IP Address |
|-----------|--------|------------|
| `enP4p65s0` | UP | 192.168.7.205/24 |
| `wlan0` | DOWN | — |
| `lo` | UP | 127.0.0.1 |

---

## Listening Services

| Port | Protocol | Service | Binary |
|------|----------|---------|--------|
| 22 | TCP | SSH | sshd |
| 3022 | TCP | RuView HTTP | sensing-server |
| 3023 | TCP | RuView WebSocket | sensing-server |
| 5005 | UDP | ESP32 CSI ingress | sensing-server |
| 5555 | TCP | ADB over network | adbd |
| 8000 | TCP | Risk scoring API | uvicorn (local_server) |
| 631 | TCP | CUPS (localhost) | cupsd |

---

## Systemd Services (Custom)

### ruview-sensing.service
- **Status:** Running
- **Binary:** `/root/RuView/v2/target/release/sensing-server` (3MB)
- **Ports:** HTTP 3022, WS 3023, UDP 5005
- **Config:** `/etc/systemd/system/ruview-sensing.service`
- **Env override:** `/etc/systemd/system/ruview-sensing.service.d/ip-map.conf`
- **Data source:** ESP32 CSI over UDP
- **UI:** `/root/RuView/ui`

### appa_ble.service
- **Status:** Running
- **Script:** `/usr/local/appa_ble/bin/appa_ble_gatt_server.py`
- **Purpose:** BLE GATT server for device provisioning (WiFi setup, etc.)

### local_server.service
- **Status:** Running
- **Script:** `/usr/local/bin/local_server.py`
- **Port:** 8000
- **Purpose:** FastAPI risk scoring model server (fetches model from AWS Lambda)

### swupdate.service
- **Status:** Running
- **Config:** `/etc/swupdate.cfg`
- **GooseBit URL:** https://192.168.7.217
- **Device ID:** `54806e40f0764e72af6bfbd275aac2b4`
- **Hardware ID:** `PrigressAPPA` rev 1.0
- **Poll interval:** 60s

---

## I2C Devices Detected

| Bus | Address | Notes |
|-----|---------|-------|
| i2c-0 | 0x42, 0x43 | (driver claimed) |
| i2c-2 | 0x42 | (driver claimed) |
| i2c-3 | 0x11 | (driver claimed) |
| i2c-6 | 0x51 | (driver claimed) — likely EEPROM |
| i2c-10 | 0x30-0x35, 0x50-0x5e | Multiple devices (sensor array?) |

---

## NFC Status

| Check | Result |
|-------|--------|
| **PN7150 on I2C** | NOT DETECTED (should be at 0x28/0x29) |
| **Kernel NFC modules** | Not loaded, not available in `/lib/modules` |
| **libnfc** | Installed (1.8.0) |
| `nfc-list` | "No NFC device found" |
| `/dev/nfc*` | Does not exist |
| `/sys/class/nfc` | Does not exist |

**Conclusion:** PN7150 is either not physically connected or requires a device tree overlay to enable the I2C bus and IRQ line.

**Next steps for NFC:**
1. Verify PN7150 hardware wiring (I2C bus, IRQ GPIO, VEN GPIO)
2. Create/enable device tree overlay for PN7150
3. Build and load `nxp-nci` kernel module (may need backport to 5.10)
4. Configure libnfc with I2C connection string

---

## USB Devices

| Bus | Device | Vendor | Product |
|-----|--------|--------|---------|
| 005 | 002 | Apple | Magic Keyboard A1644 |
| 001 | 003 | Primax | HP Optical Mouse |
| 001 | 002 | Terminus | USB Hub |

---

## GPIO State (Relevant)

| GPIO | Label | Direction | State |
|------|-------|-----------|-------|
| gpio-20 | vcc5v0-otg | out | hi |
| gpio-24 | reset (BT?) | out | lo (ACTIVE LOW) |
| gpio-50 | green_led | out | lo |
| gpio-54 | blue_led | out | lo |

---

## RuView Deployment

**Location:** `/root/RuView/` (cloned from upstream)

**Built artifacts:**
- `/root/RuView/v2/target/release/sensing-server` — 3,072,424 bytes (May 7)
- Classifier loaded: 3,316 frames, 41.5% accuracy

**Missing:**
- `/root/RuView/data/esp32-node-ip-map.json` — File does not exist (need to create)

---

## Deployment Target: .deb Package

### Components to package:
1. **sensing-server** — Rust binary (cross-compile for aarch64)
2. **NFC daemon** — PN7150 interface (libnfc-based or nxp-nci driver)
3. **GooseBit client** — SWUpdate already installed, just needs config

### Current blockers:
- [ ] NFC hardware not connected or not visible
- [ ] Kernel 5.10 may lack nxp-nci driver — need to verify
- [ ] ESP32 node IP map needs creation

### Build approach:
1. Cross-compile sensing-server on macOS using `cross` or native aarch64 toolchain
2. Create systemd service files (already exist, can reuse)
3. Package with `dpkg-deb` or use `cargo-deb`
4. Test installation on device

---

## GooseBit OTA Integration

- **Server:** 192.168.7.217 (self-hosted)
- **CA cert:** `/usr/local/share/ca-certificates/goosebit.crt`
- **Signing key:** `/etc/swupdate.pem`
- **API test:** Returns 404 for device lookup (may need different endpoint)

---

## Inspection Log

| Date | Action | Result |
|------|--------|--------|
| 2026-05-23 | Initial SSH connection | Success |
| 2026-05-23 | I2C scan all buses | No PN7150 found |
| 2026-05-23 | NFC status check | Not functional (no hardware) |
| 2026-05-23 | RuView sensing service | Running OK |
| 2026-05-23 | GooseBit connectivity | Server responds, 404 on device lookup |
| 2026-05-23 | Deploy improved sensing-server | Complete, cross-compiled via `cross` |
| 2026-05-23 | Detection threshold tuning | Presence now detected correctly |
| 2026-05-23 | Training recording | 3000 frames (present_moving) |
| 2026-05-23 | ESP32 nodes visible | 2 nodes reporting |

---

## Improvements Deployed (2026-05-23)

### Threshold Tuning (`csi.rs`, `field_bridge.rs`)

**Person count thresholds (`score_to_person_count`):**
| Count | New Threshold | Old |
|-------|--------------|-----|
| 2 people | 0.55 | 0.70 |
| 3 people | 0.75 | 0.85 |

**FieldModel energy thresholds:**
| Count | New | Old |
|-------|-----|-----|
| 2 people | 8.0 | 12.0 |
| 3 people | 18.0 | 25.0 |

**Raw classification thresholds:**
| Level | New | Old |
|-------|-----|-----|
| active | 0.20 | 0.25 |
| present_moving | 0.08 | 0.12 |
| present_still | 0.025 | 0.04 |

**Adaptive classifier gate:**
- Only overrides raw classification when:
  - Model confidence > 60%
  - Training accuracy > 70%
- Prevents undertrained classifier from degrading detection

---

## Quick Commands

```bash
# SSH into device
ssh root@192.168.7.205

# Check sensing server logs
journalctl -u ruview-sensing -f

# Restart sensing server
systemctl restart ruview-sensing

# Check all custom services
systemctl status ruview-sensing appa_ble local_server swupdate

# I2C scan
i2cdetect -y 0  # Change 0 to other bus numbers

# Test NFC
nfc-list

# Check SWUpdate status
systemctl status swupdate
```

---

## Files on Device

```
/root/RuView/                          # Main repo
/root/RuView/v2/target/release/        # Built binaries
/root/RuView/ui/                       # Web UI
/etc/systemd/system/ruview-sensing.service
/etc/systemd/system/appa_ble.service
/etc/systemd/system/local_server.service
/etc/swupdate.cfg                      # GooseBit config
/usr/local/appa_ble/                   # BLE provisioning
/usr/local/bin/local_server.py         # Risk scoring server
```
