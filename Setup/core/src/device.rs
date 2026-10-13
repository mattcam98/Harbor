//! Talking to an iPhone over the cable.

use idevice::{
    IdeviceService,
    afc::opcode::AfcFopenMode,
    house_arrest::HouseArrestClient,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use plist::Value;

use crate::{SetupError, pairing};

/// The name this tool gives itself to the phone.
const LABEL: &str = "harbor-setup";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub udid: String,
    pub name: String,
    /// The iOS version, as the device states it.
    pub version: String,
    pub wired: bool,
}

/// A copy of Harbor found on a device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledHarbor {
    pub bundle_identifier: String,
    pub version: String,
}

fn failed(doing: &'static str) -> impl FnOnce(idevice::IdeviceError) -> SetupError {
    move |error| SetupError::Device { doing, detail: error.to_string() }
}

async fn usbmuxd() -> Result<UsbmuxdConnection, SetupError> {
    UsbmuxdConnection::default()
        .await
        .map_err(|error| SetupError::NoDeviceService(error.to_string()))
}

fn address() -> Result<UsbmuxdAddr, SetupError> {
    UsbmuxdAddr::from_env_var().map_err(|error| SetupError::NoDeviceService(error.to_string()))
}

/// Every device the computer can see. One that has not trusted this computer
/// is listed with what could be learned and an empty name.
pub async fn list() -> Result<Vec<Device>, SetupError> {
    let mut connection = usbmuxd().await?;
    let found = connection.get_devices().await.map_err(failed("list the connected devices"))?;
    let address = address()?;

    let mut devices = Vec::new();
    for entry in found {
        let provider = entry.to_provider(address.clone(), LABEL);
        let (name, version) = match describe(&provider).await {
            Ok(described) => described,
            Err(_) => (String::new(), String::new()),
        };
        let device = Device {
            udid: entry.udid.clone(),
            name,
            version,
            wired: matches!(entry.connection_type, Connection::Usb),
        };
        // The same phone can be listed twice, by cable and by network.
        match devices.iter_mut().find(|known: &&mut Device| known.udid == device.udid) {
            Some(known) if device.wired && !known.wired => *known = device,
            Some(_) => {}
            None => devices.push(device),
        }
    }
    Ok(devices)
}

async fn describe(provider: &UsbmuxdProvider) -> Result<(String, String), idevice::IdeviceError> {
    let mut lockdown = LockdownClient::connect(provider).await?;
    let read = |value: Value| value.as_string().unwrap_or_default().to_owned();
    let name = read(lockdown.get_value(Some("DeviceName"), None).await?);
    let version = read(lockdown.get_value(Some("ProductVersion"), None).await?);
    Ok((name, version))
}

/// Picks the device to work on: the one named, or the only one connected.
pub async fn select(udid: Option<&str>) -> Result<Device, SetupError> {
    let mut devices = list().await?;
    match udid {
        Some(wanted) => devices
            .into_iter()
            .find(|device| device.udid.eq_ignore_ascii_case(wanted))
            .ok_or_else(|| SetupError::DeviceNotFound(wanted.to_owned())),
        None => match devices.len() {
            0 => Err(SetupError::NoDevice),
            1 => Ok(devices.remove(0)),
            _ => Err(SetupError::SeveralDevices(
                devices
                    .iter()
                    .map(|device| format!("{} ({})", device.name, device.udid))
                    .collect(),
            )),
        },
    }
}

async fn provider(device: &Device) -> Result<UsbmuxdProvider, SetupError> {
    let mut connection = usbmuxd().await?;
    let entry = connection
        .get_device(&device.udid)
        .await
        .map_err(failed("reach the device"))?;
    Ok(entry.to_provider(address()?, LABEL))
}

