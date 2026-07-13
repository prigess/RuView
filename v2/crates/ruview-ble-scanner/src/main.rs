//! ruview-ble-scanner — passive BLE-advertisement scanner.
//!
//! Listens to BLE adverts via BlueZ (Linux only) and republishes each unique
//! device as MQTT on the local broker.  The point of this binary is observation:
//! it shows what's broadcasting in the home (Dexcom CGMs, BP cuffs, scales,
//! personal-emergency pendants, phones, watches) so subsequent code can decide
//! which to parse and which to ignore.
//!
//! Default behaviour:
//!   * Scan continuously.  Never initiate pairing.
//!   * Publish each observed device's most recent advert to MQTT topic
//!     `ruview-ble/<sanitised-mac>/state` (one packed JSON payload, retained).
//!   * Anonymise the MAC in the payload (hash) unless caregiver enrols it.
//!
//! ⚠ macOS / non-Linux: the binary compiles but exits immediately with a
//!   message — bluer is BlueZ-specific.
//!
//! Privacy: this is the "observe what's around" step.  No pairing, no GATT,
//! no auto-trust.  An allowlist file (CLI arg) can restrict which adverts get
//! republished.

#[cfg(not(target_os = "linux"))]
fn main() {
    println!(
        "ruview-ble-scanner only runs on Linux (uses BlueZ).  \
         On this host the BLE stack is bluetoothd-incompatible."
    );
    std::process::exit(0);
}

#[cfg(target_os = "linux")]
mod scanner {

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use bluer::{Adapter, AdapterEvent, Address, DeviceEvent, DeviceProperty};
use clap::Parser;
use futures::stream::StreamExt;
use rumqttc::{AsyncClient, MqttOptions, QoS};
use serde::Serialize;
use tracing::{debug, info, warn};

#[derive(Parser, Debug)]
#[command(
    name = "ruview-ble-scanner",
    about = "Passive BLE-advertisement scanner that republishes observed devices to MQTT."
)]
pub struct Args {
    /// MQTT broker host.
    #[arg(long, env = "RUVIEW_BLE_MQTT_HOST", default_value = "127.0.0.1")]
    mqtt_host: String,

    /// MQTT broker port.
    #[arg(long, env = "RUVIEW_BLE_MQTT_PORT", default_value_t = 1883)]
    mqtt_port: u16,

    /// MQTT topic prefix.  Each device becomes `<prefix>/<mac>/state`.
    #[arg(long, env = "RUVIEW_BLE_MQTT_PREFIX", default_value = "ruview-ble")]
    mqtt_prefix: String,

    /// Per-device republish throttle.  No more than one MQTT message per
    /// device per `throttle_ms` even if BlueZ fires more adverts.
    #[arg(long, env = "RUVIEW_BLE_THROTTLE_MS", default_value_t = 2000)]
    throttle_ms: u64,

    /// Optional allowlist of MAC addresses (lowercase, colon-separated, one
    /// per line).  Devices not on the list will be hashed; devices on the
    /// list publish their plaintext MAC + their friendly name from the file.
    #[arg(long, env = "RUVIEW_BLE_ALLOWLIST")]
    allowlist: Option<PathBuf>,

    /// Minimum RSSI (dBm) to publish — filters out faint, far-away devices.
    #[arg(long, env = "RUVIEW_BLE_MIN_RSSI", default_value_t = -85)]
    min_rssi: i16,
}

#[derive(Serialize)]
struct BlePayload<'a> {
    /// Plaintext MAC if device is enrolled, otherwise a stable hash.
    id: String,
    /// Caregiver-provided friendly name if enrolled, else `None`.
    name: Option<&'a str>,
    /// Most recent RSSI in dBm.
    rssi_dbm: Option<i16>,
    /// Advertised local name (BLE GAP).
    advertised_name: Option<String>,
    /// Service UUIDs advertised (lowercased, sorted).
    service_uuids: Vec<String>,
    /// Manufacturer-data company ID → hex blob.
    manufacturer_data: HashMap<u16, String>,
    /// Service-data UUID → hex blob.
    service_data: HashMap<String, String>,
    /// Wall-clock ISO-8601 of last observation.
    seen_at: String,
}

/// Allowlist entry: MAC (lowercase normalised) → friendly name.
type Allowlist = HashMap<String, String>;

fn load_allowlist(path: Option<&PathBuf>) -> Result<Allowlist> {
    let mut map = Allowlist::new();
    let Some(p) = path else { return Ok(map); };
    let text = std::fs::read_to_string(p)
        .with_context(|| format!("reading allowlist {}", p.display()))?;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        let (mac, name) = line.split_once(' ')
            .map(|(m, n)| (m.trim(), n.trim()))
            .unwrap_or((line, ""));
        map.insert(mac.to_lowercase(), name.to_string());
    }
    Ok(map)
}

