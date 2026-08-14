//! Heart Rate Measurement characteristic (0x2A37) decoder.
//!
//! Bluetooth SIG Heart Rate Service spec (HRS v1.0, characteristic GATT
//! Specification Supplement vN — Heart Rate Measurement).
//!
//! Layout of a notification payload:
//!
//! ```text
//! +-----+-------------+--------------+----------+
//! | byte| field       | size         | optional |
//! +-----+-------------+--------------+----------+
//! | 0   | Flags       | u8           | always   |
//! | 1.. | HR value    | u8 or u16 LE | always   |
//! |     | Energy Exp  | u16 LE       | flag 3   |
//! |     | RR-int #1   | u16 LE       | flag 4   |
//! |     | RR-int #2   | u16 LE       | flag 4   |
//! |     | ...                                   |
//! +-----+-------------+--------------+----------+
//!
//! Flags byte bits:
//!   0   HR value format    0=u8, 1=u16
//!   1-2 Sensor contact     00/01=not supported, 10=not detected, 11=detected
//!   3   Energy Expended    1=present (u16, kilojoules)
//!   4   RR-Interval        1=present (zero or more u16, units of 1/1024 s)
//!   5-7 reserved
//! ```
//!
//! This module is pure — no Bluetooth dependency — so it runs on every
//! platform (macOS, Linux, WASM) and can be tested without a radio.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SensorContact {
    /// Device doesn't expose contact information.
    NotSupported,
    /// Contact field is supported and reports the strap/band is OFF the skin.
    NotDetected,
    /// Contact field is supported and reports good skin contact.
    Detected,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HeartRateMeasurement {
    /// Heart rate in beats per minute.
    pub bpm: u16,
    /// Whether the strap/finger contact is detected.
    pub sensor_contact: SensorContact,
    /// Energy expended in kilojoules, cumulative since last reset.
    /// `None` if the device doesn't include it in this frame.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub energy_expended_kj: Option<u16>,
    /// RR-intervals in seconds (each `= raw_u16 / 1024.0`). Used to
    /// compute heart-rate variability (HRV).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub rr_intervals_s: Vec<f32>,
}

#[derive(Debug)]
pub enum DecodeError {
    Empty,
    TooShort { got: usize, expected: usize },
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::Empty => write!(f, "empty payload"),
            DecodeError::TooShort { got, expected } =>
                write!(f, "payload too short (got {got}, expected {expected})"),
        }
    }
}
impl std::error::Error for DecodeError {}

/// Decode a raw GATT notification payload from characteristic 0x2A37.
pub fn decode(data: &[u8]) -> Result<HeartRateMeasurement, DecodeError> {
    if data.is_empty() {
        return Err(DecodeError::Empty);
    }
    let flags = data[0];
    let hr_is_u16              = flags & 0x01 != 0;
    let sensor_contact_status  = (flags >> 1) & 0x03;
    let energy_present         = flags & 0x08 != 0;
    let rr_present             = flags & 0x10 != 0;

    let mut idx = 1usize;

    let bpm: u16 = if hr_is_u16 {
        if data.len() < idx + 2 {
            return Err(DecodeError::TooShort { got: data.len(), expected: idx + 2 });
        }
        let v = u16::from_le_bytes([data[idx], data[idx + 1]]);
        idx += 2;
        v
    } else {
        if data.len() < idx + 1 {
            return Err(DecodeError::TooShort { got: data.len(), expected: idx + 1 });
        }
        let v = data[idx] as u16;
        idx += 1;
        v
    };

    let sensor_contact = match sensor_contact_status {
        0b10 => SensorContact::NotDetected,
        0b11 => SensorContact::Detected,
        _    => SensorContact::NotSupported,
    };

    let energy_expended_kj = if energy_present {
        if data.len() < idx + 2 {
            return Err(DecodeError::TooShort { got: data.len(), expected: idx + 2 });
        }
        let v = u16::from_le_bytes([data[idx], data[idx + 1]]);
        idx += 2;
        Some(v)
    } else {
        None
    };

    let mut rr_intervals_s: Vec<f32> = Vec::new();
    if rr_present {
        while idx + 2 <= data.len() {
            let raw = u16::from_le_bytes([data[idx], data[idx + 1]]);
            idx += 2;
            rr_intervals_s.push(raw as f32 / 1024.0);
        }
    }

    Ok(HeartRateMeasurement {
        bpm,
        sensor_contact,
        energy_expended_kj,
        rr_intervals_s,
    })
}

