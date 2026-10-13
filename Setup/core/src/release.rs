//! Checking a copy of Harbor before it goes on a phone.
//!
//! The installers Harbor grew out of download an app and install whatever
//! arrives. Setup installs a file only when it is, byte for byte, the build
//! it was told to expect.

use std::{fmt, fs::File, io::Read, path::Path};

use sha2::{Digest, Sha256};
use thiserror::Error;

/// A SHA-256 digest.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Sha256Digest(pub [u8; 32]);

impl Sha256Digest {
    /// Reads 64 hexadecimal characters. Anything else is `None`.
    pub fn from_hex(text: &str) -> Option<Self> {
        let text = text.trim();
        if text.len() != 64 || !text.is_ascii() {
            return None;
        }
        let mut bytes = [0u8; 32];
        for (index, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16).ok()?;
        }
        Some(Self(bytes))
    }

    pub fn of_file(path: &Path) -> std::io::Result<Self> {
        let mut file = File::open(path)?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; 1 << 20];
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        Ok(Self(hasher.finalize().into()))
    }

    pub fn hex(&self) -> String {
        self.0.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}

impl fmt::Debug for Sha256Digest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "Sha256Digest({})", self.hex())
    }
}

impl fmt::Display for Sha256Digest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.hex())
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ReleaseError {
    #[error("cannot read {0}")]
    Unreadable(String),
    #[error("the file is not the expected build (expected {expected}, found {found})")]
    WrongContents {
        expected: Sha256Digest,
        found: Sha256Digest,
    },
}

/// What checking a file found.
#[derive(Debug, PartialEq, Eq)]
pub enum Checked {
    /// The file is the build that was expected.
    Verified(Sha256Digest),
    /// Nothing was given to check it against. The caller has to say so to
    /// the user; this is never treated as verified.
    Unverified(Sha256Digest),
}

/// Checks a file against the digest it should have. A mismatch is always an
/// error: there is no mode that warns and carries on.
pub fn check(path: &Path, expected: Option<Sha256Digest>) -> Result<Checked, ReleaseError> {
    let found = Sha256Digest::of_file(path)
        .map_err(|error| ReleaseError::Unreadable(format!("{}: {error}", path.display())))?;
    match expected {
        None => Ok(Checked::Unverified(found)),
        Some(expected) if expected == found => Ok(Checked::Verified(found)),
        Some(expected) => Err(ReleaseError::WrongContents { expected, found }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // SHA-256 of the three bytes "abc".
    const ABC: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    fn file_holding(contents: &[u8]) -> tempfile::NamedTempFile {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(contents).unwrap();
        file
    }

    #[test]
    fn reads_a_digest_from_hex_and_writes_it_back() {
        let digest = Sha256Digest::from_hex(ABC).unwrap();
        assert_eq!(digest.hex(), ABC);
        assert_eq!(Sha256Digest::from_hex(&format!("  {}\n", ABC.to_uppercase())), Some(digest));
    }

    #[test]
    fn refuses_what_is_not_a_digest() {
        for text in ["", "abc", &ABC[..63], &format!("{ABC}0"), &ABC.replace('b', "z"), &ABC.replace('b', "é")] {
            assert_eq!(Sha256Digest::from_hex(text), None, "{text:?}");
        }
    }

    #[test]
    fn a_matching_file_is_verified() {
        let file = file_holding(b"abc");
        let expected = Sha256Digest::from_hex(ABC).unwrap();
        assert_eq!(check(file.path(), Some(expected)), Ok(Checked::Verified(expected)));
    }

    #[test]
    fn a_different_file_is_an_error_naming_both_digests() {
        let file = file_holding(b"abd");
        let expected = Sha256Digest::from_hex(ABC).unwrap();
        match check(file.path(), Some(expected)) {
            Err(ReleaseError::WrongContents { expected: wanted, found }) => {
                assert_eq!(wanted, expected);
                assert_ne!(found, expected);
            }
            other => panic!("expected a mismatch, got {other:?}"),
        }
    }

    #[test]
    fn with_nothing_to_compare_against_the_file_is_reported_unverified() {
        let file = file_holding(b"abc");
        assert_eq!(
            check(file.path(), None),
            Ok(Checked::Unverified(Sha256Digest::from_hex(ABC).unwrap()))
        );
    }

    #[test]
    fn a_missing_file_is_an_error() {
        let missing = std::env::temp_dir().join("harbor-setup-no-such-file.ipa");
        assert!(matches!(check(&missing, None), Err(ReleaseError::Unreadable(_))));
    }
}
