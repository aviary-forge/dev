//! Persistent drvmap cache shared between Buildkite agents on one machine.
//!
//! Entries are keyed by commit SHA and store the drvmap JSON plus a sidecar
//! copy of the `tools/ci/drvmap.nix` entry point that produced it. The parent
//! drvmap is evaluated with the *current branch's* drvmap.nix copied into the
//! base-commit worktree, so an entry is only valid while that entry point is
//! byte-identical — hence the sidecar equality check on load.
//!
//! Trunk builds additionally store their HEAD drvmap under its own commit SHA
//! so a feature branch whose merge-base is exactly that commit hits the cache
//! without any worktree + eval round trip.
//!
//! Everything here fails open: any I/O or parse error is logged and treated as
//! a cache miss (or a skipped store). The cache is purely an optimization;
//! correctness comes from the worktree eval.
//!
//! Multitenancy: Buildkite agents may run under different Unix users, so the
//! cache directory is created mode `0o2775` (setgid) and files are written
//! `0o664` (group-writable). The group itself must be provisioned by an admin:
//!
//! ```sh
//! sudo mkdir -p /var/cache/ci-orchestrator/drvmap-cache
//! sudo chgrp buildkite /var/cache/ci-orchestrator/drvmap-cache
//! sudo chmod 2775 /var/cache/ci-orchestrator/drvmap-cache
//! ```

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use crate::drvmap::Drvmap;

/// Repo-root-relative path to the drvmap entry point.
/// Must match `instantiate::DRVMAP_EXPR`.
const DRVMAP_EXPR: &str = "tools/ci/drvmap.nix";

/// Default cache location (shared, group-writable, setgid).
const DEFAULT_CACHE_DIR: &str = "/var/cache/ci-orchestrator/drvmap-cache";

/// File mode for cache entries (group-writable, relies on the setgid bit of
/// the parent directory for group inheritance).
const FILE_MODE: u32 = 0o664;
/// File mode for the cache directory itself (setgid + group-writable).
const DIR_MODE: u32 = 0o2775;

/// A handle to the drvmap cache. `dir` is `None` when the cache is unusable
/// (e.g. unwritable location); all operations then no-op with a warning.
pub struct DrvmapCache {
    dir: Option<PathBuf>,
}

impl DrvmapCache {
    /// Open (and create, best-effort) the cache directory.
    pub fn open() -> Self {
        let dir = match std::env::var("CI_DRVMAP_CACHE_DIR") {
            Ok(dir) => PathBuf::from(dir),
            Err(_) => PathBuf::from(DEFAULT_CACHE_DIR),
        };

        match ensure_dir(&dir) {
            Ok(()) => {
                tracing::debug!("drvmap cache dir: {}", dir.display());
                Self { dir: Some(dir) }
            },
            Err(err) => {
                tracing::warn!(
                    "drvmap cache unavailable ({}); proceeding without cache",
                    err
                );
                Self { dir: None }
            },
        }
    }

    /// Load a cached drvmap for `commit`, valid only if the sidecar entry-point
    /// content matches `entry_point` byte-for-byte.
    pub fn load(&self, commit: &str, entry_point: Option<&[u8]>) -> Option<Drvmap> {
        let dir = self.dir.as_ref()?;
        let entry_point = entry_point?;

        let sidecar = fs::read(sidecar_path(dir, commit)).ok()?;
        if sidecar != entry_point {
            tracing::info!(
                "drvmap cache entry for {commit} is stale (entry point changed); ignoring"
            );
            return None;
        }

        let json = match fs::read(json_path(dir, commit)) {
            Ok(json) => json,
            Err(err) => {
                tracing::warn!("drvmap cache entry for {commit} unreadable: {err}");
                return None;
            },
        };

        match serde_json::from_slice(&json) {
            Ok(drvmap) => Some(drvmap),
            Err(err) => {
                tracing::warn!("drvmap cache entry for {commit} corrupt: {err}");
                None
            },
        }
    }

