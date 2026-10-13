//! Harbor Setup, from a terminal.

use std::{path::PathBuf, process::ExitCode};

use clap::{Parser, Subcommand};
use harbor_setup_core::{SetupError, device, pairing, release};

#[derive(Parser)]
#[command(name = "harbor-setup", version, about = "Puts Harbor on an iPhone and pairs it.")]
struct Arguments {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// List the connected iPhones and iPads.
    Devices,
    /// Say whether Harbor is on the device and whether a pairing file is waiting for it.
    Status {
        /// The device, when more than one is connected.
        #[arg(long)]
        udid: Option<String>,
    },
    /// Make a pairing file and give it to Harbor on the device.
    Pair {
        #[arg(long)]
        udid: Option<String>,
        /// The copy of Harbor, when the device has more than one.
        #[arg(long)]
        bundle_id: Option<String>,
        /// Write the file here instead of giving it to Harbor. It is as good
        /// as a password for the phone: delete it once you have used it.
        #[arg(long, value_name = "FILE")]
        export: Option<PathBuf>,
    },
    /// Print the identifier of the device that would be used. For scripts.
    Udid {
        #[arg(long)]
        udid: Option<String>,
    },
    /// Install an app that is already signed for the device (.ipa or .app).
    InstallApp {
        package: PathBuf,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Give Harbor the certificate and key it was signed with (a .p12 file),
    /// so it can sign the apps it runs. The file is as sensitive as a password.
    GiveIdentity {
        identity: PathBuf,
        #[arg(long)]
        udid: Option<String>,
        /// The copy of Harbor, when the device has more than one.
        #[arg(long)]
        bundle_id: Option<String>,
    },
    /// Check a copy of Harbor against the digest it should have.
    Verify {
        ipa: PathBuf,
        /// The SHA-256 the file should have, as 64 hexadecimal characters.
        #[arg(long)]
        sha256: Option<String>,
    },
}

#[tokio::main]
async fn main() -> ExitCode {
    match run(Arguments::parse().command).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Failed: {error}.");
            eprintln!("{}", error.advice());
            ExitCode::FAILURE
        }
    }
}

async fn run(command: Command) -> Result<(), SetupError> {
    match command {
        Command::Devices => {
            let devices = device::list().await?;
            if devices.is_empty() {
                return Err(SetupError::NoDevice);
            }
            for found in devices {
                let link = if found.wired { "cable" } else { "network" };
                if found.name.is_empty() {
                    println!("{}  (has not trusted this computer)  {link}", found.udid);
                } else {
                    println!("{}  {}  iOS {}  {link}", found.udid, found.name, found.version);
                }
            }
        }

        Command::Status { udid } => {
            let found = device::select(udid.as_deref()).await?;
            println!("{} (iOS {})", found.name, found.version);
            let copies = device::harbor_copies(&found).await?;
            if copies.is_empty() {
                println!("Harbor is not installed.");
            }
            for harbor in copies {
                println!("Harbor {} is installed as {}.", harbor.version, harbor.bundle_identifier);
                if device::pairing_file_waiting(&found, &harbor).await? {
                    println!("  A pairing file is waiting. Open this copy on the device to take it.");
                } else {
                    println!("  No pairing file is waiting.");
                }
            }
        }

        Command::Pair { udid, bundle_id, export } => {
            let found = device::select(udid.as_deref()).await?;
            println!("Pairing with {} (iOS {}).", found.name, found.version);
            println!("If the device asks, unlock it and tap Trust.");
            let file = device::make_pairing_file(&found).await?;
            let summary = pairing::check_for(&file, &found.version)?;
            println!(
                "Made a pairing file: lockdown {}, RemotePairing {}.",
                if summary.has_lockdown { "yes" } else { "no" },
                if summary.has_remote_pairing { "yes" } else { "no" },
            );

            match export {
                Some(path) => {
                    std::fs::write(&path, &file).map_err(|error| SetupError::Device {
                        doing: "write the pairing file",
                        detail: format!("{}: {error}", path.display()),
                    })?;
                    println!("Wrote {}.", path.display());
                    println!("Anyone with this file can control the device. Delete it once it is in use.");
                }
                None => {
                    let harbor = device::find_harbor(&found, bundle_id.as_deref())
                        .await?
                        .ok_or(SetupError::HarborNotInstalled)?;
                    device::deliver_pairing_file(&found, &harbor, &file).await?;
                    println!("Gave it to Harbor ({}).", harbor.bundle_identifier);
                    println!("Open Harbor on the device. It stores the file and removes this copy.");
                }
            }
        }

        Command::Udid { udid } => {
            println!("{}", device::select(udid.as_deref()).await?.udid);
        }

        Command::InstallApp { package, udid } => {
            let found = device::select(udid.as_deref()).await?;
            println!("Installing {} on {}.", package.display(), found.name);
            device::install_app(&found, &package).await?;
            println!("Installed.");
        }

        Command::GiveIdentity { identity, udid, bundle_id } => {
            let found = device::select(udid.as_deref()).await?;
            let harbor = device::find_harbor(&found, bundle_id.as_deref())
                .await?
                .ok_or(SetupError::HarborNotInstalled)?;
            let bytes = std::fs::read(&identity).map_err(|error| SetupError::Device {
                doing: "read the identity file",
                detail: format!("{}: {error}", identity.display()),
            })?;
            device::deliver_identity(&found, &harbor, &bytes).await?;
            println!("Gave Harbor its signing identity. Open Harbor on the device to take it.");
        }

        Command::Verify { ipa, sha256 } => {
            let expected = match sha256.as_deref() {
                Some(text) => Some(release::Sha256Digest::from_hex(text).ok_or_else(|| {
                    SetupError::Release(release::ReleaseError::Unreadable(
                        "--sha256 is not 64 hexadecimal characters".into(),
                    ))
                })?),
                None => None,
            };
            match release::check(&ipa, expected)? {
                release::Checked::Verified(digest) => println!("Verified: {digest}"),
                release::Checked::Unverified(digest) => {
                    println!("Not verified, because no digest was given to compare with.");
                    println!("This file's SHA-256 is {digest}");
                }
            }
        }
    }
    Ok(())
}