/// The copy of Harbor to work on: the one with this identifier, or the only
/// one on the device. A device can hold two, one installed by Xcode and one
/// by Setup, and guessing between them could put a pairing file in the copy
/// nobody opens.
pub async fn find_harbor(
    device: &Device,
    bundle_identifier: Option<&str>,
) -> Result<Option<InstalledHarbor>, SetupError> {
    let mut copies = harbor_copies(device).await?;
    match bundle_identifier {
        Some(wanted) => Ok(copies
            .into_iter()
            .find(|copy| copy.bundle_identifier.eq_ignore_ascii_case(wanted))),
        None => match copies.len() {
            0 => Ok(None),
            1 => Ok(Some(copies.remove(0))),
            _ => Err(SetupError::SeveralCopies(
                copies.into_iter().map(|copy| copy.bundle_identifier).collect(),
            )),
        },
    }
}

/// Every copy of Harbor on the device.
pub async fn harbor_copies(device: &Device) -> Result<Vec<InstalledHarbor>, SetupError> {
    let provider = provider(device).await?;
    let mut apps = InstallationProxyClient::connect(&provider)
        .await
        .map_err(failed("ask the device which apps it has"))?;
    let installed = apps
        .get_apps(Some("User"), None)
        .await
        .map_err(failed("ask the device which apps it has"))?;

    let mut copies = Vec::new();
    for (bundle_identifier, info) in installed {
        let Some(info) = info.as_dictionary() else { continue };
        let text = |key: &str| info.get(key).and_then(Value::as_string).unwrap_or_default();
        // Harbor is known by the link scheme only it answers to, not by a
        // name another app could also have.
        let answers_to_harbor = info
            .get("CFBundleURLTypes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|kind| kind.as_dictionary()?.get("CFBundleURLSchemes")?.as_array())
            .flatten()
            .any(|scheme| scheme.as_string() == Some("harbor"));
        if answers_to_harbor {
            copies.push(InstalledHarbor {
                bundle_identifier,
                version: text("CFBundleShortVersionString").to_owned(),
            });
        }
    }
    copies.sort_by(|left, right| left.bundle_identifier.cmp(&right.bundle_identifier));
    Ok(copies)
}

/// Makes a pairing file for the device, in memory.
///
/// The lockdown half is the record this computer already has for the phone
/// from when the user tapped Trust, with use over the network switched on.
/// The RemotePairing half is made new each time.
pub async fn make_pairing_file(device: &Device) -> Result<Vec<u8>, SetupError> {
    let provider = provider(device).await?;
    let mut connection = usbmuxd().await?;

    let mut record = connection
        .get_pair_record(&device.udid)
        .await
        .map_err(|_| SetupError::NotTrusted)?;
    record.udid = Some(device.udid.clone());

    let mut lockdown = LockdownClient::connect(&provider)
        .await
        .map_err(failed("open a session with the device"))?;
    lockdown
        .start_session(&record)
        .await
        .map_err(failed("open a session with the device"))?;
    lockdown
        .set_value("EnableWifiDebugging", true.into(), Some("com.apple.mobile.wireless_lockdown"))
        .await
        .map_err(failed("let the pairing be used on the device itself"))?;

    let lockdown_record = record
        .serialize()
        .ok()
        .and_then(|bytes| Value::from_reader(std::io::Cursor::new(bytes)).ok())
        .and_then(Value::into_dictionary)
        .ok_or(pairing::PairingFileError::NotAPropertyList)?;

    let remote_record = if pairing::needs_remote_pairing(&device.version) {
        let host = format!("{LABEL}-{}", &uuid::Uuid::new_v4().simple().to_string()[..6]);
        let service = RemotePairingLockdownService::connect(&provider)
            .await
            .map_err(failed("start pairing for iOS 17.4 and later"))?;
        let mut client = service.into_client(&host).map_err(|_| SetupError::Device {
            doing: "start pairing for iOS 17.4 and later",
            detail: "the device closed the connection".into(),
        })?;
        let mut file = RpPairingFile::generate(&host);
        client
            .connect(&mut file, async || "000000".to_string())
            .await
            .map_err(failed("pair for iOS 17.4 and later"))?;
        Some(
            Value::from_reader(std::io::Cursor::new(file.to_bytes()))
                .ok()
                .and_then(Value::into_dictionary)
                .ok_or(pairing::PairingFileError::NotAPropertyList)?,
        )
    } else {
        None
    };

    let bytes = pairing::merge(lockdown_record, remote_record);
    pairing::check_for(&bytes, &device.version)?;
    Ok(bytes)
}

fn inbox_path() -> String {
    inbox_file(pairing::INBOX_FILE)
}

fn inbox_file(name: &str) -> String {
    format!("/{}/{name}", pairing::INBOX_DIRECTORIES.join("/"))
}

/// Installs an app that is already signed for this device: an `.ipa`, or an
/// unpacked `.app` folder.
pub async fn install_app(device: &Device, package: &std::path::Path) -> Result<(), SetupError> {
    let provider = provider(device).await?;
    idevice::utils::installation::install_package(&provider, package, None)
        .await
        .map_err(failed("install the app"))
}

/// Leaves the signing certificate and key where Harbor looks for them.
pub async fn deliver_identity(
    device: &Device,
    harbor: &InstalledHarbor,
    identity: &[u8],
) -> Result<(), SetupError> {
    write_to_inbox(device, harbor, pairing::IDENTITY_INBOX_FILE, identity).await
}

/// Leaves a pairing file where Harbor looks for one.
///
/// The file is checked first, and read back afterwards: the device holding
/// a damaged copy would only show up later, as Harbor failing to connect.
pub async fn deliver_pairing_file(
    device: &Device,
    harbor: &InstalledHarbor,
    file: &[u8],
) -> Result<(), SetupError> {
    pairing::check_for(file, &device.version)?;
    write_to_inbox(device, harbor, pairing::INBOX_FILE, file).await
}

/// Writes a file into Harbor's inbox and reads it back to be sure of it.
async fn write_to_inbox(
    device: &Device,
    harbor: &InstalledHarbor,
    name: &str,
    file: &[u8],
) -> Result<(), SetupError> {
    let provider = provider(device).await?;
    let house_arrest = HouseArrestClient::connect(&provider)
        .await
        .map_err(failed("open Harbor's storage on the device"))?;
    // The whole container, not just Documents: the inbox is outside it.
    let mut files = house_arrest
        .vend_container(harbor.bundle_identifier.clone())
        .await
        .map_err(failed("open Harbor's storage on the device"))?;

    let mut directory = String::new();
    for part in pairing::INBOX_DIRECTORIES {
        directory.push('/');
        directory.push_str(part);
        // Fails when the folder is already there, which is fine.
        let _ = files.mk_dir(directory.clone()).await;
    }

    let path = inbox_file(name);
    let mut handle = files
        .open(path.clone(), AfcFopenMode::WrOnly)
        .await
        .map_err(failed("write to Harbor's storage on the device"))?;
    handle
        .write_entire(file)
        .await
        .map_err(failed("write to Harbor's storage on the device"))?;
    handle.close().await.map_err(failed("write to Harbor's storage on the device"))?;

    let mut handle = files
        .open(path, AfcFopenMode::RdOnly)
        .await
        .map_err(failed("read back from Harbor's storage on the device"))?;
    let written = handle
        .read_entire()
        .await
        .map_err(failed("read back from Harbor's storage on the device"))?;
    let _ = handle.close().await;
    if written != file {
        return Err(SetupError::Device {
            doing: "write to Harbor's storage on the device",
            detail: "what the device holds is not what was sent".into(),
        });
    }
    Ok(())
}

/// Whether a pairing file is still waiting for Harbor to take it. Harbor
/// deletes the file once it has stored it, so `false` after a delivery means
/// Harbor has it.
pub async fn pairing_file_waiting(
    device: &Device,
    harbor: &InstalledHarbor,
) -> Result<bool, SetupError> {
    let provider = provider(device).await?;
    let house_arrest = HouseArrestClient::connect(&provider)
        .await
        .map_err(failed("open Harbor's storage on the device"))?;
    let mut files = house_arrest
        .vend_container(harbor.bundle_identifier.clone())
        .await
        .map_err(failed("open Harbor's storage on the device"))?;
    Ok(files.get_file_info(inbox_path()).await.is_ok())
}