    /// Store a drvmap for `commit` along with the entry-point content that
    /// produced it. Silently skips when the cache is unavailable or the entry
    /// point wasn't readable.
    pub fn store(&self, commit: &str, entry_point: Option<&[u8]>, drvmap: &Drvmap) {
        let (Some(dir), Some(entry_point)) = (self.dir.as_ref(), entry_point) else {
            return;
        };

        let json = match serde_json::to_vec_pretty(drvmap) {
            Ok(json) => json,
            Err(err) => {
                tracing::warn!("drvmap cache: serializing drvmap for {commit}: {err}");
                return;
            },
        };

        if let Err(err) = write_atomic(&sidecar_path(dir, commit), entry_point) {
            tracing::warn!("drvmap cache: storing sidecar for {commit}: {err}");
            return;
        }
        if let Err(err) = write_atomic(&json_path(dir, commit), &json) {
            tracing::warn!("drvmap cache: storing drvmap for {commit}: {err}");
        }
    }
}

fn json_path(dir: &std::path::Path, commit: &str) -> PathBuf {
    dir.join(format!("{commit}.json"))
}

fn sidecar_path(dir: &std::path::Path, commit: &str) -> PathBuf {
    dir.join(format!("{commit}.drvmap-nix"))
}

/// Create the cache directory with setgid group-shared permissions.
fn ensure_dir(dir: &std::path::Path) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(DIR_MODE))
}

/// Write via a temp file + rename so concurrent readers never see a partial
/// entry. Rename-over is atomic on POSIX.
fn write_atomic(path: &std::path::Path, contents: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!(
        "tmp-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(contents)?;
        file.set_permissions(fs::Permissions::from_mode(FILE_MODE))?;
        file.sync_all().ok();
    }
    fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unique temp dir for a test run; the caller is expected to clean up.
    fn test_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ci-cache-test-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_drvmap() -> Drvmap {
        let mut map = Drvmap::new();
        map.insert(
            "test/target".to_string(),
            crate::drvmap::TargetInfo {
                drv_path: "/nix/store/test.drv".to_string(),
                attr_path: vec![],
                system: Some("x86_64-linux".to_string()),
                dev_attr_type: None,
                owners: vec![],
                deps: vec![],
                outputs: Default::default(),
            },
        );
        map
    }

    #[test]
    fn test_store_load_roundtrip() {
        let dir = test_dir("roundtrip");
        let cache = DrvmapCache {
            dir: Some(dir.clone()),
        };
        let entry_point = b"{ dev ? import ../.. {} }: ...";

        cache.store("abc123", Some(entry_point), &make_drvmap());
        let loaded = cache.load("abc123", Some(entry_point)).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["test/target"].drv_path, "/nix/store/test.drv");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_entry_point_change_is_miss() {
        let dir = test_dir("stale");
        let cache = DrvmapCache {
            dir: Some(dir.clone()),
        };

        cache.store("abc123", Some(b"old entry point"), &make_drvmap());
        assert!(cache.load("abc123", Some(b"new entry point")).is_none());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_no_entry_point_skips_cache() {
        let dir = test_dir("nopoint");
        let cache = DrvmapCache {
            dir: Some(dir.clone()),
        };

        cache.store("abc123", None, &make_drvmap());
        assert!(cache.load("abc123", Some(b"anything")).is_none());
        assert!(!dir.join("abc123.json").exists());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_corrupt_json_is_miss() {
        let dir = test_dir("corrupt");
        fs::write(json_path(&dir, "abc123"), "not json{{{").unwrap();
        let cache = DrvmapCache {
            dir: Some(dir.clone()),
        };

        assert!(cache.load("abc123", Some(b"ep")).is_none());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_unavailable_cache_noops() {
        let cache = DrvmapCache { dir: None };
        cache.store("abc123", Some(b"ep"), &make_drvmap());
        assert!(cache.load("abc123", Some(b"ep")).is_none());
    }

    #[test]
    fn test_default_expr_matches_instantiate() {
        assert_eq!(DRVMAP_EXPR, crate::instantiate::DRVMAP_EXPR);
    }
}
