//! The PE32+ modules of a package folder and their import and export names, as
//! `emu/bench.py` and `emu/translation.py` list them. Unreadable files give empty tables, like
//! the Python code that catches pefile's errors.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::{Path, PathBuf};

use victory_pe::{ImageInfo, ImportSymbol};

use crate::dll_name;

const HEADER_PROBE: usize = 0x400;
const PE_SIGNATURE: &[u8] = b"PE\0\0";
const PE32_PLUS_MAGIC: [u8; 2] = 0x20B_u16.to_le_bytes();
const E_LFANEW: usize = 0x3C;
const MAGIC_OFFSET: usize = 24;
/// `PATTERNS` of bench.py: `*.dll` and `*.exe`, matched case-insensitively as on Windows.
const EXTENSIONS: [&str; 2] = ["dll", "exe"];

/// `bench.is_pe32_plus`: true for an x86-64 module (a 32-bit or .NET launcher is not one).
pub fn is_pe32_plus(path: &Path) -> bool {
    let Ok(file) = std::fs::File::open(path) else {
        return false;
    };
    let mut header = Vec::with_capacity(HEADER_PROBE);
    if file
        .take(HEADER_PROBE as u64)
        .read_to_end(&mut header)
        .is_err()
    {
        return false;
    }
    if header.len() < 0x40 || &header[..2] != b"MZ" {
        return false;
    }
    let pe =
        u32::from_le_bytes(header[E_LFANEW..E_LFANEW + 4].try_into().expect("4 bytes")) as usize;
    pe + MAGIC_OFFSET + 2 <= header.len()
        && &header[pe..pe + 4] == PE_SIGNATURE
        && header[pe + MAGIC_OFFSET..pe + MAGIC_OFFSET + 2] == PE32_PLUS_MAGIC
}

fn has_module_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| EXTENSIONS.iter().any(|x| e.eq_ignore_ascii_case(x)))
}

/// `translation._modules` / `bench.run`: the PE32+ modules of `folder`, sorted by lower-case name.
pub fn package_modules(folder: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| has_module_extension(p) && p.is_file() && is_pe32_plus(p))
        .collect();
    paths.sort_by_key(|p| file_name(p).to_lowercase());
    paths
}

pub fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn parse(path: &Path) -> Option<ImageInfo> {
    ImageInfo::parse(&std::fs::read(path).ok()?).ok()
}

/// How the Python reports write an imported function: its name, or `#ordinal`.
pub fn symbol_name(symbol: &ImportSymbol) -> String {
    symbol.to_string()
}

/// `translation._imported_names`: {normalised DLL: names}, ordinals written `#n`.
pub fn imported_names(path: &Path) -> BTreeMap<String, BTreeSet<String>> {
    let mut found: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for module in parse(path).map(|i| i.imports).unwrap_or_default() {
        let names = found.entry(dll_name(&module.dll)).or_default();
        names.extend(module.entries.iter().map(|e| symbol_name(&e.symbol)));
    }
    found
}

/// `translation._exported_names`: the named exports, forwarders included.
pub fn exported_names(path: &Path) -> BTreeSet<String> {
    parse(path)
        .map(|info| info.exports.into_iter().filter_map(|e| e.name).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn junk_is_not_a_module() {
        let dir = std::env::temp_dir().join(format!("anyxboxx-modules-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let junk = dir.join("notes.dll");
        std::fs::write(&junk, b"MZ not a PE").unwrap();
        assert!(!is_pe32_plus(&junk));
        assert!(!is_pe32_plus(&dir.join("absent.dll")));
        assert!(package_modules(&dir).is_empty());
        assert!(imported_names(&junk).is_empty() && exported_names(&junk).is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn extensions_match_without_case() {
        assert!(has_module_extension(Path::new("GAME.EXE")));
        assert!(has_module_extension(Path::new("a.Dll")));
        assert!(!has_module_extension(Path::new("a.sys")));
    }
}
