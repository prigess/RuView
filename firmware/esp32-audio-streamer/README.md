# RuView ESP32-S3 Audio Streamer

Streams raw microphone audio from an **ESP32-S3 + INMP441** to the Orange Pi for
sound-event inference + telemetry fusion.

```
ESP32-S3 + INMP441  --UDP:5006 PCM16 16kHz mono-->  Orange Pi (ruview-audiod)
                                                     → YAMNet (NPU) ⨝ radar
                                                     → REST :3025 → iOS app
```

This replaces the ESPHome loudness firmware on the mic node with a dedicated
raw-audio streamer. The Pi computes level/activity from the stream, so the
ESPHome loudness sensors are no longer needed on-device.

## Wiring (INMP441 → ESP32-S3)
| INMP441 | ESP32-S3 | Note |
|---------|----------|------|
| VDD | 3V3 | 3.3 V only |
| GND | GND | |
| L/R | GND | left channel |
| SCK | **GPIO15** | I²S BCLK |
| WS  | **GPIO16** | I²S WS |
| SD  | **GPIO4**  | I²S data → ESP |

## Configure
Edit the `#define`s at the top of `main/audio_streamer_main.c`:
- `WIFI_SSID` / `WIFI_PASS` — your network (currently `Firefly`)
- `PI_IP` — the Orange Pi (`192.168.7.205`)
- `GAIN_SHIFT` — 13 default; lower = louder (INMP441 is quiet), higher = more headroom

## Build & flash (ESP-IDF v5.x)
```bash
cd firmware/esp32-audio-streamer
idf.py set-target esp32s3
idf.py build
idf.py -p <PORT> flash monitor      # PORT e.g. /dev/cu.wchusbserial…
```

## Verify on the Pi
```bash
# stream should read "up" once the ESP32 is running:
curl -s http://192.168.7.205:3025/health
curl -s http://192.168.7.205:3025/api/v1/audio | python3 -m json.tool
# or watch live:
sshpass -p orangepi ssh root@192.168.7.205 journalctl -u ruview-audiod -f
```

The Pi side (`ruview-audiod`, installed at `/usr/local/bin/ruview-audiod`,
enabled systemd service) receives the stream, runs inference, fuses with the
radar's `edge-vitals`, and serves the result at `:3025/api/v1/audio`.

## ⚠ Critical: Pi-side networking (why "the mic was down")

The board streams **UDP** to the Pi. UDP has no retransmit — if the L2 path is
wrong, packets die silently with no recovery (unlike the radars' **TCP** MQTT,
which retransmits through problems). Two Pi-side requirements:

1. **ARP-flux fix (root cause of the infamous "only the mic is down").** The Pi
   is multi-homed on one subnet (ethernet `.212`/`.205` + wlan0 `.206`). By
   default both interfaces answer ARP for any local IP, so the board sometimes
   cached the Pi's *WiFi* MAC for `.205` and its UDP died in WiFi
   client-isolation. Fix (persisted in `/etc/sysctl.d/99-ruview-arp.conf`):
   ```
   net.ipv4.conf.all.arp_ignore=1
   net.ipv4.conf.all.arp_announce=2
   ```
   Each interface then answers ARP only for its own IPs → `.205` resolves to the
   ethernet MAC → bridged path works. TCP (radars) survived without this; UDP
   (mic) did not — that's why *only* the mic broke.
2. **Ethernet-primary routing** (`enP4p65s0` metric 100 < `wlan0` 600) and the
   board BSSID-locked to AP B (`14:22:db:bc:7b:e6`).
