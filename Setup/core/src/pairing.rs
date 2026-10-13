//! The pairing file: what it is made of, and whether one is complete.
//!
//! A pairing file lets whoever holds it talk to the phone's own services:
//! install apps, read data. Harbor keeps one so it can install and renew
//! apps on the phone it runs on. It carries up to two sets of credentials in
//! one property list: the classic lockdown record, and the RemotePairing
//! record that iOS 17.4 and later use.
//!
//! The rules here match the ones Harbor applies when it reads the file
//! (`PairingRecord` in HarborCore), so Setup never hands over a file Harbor
//! would refuse.

use plist::{Dictionary, Value};
use thiserror::Error;

/// Every key of a complete lockdown record.
pub const LOCKDOWN_KEYS: [&str; 10] = [
    "DeviceCertificate",
    "EscrowBag",
    "HostCertificate",
    "HostID",
    "HostPrivateKey",
    "RootCertificate",
    "RootPrivateKey",
    "SystemBUID",
    "UDID",
    "WiFiMACAddress",
];

/// Every key of a complete RemotePairing record.
pub const REMOTE_PAIRING_KEYS: [&str; 3] = ["identifier", "private_key", "public_key"];

/// Where in Harbor's own container Setup leaves the file, and Harbor looks
/// for it. Harbor moves it into the keychain and deletes it the next time it
/// opens. The folder is outside Documents, which is where apps running
/// inside Harbor keep their files.
pub const INBOX_DIRECTORIES: [&str; 3] = ["Library", "Application Support", "Harbor"];
pub const INBOX_FILE: &str = "pairing-from-setup.plist";
/// The signing certificate and its key, left the same way. Harbor was signed
/// with it, and needs it to sign the apps it runs.
pub const IDENTITY_INBOX_FILE: &str = "identity-from-setup.p12";

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PairingFileError {
    #[error("the pairing file is not a property list")]
    NotAPropertyList,
    #[error("the pairing file is incomplete (lockdown is missing {lockdown:?}, RemotePairing is missing {remote_pairing:?})")]
    Incomplete {
        lockdown: Vec<&'static str>,
        remote_pairing: Vec<&'static str>,
    },
    #[error("this version of iOS needs RemotePairing credentials and the file has none")]
    RemotePairingRequired,
    /// A field is there but is not what it should be.
    #[error("the pairing file's {0} is not valid")]
    InvalidField(&'static str),
}

/// What a pairing file holds, without any of its secrets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    pub has_lockdown: bool,
    pub has_remote_pairing: bool,
    /// The device the lockdown record is for.
    pub udid: Option<String>,
}

/// iOS 17.4 and later talk to an app on the device through RemotePairing.
/// A version that cannot be read is taken to be a new one.
pub fn needs_remote_pairing(ios_version: &str) -> bool {
    let mut parts = ios_version.split('.').map(|part| {
        part.chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>()
            .parse::<u32>()
            .ok()
    });
    match (parts.next().flatten(), parts.next().flatten()) {
        (Some(major), minor) => (major, minor.unwrap_or(0)) >= (17, 4),
        (None, _) => true,
    }
}

/// Puts the two records in one property list, as XML.
pub fn merge(lockdown: Dictionary, remote_pairing: Option<Dictionary>) -> Vec<u8> {
    let mut merged = lockdown;
    if let Some(remote_pairing) = remote_pairing {
        for (key, value) in remote_pairing {
            merged.insert(key, value);
        }
    }
    let mut bytes = Vec::new();
    // Writing a dictionary of plist values to memory cannot fail.
    Value::Dictionary(merged)
        .to_writer_xml(&mut bytes)
        .expect("a property list can be written to memory");
    bytes
}

