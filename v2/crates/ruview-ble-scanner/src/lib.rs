//! Shared modules for the ruview-ble-scanner binaries.
//!
//! The crate ships two binaries:
//!   * `ruview-ble-scanner` — passive advertisement observer (src/main.rs)
//!   * `ruview-ble-hr-decoder` — GATT subscriber for the Bluetooth SIG
//!     Heart Rate Service (src/bin/ruview-ble-hr-decoder.rs)
//!
//! Pure decoding lives here so it runs on any platform and gets unit tests
//! without a Bluetooth radio.

pub mod hr_decoder;
