//! Merge-base drvmap cache — avoids re-evaluating the parent drvmap
//! when the same merge-base commit is hit across repeated branch pushes.
//!
//! ## Design
//!
//! The parent drvmap is a deterministic function of:
//! 1. The merge-base commit's Nix code
//! 2. The current checkout's `tools/ci/drvmap.nix` entry point
//!
//! Cache files are named `{base_commit_sha}.json` and contain the
//! drvmap payload plus the full content of `drvmap.nix` at cache time.
//! On lookup, if the current `drvmap.nix` content differs from the
//! cached content, the entry is treated as stale (cache miss).
//!
//! ## Multitenancy
//!
//! Buildkite agents may run under different Unix users.  The cache
//! directory should be pre-created with a shared group and the setgid
//! bit so that all agents can read and write:
//!
//! ```bash
//! sudo mkdir -p /var/cache/ci-orchestrator/drvmap-cache
//! sudo chgrp buildkite /var/cache/ci-orchestrator/drvmap-cache
//! sudo chmod 2775 /var/cache/ci-orchestrator/drvmap-cache
//! ```
//!
//! The binary creates files with mode `0o664` (group-writable) and
//! relies on the directory's setgid bit to inherit the group.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::drvmap::Drvmap;

/// Wrapper stored on disk: the parent drvmap plus the drvmap.nix content
/// that was used to produce it, for staleness detection.
#[derive(Serialize, Deserialize)]
struct CachedParent {
    /// Full content of `tools/ci/drvmap.nix` at cache-write time.
    drvmap_nix_content: String,
    /// The parent drvmap.
    drvmap: Drvmap,
}

/// Resolve the cache directory.
///
/// Uses `CI_DRVMAP_CACHE_DIR` env var if set, otherwise defaults to
/// `/var/cache/ci-orchestrator/drvmap-cache`.
pub fn cache_dir() -> PathBuf {
    std::env::var("CI_DRVMAP_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/var/cache/ci-orchestrator/drvmap-cache"))
}

/// Ensure the cache directory exists with group-friendly permissions.
///
/// On Unix, sets mode `0o2775` (setgid + rwxrwxr-x) so that files
/// created inside inherit the directory's group.
fn ensure_cache_dir(dir: &Path) -> Result<()> {
    if dir.exists() {
        return Ok(());
    }

    std::fs::create_dir_all(dir)
        .with_context(|| format!("creating cache directory {}", dir.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let meta = std::fs::metadata(dir)?;
        let mut perms = meta.permissions();
        perms.set_mode(0o2775);
        std::fs::set_permissions(dir, perms)?;
    }

    Ok(())
}

/// Try to load a cached parent drvmap for the given base commit.
///
/// Returns `Ok(None)` when:
/// - No cache file exists for this commit
/// - The cached `drvmap.nix` content doesn't match the current one
/// - The cache file can't be parsed
pub fn load_cached_parent(commit: &str, drvmap_nix_content: &str) -> Result<Option<Drvmap>> {
    let dir = cache_dir();
    let cache_path = dir.join(format!("{}.json", commit));

    if !cache_path.exists() {
        tracing::debug!("no cache file at {}", cache_path.display());
        return Ok(None);
    }

    let data = std::fs::read_to_string(&cache_path)
        .with_context(|| format!("reading cache file {}", cache_path.display()))?;

    let cached: CachedParent = match serde_json::from_str(&data) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(
                "failed to parse cache file {}, treating as miss: {e}",
                cache_path.display()
            );
            return Ok(None);
        }
    };

    if cached.drvmap_nix_content != drvmap_nix_content {
        tracing::info!(
            "cache entry for {} has stale drvmap.nix content (length {} vs {}), ignoring",
            commit,
            cached.drvmap_nix_content.len(),
            drvmap_nix_content.len(),
        );
        return Ok(None);
    }

    tracing::info!(
        "cache hit for base commit {} ({} targets)",
        commit,
        cached.drvmap.len(),
    );
    Ok(Some(cached.drvmap))
}

/// Store a parent drvmap in the cache for the given base commit.
///
/// The current `drvmap.nix` content is stored alongside so future
/// lookups can detect staleness when the entry point changes.
pub fn store_cached_parent(commit: &str, drvmap_nix_content: &str, drvmap: &Drvmap) -> Result<()> {
    let dir = cache_dir();
    ensure_cache_dir(&dir)?;

    let cache_path = dir.join(format!("{}.json", commit));

    let cached = CachedParent {
        drvmap_nix_content: drvmap_nix_content.to_string(),
        drvmap: drvmap.clone(),
    };

    let json = serde_json::to_string_pretty(&cached)?;
    std::fs::write(&cache_path, &json)
        .with_context(|| format!("writing cache file {}", cache_path.display()))?;

    // Set mode 0o664: user rw, group rw, other r.
    // The containing directory's setgid bit ensures the group is inherited.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let meta = std::fs::metadata(&cache_path)?;
        let mut perms = meta.permissions();
        perms.set_mode(0o664);
        std::fs::set_permissions(&cache_path, perms)?;
    }

    tracing::info!(
        "cached parent drvmap ({} targets) for commit {}",
        drvmap.len(),
        commit,
    );

    Ok(())
}

/// Remove all but the `retain` most recently modified cache entries.
/// Returns the number of files deleted.
pub fn clean(retain: usize) -> Result<usize> {
    let dir = cache_dir();

    if !dir.exists() {
        tracing::info!(
            "cache directory {} does not exist, nothing to clean",
            dir.display()
        );
        return Ok(0);
    }

    // Collect all .json cache files with their modification times.
    let mut entries: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(&dir)
        .with_context(|| format!("reading cache directory {}", dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();

        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }

        let meta = std::fs::metadata(&path)?;
        let mtime = meta.modified()?;
        entries.push((mtime, path));
    }

    if entries.is_empty() || entries.len() <= retain {
        tracing::info!(
            "{} cache entries, retain is {} — nothing to clean",
            entries.len(),
            retain
        );
        return Ok(0);
    }

    // Sort by modification time, oldest first.
    entries.sort_by_key(|(a, _)| *a);

    let to_delete = entries.len() - retain;
    tracing::info!(
        "cleaning {} of {} cache entries, retaining {} most recent",
        to_delete,
        entries.len(),
        retain
    );

    let mut removed = 0;
    for (_mtime, path) in entries.iter().take(to_delete) {
        std::fs::remove_file(path)
            .with_context(|| format!("removing cache file {}", path.display()))?;
        tracing::debug!("removed {}", path.display());
        removed += 1;
    }

    tracing::info!("cleaned {} cache entries", removed);
    Ok(removed)
}