/// Stable, short hash of a MAC — non-reversible without the secret salt,
/// reversible WITH the salt for the same address (so a single MAC always
/// produces the same anonymised id across restarts).  Salt is a per-host
/// file at /var/lib/ruview-ble/salt — generated on first boot.
fn anonymise_mac(addr: Address, salt: &[u8]) -> String {
    use std::hash::Hasher;
    let mut h = std::collections::hash_map::DefaultHasher::new();
    h.write(&addr.0);
    h.write(salt);
    format!("anon-{:016x}", h.finish())
}

fn load_or_create_salt() -> Vec<u8> {
    let salt_path = "/var/lib/ruview-ble/salt";
    if let Ok(bytes) = std::fs::read(salt_path) {
        if bytes.len() >= 16 { return bytes; }
    }
    let mut salt = [0u8; 16];
    use std::io::Read;
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut salt);
    }
    if let Some(parent) = std::path::Path::new(salt_path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(salt_path, salt);
    salt.to_vec()
}

#[derive(Default, Clone)]
struct CachedAdvert {
    rssi: Option<i16>,
    name: Option<String>,
    service_uuids: Vec<String>,
    manufacturer_data: HashMap<u16, String>,
    service_data: HashMap<String, String>,
    last_published: Option<Instant>,
}

pub async fn run() -> Result<()> {
    let args = Args::parse();
    let salt = load_or_create_salt();
    let allowlist = load_allowlist(args.allowlist.as_ref())?;
    info!("loaded allowlist: {} entries", allowlist.len());

    // BlueZ session
    let session = bluer::Session::new().await
        .context("opening BlueZ session — is bluetoothd running?")?;
    let adapter: Adapter = session.default_adapter().await
        .context("no default BLE adapter available")?;
    adapter.set_powered(true).await.ok();
    info!("adapter: {} ({})", adapter.name(), adapter.address().await?);

    // Connect MQTT
    let client_id = format!("ruview-ble-scanner-{}", std::process::id());
    let mut opts = MqttOptions::new(&client_id, &args.mqtt_host, args.mqtt_port);
    opts.set_keep_alive(Duration::from_secs(30));
    let (mqtt, mut eventloop) = AsyncClient::new(opts, 64);
    // Spawn an event drain so the eventloop progresses.
    tokio::spawn(async move {
        while let Ok(_) = eventloop.poll().await {}
    });
    info!("mqtt: connected client={} prefix={}", client_id, args.mqtt_prefix);

    // Cache of last-seen properties per device.
    let mut cache: HashMap<Address, CachedAdvert> = HashMap::new();

    // Discovery loop
    let mut events = adapter.discover_devices().await?;
    info!("discovery: started · throttle={}ms · min_rssi={}",
          args.throttle_ms, args.min_rssi);

    while let Some(evt) = events.next().await {
        match evt {
            AdapterEvent::DeviceAdded(addr) => {
                cache.entry(addr).or_default();
                // Watch property changes for THIS device so we get RSSI + MFG
                // updates as new adverts arrive.
                if let Ok(device) = adapter.device(addr) {
                    if let Ok(mut p) = device.events().await {
                        let allowlist_c = allowlist.clone();
                        let salt_c = salt.clone();
                        let prefix_c = args.mqtt_prefix.clone();
                        let mqtt_c = mqtt.clone();
                        let throttle = args.throttle_ms;
                        let min_rssi = args.min_rssi;
                        tokio::spawn(async move {
                            let mut local = CachedAdvert::default();
                            while let Some(ev) = p.next().await {
                                if let DeviceEvent::PropertyChanged(prop) = ev {
                                    update_cached(&mut local, prop);
                                    let now = Instant::now();
                                    let due = local.last_published
                                        .map(|t| now.duration_since(t) >= Duration::from_millis(throttle))
                                        .unwrap_or(true);
                                    if !due { continue; }
                                    if let Some(r) = local.rssi {
                                        if r < min_rssi { continue; }
                                    }
                                    local.last_published = Some(now);
                                    publish(
                                        &mqtt_c, &prefix_c, addr, &local,
                                        &allowlist_c, &salt_c,
                                    ).await;
                                }
                            }
                        });
                    }
                }
            }
            AdapterEvent::DeviceRemoved(addr) => {
                debug!("device removed: {addr}");
                cache.remove(&addr);
            }
            _ => {}
        }
    }
    warn!("discovery stream ended");
    Ok(())
}