// ─────────── tests ───────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_uint8_bpm() {
        // flags=0x00 — u8 HR, no contact, no energy, no RR
        let hr = decode(&[0x00, 72]).unwrap();
        assert_eq!(hr.bpm, 72);
        assert_eq!(hr.sensor_contact, SensorContact::NotSupported);
        assert!(hr.energy_expended_kj.is_none());
        assert!(hr.rr_intervals_s.is_empty());
    }

    #[test]
    fn decode_uint16_bpm() {
        // flags=0x01 — u16 HR; 300 bpm (out of physiological range but valid)
        let hr = decode(&[0x01, 0x2C, 0x01]).unwrap();
        assert_eq!(hr.bpm, 300);
    }

    #[test]
    fn decode_contact_detected() {
        // flags bit 1-2 = 11 → contact detected (mask 0b0000_0110 = 0x06)
        let hr = decode(&[0x06, 80]).unwrap();
        assert_eq!(hr.sensor_contact, SensorContact::Detected);
        assert_eq!(hr.bpm, 80);
    }

    #[test]
    fn decode_contact_not_detected() {
        // flags bit 1-2 = 10 → contact NOT detected (mask 0b0000_0100 = 0x04)
        let hr = decode(&[0x04, 65]).unwrap();
        assert_eq!(hr.sensor_contact, SensorContact::NotDetected);
    }

    #[test]
    fn decode_with_rr_intervals() {
        // flags=0x10 (RR), bpm=72, RR0=512 (0.5 s), RR1=1024 (1.0 s)
        let hr = decode(&[0x10, 72, 0x00, 0x02, 0x00, 0x04]).unwrap();
        assert_eq!(hr.bpm, 72);
        assert_eq!(hr.rr_intervals_s.len(), 2);
        assert!((hr.rr_intervals_s[0] - 0.5).abs() < 1e-3);
        assert!((hr.rr_intervals_s[1] - 1.0).abs() < 1e-3);
    }

    #[test]
    fn decode_with_energy_and_rr() {
        // flags=0x18 (energy + RR), bpm=70, energy=200 kJ, 1 RR=0.875s (raw=896)
        let hr = decode(&[0x18, 70, 0xC8, 0x00, 0x80, 0x03]).unwrap();
        assert_eq!(hr.bpm, 70);
        assert_eq!(hr.energy_expended_kj, Some(200));
        assert_eq!(hr.rr_intervals_s.len(), 1);
        assert!((hr.rr_intervals_s[0] - 0.875).abs() < 1e-3);
    }

    #[test]
    fn empty_payload_errors() {
        assert!(matches!(decode(&[]), Err(DecodeError::Empty)));
    }

    #[test]
    fn truncated_uint16_errors() {
        // flags claim u16 HR but only 1 byte follows
        assert!(matches!(decode(&[0x01, 0x2C]), Err(DecodeError::TooShort { .. })));
    }

    #[test]
    fn truncated_energy_errors() {
        // flags claim energy present but only HR byte follows
        assert!(matches!(decode(&[0x08, 72]), Err(DecodeError::TooShort { .. })));
    }

    #[test]
    fn realistic_polar_h10_frame() {
        // Polar H10 broadcasts u8 HR + RR intervals, no energy, no contact bit
        // flags = 0b0001_0000 (RR present, u8 HR)
        // bpm = 64, RR = 0.937 s (raw ~959)
        let hr = decode(&[0x10, 64, 0xBF, 0x03]).unwrap();
        assert_eq!(hr.bpm, 64);
        assert!((hr.rr_intervals_s[0] - 959.0 / 1024.0).abs() < 1e-3);
    }
}
