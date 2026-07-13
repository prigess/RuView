//! ruview-ble-hr-decoder — GATT subscriber for the standard Bluetooth
//! Heart Rate Service (UUID 0x180D), publishing decoded HR + RR + sensor
//! contact + energy as MQTT.
//!
//! Pairing model: the Heart Rate Service spec permits unbonded
//! notifications, so this binary does NOT pair with the device — it just
//! GATT-connects, subscribes to characteristic 0x2A37 notifications, and
//! decodes each frame.
//!
//! Allowlist of devices to subscribe to is provided as a comma-separated
//! list of MACs via env var `RUVIEW_BLE_HR_DEVICES`.  Each device runs in
//! its own task; the subscriber auto-reconnects on disconnect with
//! exponential backoff.

#[cfg(not(target_os = "linux"))]
fn main() {
    println!("ruview-ble-hr-decoder runs on Linux only (requires BlueZ).");
    std::process::exit(0);
}

#[cfg(target_os = "linux")]
mod hr_runtime {

use std::str::FromStr;
use std::time::Duration;

use anyhow::{Context, Result};
use bluer::{gatt::remote::Characteristic, Adapter, Address, Device};
use clap::Parser;
use futures::stream::StreamExt;
use rumqttc::{AsyncClient, MqttOptions, QoS};
use serde::Serialize;
use tracing::{debug, error, info, warn};

use ruview_ble_scanner::hr_decoder::{decode, HeartRateMeasurement};

// Bluetooth SIG-assigned UUIDs for the Heart Rate profile.
//   0x180D — Heart Rate Service
//   0x2A37 — Heart Rate Measurement characteristic
const HR_SERVICE_UUID:           uuid::Uuid = uuid::uuid!("0000180d-0000-1000-8000-00805f9b34fb");
const HR_MEASUREMENT_CHAR_UUID:  uuid::Uuid = uuid::uuid!("00002a37-0000-1000-8000-00805f9b34fb");

#[derive(Parser, Debug)]
#[command(
    name = "ruview-ble-hr-decoder",
    about = "Subscribe to the Bluetooth SIG Heart Rate Service for allowlisted devices and republish HR readings to MQTT."
)]
pub struct Args {
    /// Comma-separated MAC list, e.g. "AA:BB:CC:DD:EE:FF,11:22:33:44:55:66"
    #[arg(long, env = "RUVIEW_BLE_HR_DEVICES")]
    devices: String,

    #[arg(long, env = "RUVIEW_BLE_MQTT_HOST", default_value = "127.0.0.1")]
    mqtt_host: String,
    #[arg(long, env = "RUVIEW_BLE_MQTT_PORT", default_value_t = 1883)]
    mqtt_port: u16,
    #[arg(long, env = "RUVIEW_BLE_MQTT_PREFIX", default_value = "ruview-ble")]
    mqtt_prefix: String,
}

#[derive(Serialize)]
struct PublishedHr<'a> {
    /// MAC string (allowlisted devices are not anonymised in this binary —
    /// they're explicitly enrolled by the caregiver).
    mac: String,
    #[serde(flatten)]
    measurement: &'a HeartRateMeasurement,
    seen_at: String,
}

pub async fn run() -> Result<()> {
    let args = Args::parse();
    let macs: Vec<Address> = args.devices.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| Address::from_str(s))
        .collect::<Result<Vec<_>, _>>()
        .context("parsing RUVIEW_BLE_HR_DEVICES — expected comma-sep MAC list")?;
    if macs.is_empty() {
        anyhow::bail!("no devices configured; set RUVIEW_BLE_HR_DEVICES");
    }
    info!("hr-decoder: monitoring {} device(s)", macs.len());

    // BlueZ
    let session = bluer::Session::new().await
        .context("opening BlueZ session — is bluetoothd running?")?;
    let adapter = session.default_adapter().await
        .context("no default adapter")?;
    adapter.set_powered(true).await.ok();
    // Run an internal discovery so connect() finds the device by address.
    let _disc = adapter.discover_devices().await?;

    // MQTT
    let client_id = format!("ruview-ble-hr-{}", std::process::id());
    let mut opts = MqttOptions::new(&client_id, &args.mqtt_host, args.mqtt_port);
    opts.set_keep_alive(Duration::from_secs(30));
    let (mqtt, mut eventloop) = AsyncClient::new(opts, 64);
    tokio::spawn(async move { while let Ok(_) = eventloop.poll().await {} });
    info!("hr-decoder: mqtt connected client={}", client_id);

    // One task per device, each with its own reconnect/backoff loop.
    let prefix = args.mqtt_prefix.clone();
    let mut handles = Vec::new();
    for mac in macs {
        let adapter = adapter.clone();
        let mqtt = mqtt.clone();
        let prefix = prefix.clone();
        handles.push(tokio::spawn(async move {
            run_one_device(adapter, mac, mqtt, prefix).await
        }));
    }
    for h in handles { let _ = h.await; }
    Ok(())
}