fn update_cached(cache: &mut CachedAdvert, prop: DeviceProperty) {
    use bluer::DeviceProperty::*;
    match prop {
        Rssi(r)                   => cache.rssi = Some(r),
        Name(n)                   => cache.name = Some(n),
        Uuids(us)                 => cache.service_uuids =
            us.into_iter().map(|u| u.to_string().to_lowercase()).collect(),
        ManufacturerData(md)      => {
            cache.manufacturer_data = md.into_iter()
                .map(|(k, v)| (k, hex::encode(&v)))
                .collect();
        }
        ServiceData(sd)           => {
            cache.service_data = sd.into_iter()
                .map(|(u, v)| (u.to_string().to_lowercase(), hex::encode(&v)))
                .collect();
        }
        _ => {}
    }
}

async fn publish(
    mqtt: &AsyncClient,
    prefix: &str,
    addr: Address,
    advert: &CachedAdvert,
    allowlist: &Allowlist,
    salt: &[u8],
) {
    let mac_str = addr.to_string().to_lowercase();
    let (id, name) = match allowlist.get(&mac_str) {
        Some(friendly) => (mac_str.clone(), Some(friendly.as_str())),
        None           => (anonymise_mac(addr, salt), None),
    };
    let payload = BlePayload {
        id: id.clone(),
        name,
        rssi_dbm: advert.rssi,
        advertised_name: advert.name.clone(),
        service_uuids: advert.service_uuids.clone(),
        manufacturer_data: advert.manufacturer_data.clone(),
        service_data: advert.service_data.clone(),
        seen_at: chrono::Utc::now().to_rfc3339(),
    };
    let topic = format!("{}/{}/state", prefix, id);
    let bytes = match serde_json::to_vec(&payload) {
        Ok(b)  => b,
        Err(e) => { warn!("json encode: {e}"); return; }
    };
    if let Err(e) = mqtt.publish(&topic, QoS::AtLeastOnce, true, bytes).await {
        warn!("mqtt publish failed for {topic}: {e}");
    } else {
        debug!("published {topic} rssi={:?}", advert.rssi);
    }
}

// Tiny hex encoder so we don't pull in a whole hex crate.
mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        let mut s = String::with_capacity(bytes.len() * 2);
        for b in bytes { s.push_str(&format!("{:02x}", b)); }
        s
    }
}

// chrono shim — we only need RFC3339 wall-clock formatting.
mod chrono {
    pub struct Utc;
    impl Utc {
        pub fn now() -> WallClock {
            use std::time::{SystemTime, UNIX_EPOCH};
            let d = SystemTime::now().duration_since(UNIX_EPOCH)
                .unwrap_or_default();
            WallClock { unix_ms: d.as_millis() as i64 }
        }
    }
    pub struct WallClock { unix_ms: i64 }
    impl WallClock {
        pub fn to_rfc3339(&self) -> String {
            // Best-effort, no leap-second handling — fine for logs.
            let secs   = self.unix_ms / 1000;
            let millis = (self.unix_ms % 1000).abs();
            let t = secs.max(0) as u64;
            // Compute Y-M-D-h-m-s the long way (no extra crate).
            let (year, month, day, hh, mm, ss) = unix_to_ymdhms(t);
            format!("{year:04}-{month:02}-{day:02}T{hh:02}:{mm:02}:{ss:02}.{millis:03}Z")
        }
    }
    fn unix_to_ymdhms(t: u64) -> (i64, u32, u32, u32, u32, u32) {
        let ss = (t % 60) as u32;
        let m  = t / 60;
        let mm = (m % 60) as u32;
        let h  = m / 60;
        let hh = (h % 24) as u32;
        let days = (h / 24) as i64;
        // Civil-from-days (Howard Hinnant)
        let z = days + 719468;
        let era = if z >= 0 { z } else { z - 146096 } / 146097;
        let doe = (z - era * 146097) as u64;
        let yoe = (doe.saturating_sub(doe/1460).saturating_sub(doe/36524).saturating_add(doe/146096)) / 365;
        let y = yoe as i64 + era * 400;
        let doy = doe.saturating_sub(365*yoe + yoe/4 - yoe/100);
        let mp = (5*doy + 2)/153;
        let d = (doy - (153*mp + 2)/5 + 1) as u32;
        let mo = if mp < 10 { mp as u32 + 3 } else { mp as u32 - 9 };
        let yr = if mo <= 2 { y + 1 } else { y };
        (yr, mo, d, hh, mm, ss)
    }
}

} // mod scanner

#[cfg(target_os = "linux")]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "ruview_ble_scanner=info".into())
        )
        .init();
    scanner::run().await
}
