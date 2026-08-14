# RuView — BLE Device Pairing Procedure

How to connect a Bluetooth Low Energy device (heart-rate strap/ring, BP cuff,
scale, temp beacon, panic button) to the Orange Pi so it flows into the RuView
app.

**Pi:** `192.168.7.205` · SSH `root@192.168.7.205` · BT controller **`simha`** (`hci0`).
Everything below is already installed on this Pi (binaries, services,
`bluetoothctl 5.64`, `ruview-hrd` bridge on `:3027`).

> **Key idea:** the standard **Heart Rate Service (0x180D) needs NO pairing/bonding.**
> You just allowlist the device's MAC. Only devices that *require* a bond
> (some BP cuffs / scales) go through the `bluetoothctl` pair flow in §4.

---

## 1. Discover the device (get its MAC)

Put the device in pairing/advertising mode (e.g. wet a Polar H10's electrodes
and clip the pod on — it only advertises when worn), then on the Pi:

```bash
ssh root@192.168.7.205
bluetoothctl --timeout 20 scan on      # watch the [NEW] lines for your device
bluetoothctl devices                   # list what was found: "Device AA:BB:.. Polar H10 1234ABCD"
```

Note the **MAC** (e.g. `A0:9E:1A:xx:xx:xx`) and name. If it doesn't appear:
keep it worn/active, move it within ~2 m of the Pi, and re-scan (the Pi's
onboard BT range is short — a $5 USB BLE dongle helps if needed).

---

## 2. Heart-rate strap / ring (0x180D) — NO pairing needed

The `ruview-ble-hr-decoder` GATT-subscribes to the Heart Rate Measurement
characteristic (unbonded notifications) for allowlisted MACs and republishes to
MQTT `ruview-ble/hr/<mac>`. The `ruview-hrd` bridge turns that into the app's
`:3027/api/v1/hr`.

```bash
# a) Allowlist the device (comma-separate multiple MACs)
mkdir -p /etc/ruview
cat > /etc/ruview/ble-hr.conf <<'EOF'
RUVIEW_BLE_HR_DEVICES=A0:9E:1A:XX:XX:XX
EOF

# b) Start (and auto-start on boot) the decoder — opt-in, off by default
systemctl enable --now ruview-ble-hr-decoder

# c) Watch it connect + decode
journalctl -u ruview-ble-hr-decoder -f      # expect: "published HR=62 bpm contact=Detected rr=1"
```

That's it — no PIN, no bond. Skip to §3 to verify.

---

## 3. Verify the chain (device → app)

```bash
# 1. MQTT — is the decoder publishing?
mosquitto_sub -h 127.0.0.1 -t 'ruview-ble/hr/#' -v      # {"mac":"..","bpm":61,"sensor_contact":"detected",...}

# 2. REST bridge — is ruview-hrd serving it? (run from the Pi OR your Mac)
curl -s http://192.168.7.205:3027/api/v1/hr             # {"bpm":61,"hrv_ms":38.4,"stream":"up",...}
```

3. **In the app:** open **Vital Signs** — a "Heart Rate — BLE strap" card shows
   live BPM + HRV, and **Node Health** gains a "BLE HR strap" node. The heart
   rate on every screen now comes from the strap (preferred over the C6 radar).

`stream:"up"` = fresh reading; `"down"` = no reading in the last 8 s (strap off,
out of range, or off-skin).

---

## 4. Devices that REQUIRE a bond (some BP cuffs / scales)

If a device won't deliver data unbonded, pair it once with `bluetoothctl`:

```bash
bluetoothctl
[bluetooth]# power on
[bluetooth]# agent on
[bluetooth]# scan on            # wait for your device, then:
[bluetooth]# pair  AA:BB:CC:DD:EE:FF     # enter PIN if prompted (often 0000/1234)
[bluetooth]# trust AA:BB:CC:DD:EE:FF     # auto-reconnect on future wake
[bluetooth]# connect AA:BB:CC:DD:EE:FF
[bluetooth]# quit
```

- **BP cuff (SIG 0x1810)** and **HR (0x180D)** are standard profiles — decodable
  with the same pattern as the HR decoder (a small per-profile decoder).
- **Temp/humidity beacons** (Xiaomi LYWSD03MMC/ATC, Govee) **broadcast** in their
  adverts — no pairing at all; the passive `ruview-ble-scanner` reads them
  (`systemctl enable --now ruview-ble-scanner`, topic `ruview-ble/<id>/state`).

---

## 5. Troubleshooting

| Symptom | Fix |
|--------|-----|
| Device not in scan | Keep it worn/active; within ~2 m of the Pi; re-scan. Straps only advertise when worn (electrodes wet). |
| Decoder connects then drops | Normal on brief range loss — it auto-reconnects with backoff. Check `journalctl -u ruview-ble-hr-decoder`. |
| `stream:"down"` at `:3027` | No fresh frame in 8 s — strap off/off-skin/out of range. `sensor_contact:"not_detected"` = not on skin. |
| App card absent | App must be connected to the Pi; the BLE node only appears when a strap is paired. Reachability: `curl <pi>:3027/health`. |
| MQTT empty | Is `mosquitto` up (`systemctl is-active mosquitto`) and the decoder enabled with the right MAC in `/etc/ruview/ble-hr.conf`? |
| Push-sensor "down" but pings fine | ARP flux on the multi-homed Pi — see the voice-pipeline notes; `arp_ignore=1`/`arp_announce=2` already set. |

## Service map

| Service | Role | Default |
|--------|------|---------|
| `ruview-ble-hr-decoder` | 0x180D GATT → MQTT `ruview-ble/hr/<mac>` | disabled (opt-in) |
| `ruview-ble-scanner` | passive adverts → MQTT `ruview-ble/<id>/state` | disabled (opt-in) |
| `ruview-hrd` | MQTT → REST `:3027/api/v1/hr` (HR + HRV) | **enabled** |

Consent model: the decoders are **off by default** and only ever touch
allowlisted MACs — a device is monitored only after someone explicitly adds it.