async fn run_one_device(
    adapter: Adapter, mac: Address,
    mqtt: AsyncClient, prefix: String,
) {
    let mut backoff = Duration::from_secs(2);
    loop {
        match subscribe_loop(&adapter, mac, &mqtt, &prefix).await {
            Ok(()) => warn!("{mac}: subscription ended cleanly · reconnecting"),
            Err(e) => warn!("{mac}: subscribe error · {e:#}"),
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(60));
    }
}

async fn subscribe_loop(
    adapter: &Adapter, mac: Address,
    mqtt: &AsyncClient, prefix: &str,
) -> Result<()> {
    let device: Device = adapter.device(mac)
        .with_context(|| format!("opening device {mac}"))?;
    if !device.is_connected().await.unwrap_or(false) {
        info!("{mac}: connecting…");
        device.connect().await
            .with_context(|| format!("connect to {mac}"))?;
    }
    info!("{mac}: connected · searching for HR Service");

    let svcs = device.services().await
        .with_context(|| format!("listing services on {mac}"))?;
    let mut hr_svc_opt = None;
    for s in svcs {
        if s.uuid().await.unwrap_or_default() == HR_SERVICE_UUID {
            hr_svc_opt = Some(s);
            break;
        }
    }
    let hr_svc = hr_svc_opt
        .ok_or_else(|| anyhow::anyhow!("{mac}: no HR Service (0x180D) advertised"))?;

    let chars = hr_svc.characteristics().await
        .with_context(|| format!("listing chars on {mac}"))?;
    let mut hr_char_opt: Option<Characteristic> = None;
    for c in chars {
        if c.uuid().await.unwrap_or_default() == HR_MEASUREMENT_CHAR_UUID {
            hr_char_opt = Some(c);
            break;
        }
    }
    let hr_char = hr_char_opt
        .ok_or_else(|| anyhow::anyhow!("{mac}: no HR Measurement (0x2A37) characteristic"))?;
    info!("{mac}: subscribing to HR Measurement notifications");

    // Stream returned by bluer is not Unpin; pin to the heap so we can
    // poll it from a plain `while let` loop.
    let notify_stream = hr_char.notify().await
        .with_context(|| format!("subscribe HR on {mac}"))?;
    let mut notify = Box::pin(notify_stream);
    let topic = format!("{}/hr/{}", prefix, mac.to_string().to_lowercase());

    while let Some(bytes) = notify.next().await {
        match decode(&bytes) {
            Ok(m) => {
                let payload = PublishedHr {
                    mac: mac.to_string().to_lowercase(),
                    measurement: &m,
                    seen_at: now_rfc3339(),
                };
                match serde_json::to_vec(&payload) {
                    Ok(b) => {
                        if let Err(e) = mqtt.publish(&topic, QoS::AtLeastOnce, false, b).await {
                            warn!("{mac}: mqtt publish: {e}");
                        } else {
                            debug!("{mac}: published HR={} bpm contact={:?} rr={}",
                                   m.bpm, m.sensor_contact, m.rr_intervals_s.len());
                        }
                    }
                    Err(e) => error!("{mac}: json encode: {e}"),
                }
            }
            Err(e) => warn!("{mac}: HR decode failed · raw={:02x?} · {e}", bytes),
        }
    }
    Ok(())
}

fn now_rfc3339() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let ms = d.as_millis();
    // Cheap RFC3339; reuses the scanner's home-grown formatter shape.
    let secs = (ms / 1000) as i64;
    let millis = (ms % 1000) as u64;
    let (y, mo, d, hh, mm, ss) = ymd(secs as u64);
    format!("{y:04}-{mo:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}.{millis:03}Z")
}
fn ymd(t: u64) -> (i64, u32, u32, u32, u32, u32) {
    let ss = (t % 60) as u32;
    let m = t / 60;
    let mm = (m % 60) as u32;
    let h = m / 60;
    let hh = (h % 24) as u32;
    let days = (h / 24) as i64;
    let z = days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe.saturating_sub(doe / 1460).saturating_sub(doe / 36524).saturating_add(doe / 146096)) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe.saturating_sub(365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let mo = if mp < 10 { mp as u32 + 3 } else { mp as u32 - 9 };
    let yr = if mo <= 2 { y + 1 } else { y };
    (yr, mo, d, hh, mm, ss)
}

} // mod hr_runtime

#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ruview_ble_hr_decoder=info".into())
        )
        .init();
    hr_runtime::run().await
}
