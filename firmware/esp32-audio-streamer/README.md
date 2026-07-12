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
