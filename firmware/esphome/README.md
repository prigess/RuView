# ESPHome firmware for the C6 radar node

This directory holds the ESPHome configuration for **Node 7** — an ESP32-C6
with a Seeed MR60BHA2 60 GHz mmWave radar attached on UART1 (TX=GPIO16,
RX=GPIO17).

It replaces the custom RuView firmware on this specific device because:

- The custom firmware has an unresolved `radar_type=0` bug — the MR60 is
  detected at boot but the radar fields never populate in outgoing UDP packets.
- ESPHome ships a mature `seeed_mr60bha2` component with built-in support for
  presence, distance, breath rate, and heart rate.
- Configuration is declarative YAML, no NVS provisioning gymnastics.
- Native OTA + encrypted API + auto-reconnect WiFi out of the box.

The 3 ESP32-S3 CSI nodes (Nodes 1, 2, 3) continue to run the custom RuView
firmware — ESPHome does not do WiFi CSI.

## Files

| File | Purpose |
|------|---------|
| `ruview-c6-radar.yaml` | The ESPHome config (committed) |
| `secrets.yaml.example` | Template for credentials (committed) |
| `secrets.yaml` | Real credentials (gitignored, you create this) |

## One-time setup (10 min)

```bash
# 1. Install ESPHome (Python package, you only do this once)
python3 -m pip install esphome

# 2. Create the secrets file with real credentials
cd firmware/esphome
cp secrets.yaml.example secrets.yaml
$EDITOR secrets.yaml          # fill in wifi_ssid/password
openssl rand -base64 32        # paste output as api_encryption_key
openssl rand -hex  16          # paste output as ota_password
```

## Build & flash

Plug the C6 into USB (it enumerates as `/dev/cu.usbmodem*`), then:

```bash
cd firmware/esphome
esphome run ruview-c6-radar.yaml
```

ESPHome will:
1. Compile a firmware image (~2 min first time, ~30 s after)
2. Auto-detect the USB port
3. Flash via esptool
4. Open a serial monitor showing live logs

After the first flash, subsequent updates happen over WiFi (OTA) without
needing USB.

## Smoke-test once installed

```bash
# Find the assigned IP (look at the serial log, or check the router)
C6_IP=192.168.7.<assigned>

# Web UI — open in browser
open http://$C6_IP/

# JSON endpoints — what the Pi sensing-server will poll
curl http://$C6_IP/sensor/heart_rate
curl http://$C6_IP/sensor/breath_rate
curl http://$C6_IP/sensor/target_distance
curl http://$C6_IP/binary_sensor/person_present
```

A successful response looks like:
```json
{"id":"sensor-heart_rate","value":72.0,"state":"72 BPM"}
```

## How the Pi consumes this

The sensing-server side ingests these endpoints periodically and merges the
values into the `edge_vitals` slot for Node 7. The poller is at
`scripts/c6-radar-poll.py` (TBD — wire up after we confirm the device is
publishing reliably).

For now, manual verification: `curl` the endpoints above. If you see real
HR/BR/distance values, the radar path is working end-to-end.

## Why these WiFi settings

The YAML pins the device to BSSID `14:22:db:bc:7b:e6` (AP "B" in the Firefly
mesh), because:

- AP "A" (`14:22:db:bc:54:a6`) had broken client-to-Pi forwarding during our
  2026-06-08 testing. Locking to AP B kept the radar device reliably reachable.
- A fallback network entry (no BSSID) is included so the device still works
  if AP B goes down.

When the upstream mesh isolation is fixed, just remove the `bssid:` line from
the primary network entry.