/// Reads a pairing file and says what it holds. A file with neither record
/// complete is an error.
pub fn inspect(bytes: &[u8]) -> Result<Summary, PairingFileError> {
    let dictionary = Value::from_reader(std::io::Cursor::new(bytes))
        .ok()
        .and_then(Value::into_dictionary)
        .ok_or(PairingFileError::NotAPropertyList)?;

    let missing = |keys: &[&'static str]| -> Vec<&'static str> {
        keys.iter().copied().filter(|key| !dictionary.contains_key(key)).collect()
    };
    let lockdown = missing(&LOCKDOWN_KEYS);
    let remote_pairing = missing(&REMOTE_PAIRING_KEYS);
    if !lockdown.is_empty() && !remote_pairing.is_empty() {
        return Err(PairingFileError::Incomplete { lockdown, remote_pairing });
    }

    let has_lockdown = lockdown.is_empty();
    let has_remote_pairing = remote_pairing.is_empty();
    if has_lockdown {
        check_lockdown(&dictionary)?;
    }
    if has_remote_pairing {
        check_remote_pairing(&dictionary)?;
    }

    Ok(Summary {
        has_lockdown,
        has_remote_pairing,
        udid: dictionary.get("UDID").and_then(Value::as_string).map(str::to_owned),
    })
}

fn text<'a>(record: &'a Dictionary, key: &'static str) -> Result<&'a str, PairingFileError> {
    match record.get(key).and_then(Value::as_string) {
        Some(value) if !value.is_empty() => Ok(value),
        _ => Err(PairingFileError::InvalidField(key)),
    }
}

fn data<'a>(record: &'a Dictionary, key: &'static str) -> Result<&'a [u8], PairingFileError> {
    match record.get(key).and_then(Value::as_data) {
        Some(value) if !value.is_empty() => Ok(value),
        _ => Err(PairingFileError::InvalidField(key)),
    }
}

/// Certificates and keys are PEM text inside a data value.
fn pem(record: &Dictionary, key: &'static str, label: &str) -> Result<(), PairingFileError> {
    let value = std::str::from_utf8(data(record, key)?).map_err(|_| PairingFileError::InvalidField(key))?;
    if value.starts_with("-----BEGIN ") && value.contains(&format!("{label}-----")) {
        Ok(())
    } else {
        Err(PairingFileError::InvalidField(key))
    }
}

/// 40 hexadecimal characters, or the newer 8-16 form.
fn is_device_identifier(value: &str) -> bool {
    let parts: Vec<&str> = value.split('-').collect();
    let lengths: Vec<usize> = parts.iter().map(|part| part.len()).collect();
    (lengths == [40] || lengths == [8, 16])
        && parts.iter().all(|part| part.chars().all(|character| character.is_ascii_hexdigit()))
}

fn check_lockdown(record: &Dictionary) -> Result<(), PairingFileError> {
    for key in ["DeviceCertificate", "HostCertificate", "RootCertificate"] {
        pem(record, key, "CERTIFICATE")?;
    }
    for key in ["HostPrivateKey", "RootPrivateKey"] {
        pem(record, key, "PRIVATE KEY")?;
    }
    data(record, "EscrowBag")?;
    text(record, "HostID")?;
    text(record, "SystemBUID")?;
    if !is_device_identifier(text(record, "UDID")?) {
        return Err(PairingFileError::InvalidField("UDID"));
    }
    Ok(())
}

fn check_remote_pairing(record: &Dictionary) -> Result<(), PairingFileError> {
    text(record, "identifier")?;
    data(record, "private_key")?;
    data(record, "public_key")?;
    Ok(())
}

/// Checks a file is what Harbor on this version of iOS can use.
pub fn check_for(bytes: &[u8], ios_version: &str) -> Result<Summary, PairingFileError> {
    let summary = inspect(bytes)?;
    if needs_remote_pairing(ios_version) && !summary.has_remote_pairing {
        return Err(PairingFileError::RemotePairingRequired);
    }
    Ok(summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lockdown() -> Dictionary {
        let mut record = Dictionary::new();
        for key in ["DeviceCertificate", "HostCertificate", "RootCertificate"] {
            record.insert(key.into(), Value::Data(b"-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
".to_vec()));
        }
        for key in ["HostPrivateKey", "RootPrivateKey"] {
            record.insert(key.into(), Value::Data(b"-----BEGIN RSA PRIVATE KEY-----
MIIE
-----END RSA PRIVATE KEY-----
".to_vec()));
        }
        record.insert("EscrowBag".into(), Value::Data(vec![1, 2, 3]));
        record.insert("HostID".into(), Value::String("5E1F0C5E-0D0B-4E0C-9A5C-6C1B6C0D7A11".into()));
        record.insert("SystemBUID".into(), Value::String("30142955-444094379208051516".into()));
        record.insert("UDID".into(), Value::String("00008140-001C48A2347B001C".into()));
        record.insert("WiFiMACAddress".into(), Value::String("aa:bb:cc:dd:ee:ff".into()));
        record
    }

    fn remote_pairing() -> Dictionary {
        let mut record = Dictionary::new();
        record.insert("identifier".into(), Value::String("harbor-setup-abc123".into()));
        record.insert("private_key".into(), Value::Data(vec![1; 32]));
        record.insert("public_key".into(), Value::Data(vec![2; 32]));
        record
    }

    #[test]
    fn remote_pairing_is_needed_from_ios_17_4() {
        for version in ["17.4", "17.4.1", "17.10", "18.0", "26.4", "27.0", "27"] {
            assert!(needs_remote_pairing(version), "{version}");
        }
        for version in ["17.3.1", "17.0", "16.7.10", "15"] {
            assert!(!needs_remote_pairing(version), "{version}");
        }
    }

    #[test]
    fn a_version_that_cannot_be_read_is_taken_to_be_new() {
        for version in ["", "beta", "?.4"] {
            assert!(needs_remote_pairing(version), "{version:?}");
        }
        // A build suffix after the number is still a number.
        assert!(needs_remote_pairing("27.0b3"));
        assert!(!needs_remote_pairing("17.3b3"));
    }

    #[test]
    fn merging_keeps_every_key_of_both_records() {
        let bytes = merge(lockdown(), Some(remote_pairing()));
        let summary = inspect(&bytes).unwrap();

        assert!(summary.has_lockdown);
        assert!(summary.has_remote_pairing);
        assert_eq!(summary.udid.as_deref(), Some("00008140-001C48A2347B001C"));
        // XML, which is the form Harbor's device transport takes.
        assert!(bytes.starts_with(b"<?xml"));
    }

    #[test]
    fn a_lockdown_record_alone_is_enough_before_ios_17_4() {
        let bytes = merge(lockdown(), None);
        assert!(check_for(&bytes, "16.7").is_ok());
        assert_eq!(check_for(&bytes, "27.0"), Err(PairingFileError::RemotePairingRequired));
    }

    #[test]
    fn a_remote_pairing_record_alone_is_complete() {
        let bytes = merge(remote_pairing(), None);
        let summary = check_for(&bytes, "27.0").unwrap();
        assert!(!summary.has_lockdown);
        assert_eq!(summary.udid, None);
    }

    #[test]
    fn a_file_with_neither_record_complete_names_what_is_missing() {
        let mut partial = lockdown();
        partial.remove("EscrowBag");
        partial.insert("identifier".into(), Value::String("x".into()));

        match inspect(&merge(partial, None)) {
            Err(PairingFileError::Incomplete { lockdown, remote_pairing }) => {
                assert_eq!(lockdown, vec!["EscrowBag"]);
                assert_eq!(remote_pairing, vec!["private_key", "public_key"]);
            }
            other => panic!("expected an incomplete file, got {other:?}"),
        }
    }

    #[test]
    fn fields_of_the_wrong_shape_are_refused_as_harbor_would_refuse_them() {
        let broken: [(&str, Value); 6] = [
            ("HostCertificate", Value::Data(b"not a certificate".to_vec())),
            ("HostPrivateKey", Value::Data(b"-----BEGIN CERTIFICATE-----".to_vec())),
            ("RootCertificate", Value::String("-----BEGIN CERTIFICATE-----".into())),
            ("EscrowBag", Value::Data(vec![])),
            ("UDID", Value::String("not-a-device".into())),
            ("SystemBUID", Value::String(String::new())),
        ];
        for (key, value) in broken {
            let mut record = lockdown();
            record.insert(key.into(), value);
            assert_eq!(
                inspect(&merge(record, None)).unwrap_err().to_string(),
                format!("the pairing file's {key} is not valid"),
            );
        }

        let mut record = remote_pairing();
        record.insert("public_key".into(), Value::Data(vec![]));
        assert_eq!(inspect(&merge(record, None)), Err(PairingFileError::InvalidField("public_key")));
    }

    #[test]
    fn both_forms_of_device_identifier_are_accepted() {
        assert!(is_device_identifier("00008140-001C48A2347B001C"));
        assert!(is_device_identifier(&"a1".repeat(20)));
        for wrong in ["", "00008140", "00008140-001C48A2347B001", "0000814G-001C48A2347B001C", &"a1".repeat(21)] {
            assert!(!is_device_identifier(wrong), "{wrong:?}");
        }
    }

    #[test]
    fn something_that_is_not_a_property_list_is_refused() {
        assert_eq!(inspect(b"not a plist"), Err(PairingFileError::NotAPropertyList));
        assert_eq!(inspect(b""), Err(PairingFileError::NotAPropertyList));
        // A property list, but not a dictionary.
        let mut array = Vec::new();
        Value::Array(vec![]).to_writer_xml(&mut array).unwrap();
        assert_eq!(inspect(&array), Err(PairingFileError::NotAPropertyList));
    }
}
