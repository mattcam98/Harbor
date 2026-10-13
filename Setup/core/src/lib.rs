//! What Harbor Setup does, without an interface.
//!
//! Setup is the one time a computer is needed. It finds the iPhone, installs
//! Harbor on it, and hands Harbor a pairing file, which is what lets Harbor
//! install and renew apps on the phone by itself afterwards.
//!
//! Three rules shape this crate, each from something found wrong in the
//! tools Harbor grew out of:
//!
//! * Nothing is installed that was not checked first ([`release`]).
//! * The pairing file is as good as a password for the phone. It is made in
//!   memory, written to one place on the phone that only Harbor reads, and
//!   never kept on the computer ([`pairing`], [`device`]).
//! * A failure says what to do about it ([`SetupError::advice`]).

pub mod device;
pub mod pairing;
pub mod release;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum SetupError {
    /// The computer's own service for talking to iPhones is not running.
    #[error("cannot reach the service that talks to iPhones ({0})")]
    NoDeviceService(String),
    #[error("no iPhone or iPad is connected")]
    NoDevice,
    #[error("more than one device is connected: {}", .0.join(", "))]
    SeveralDevices(Vec<String>),
    #[error("no connected device has the identifier {0}")]
    DeviceNotFound(String),
    #[error("the device has not trusted this computer")]
    NotTrusted,
    #[error("could not {doing}: {detail}")]
    Device { doing: &'static str, detail: String },
    #[error("Harbor is not installed on this device")]
    HarborNotInstalled,
    #[error(transparent)]
    PairingFile(#[from] pairing::PairingFileError),
    #[error(transparent)]
    Release(#[from] release::ReleaseError),
}

impl SetupError {
    /// The one thing to do about it.
    pub fn advice(&self) -> &'static str {
        match self {
            SetupError::NoDeviceService(_) => {
                if cfg!(windows) {
                    "Install Apple Devices from the Microsoft Store (or iTunes from apple.com), open it once, then try again."
                } else if cfg!(target_os = "macos") {
                    "Restart the Mac. The service is part of macOS and should always be running."
                } else {
                    "Install and start usbmuxd, then try again."
                }
            }
            SetupError::NoDevice => {
                "Connect the iPhone with a cable, unlock it, and tap Trust if it asks."
            }
            SetupError::SeveralDevices(_) => {
                "Disconnect the others, or name the one you mean with --udid."
            }
            SetupError::DeviceNotFound(_) => "Check the identifier with `harbor-setup devices`.",
            SetupError::NotTrusted => {
                "Unlock the iPhone and tap Trust on the question it is showing, then try again."
            }
            SetupError::Device { .. } => {
                "Unlock the iPhone, keep it connected, and try again."
            }
            SetupError::HarborNotInstalled => "Install Harbor first, then run this again.",
            SetupError::PairingFile(_) => {
                "Unplug the iPhone, plug it back in, tap Trust, and try again."
            }
            SetupError::Release(_) => {
                "Download Harbor again from where you got it. Do not install this copy."
            }
        }
    }
}
