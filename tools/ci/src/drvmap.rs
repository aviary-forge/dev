//! Drvmap types, loading, and diffing.
//!
//! A drvmap maps `treePath → TargetInfo` and is the interface between
//! Nix (discovery) and Rust (orchestration).

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Owner information for a target (Discord/GitHub).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Owner {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discord: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub github: Option<String>,
}

/// Per-target metadata stored in the drvmap.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TargetInfo {
    /// The Nix derivation path (e.g. /nix/store/...-foo.drv).
    #[serde(rename = "drvPath")]
    pub drv_path: String,

    /// Nix attribute path from the repo root (e.g. ["rust", "ci"]).
    #[serde(rename = "attrPath", default, skip_serializing_if = "Vec::is_empty")]
    pub attr_path: Vec<String>,

    /// The system this derivation builds on (e.g. "aarch64-darwin").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,

    /// Config type tag ("nixos-system", "darwin-system", "home-manager-system").
    #[serde(
        rename = "devAttrType",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub dev_attr_type: Option<String>,

    /// Owners for notification dispatch.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub owners: Vec<Owner>,

    /// Tree paths this target depends on (forward deps).
    /// Used for reverse-dependency computation when marking skipped targets.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub deps: Vec<String>,

    /// Per-output store paths, keyed by output name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub outputs: BTreeMap<String, String>,
}

/// The full drvmap: treePath → TargetInfo.
pub type Drvmap = BTreeMap<String, TargetInfo>;

/// A diff result: targets that changed between parent and current.
#[derive(Debug)]
pub struct DrvmapDiff {
    /// Targets present in current but not in parent (new targets).
    pub added: Drvmap,
    /// Targets where drvPath differs between parent and current.
    pub changed: Drvmap,
    /// Target treePaths present in both, unchanged.
    pub unchanged: Drvmap,
    /// Targets present in parent but not in current (removed).
    pub removed: Drvmap,
}

impl DrvmapDiff {
    /// All targets that need building: added ∪ changed.
    pub fn to_build(&self) -> Drvmap {
        let mut build = self.changed.clone();
        build.extend(self.added.clone());
        build
    }

    /// Total number of changed or added targets.
    pub fn changed_count(&self) -> usize {
        self.added.len() + self.changed.len()
    }
}

/// Load a drvmap from a JSON file on disk.
pub fn load(path: &Path) -> Result<Drvmap> {
    let data = std::fs::read_to_string(path)
        .with_context(|| format!("reading drvmap from {}", path.display()))?;
    serde_json::from_str(&data).with_context(|| format!("parsing drvmap from {}", path.display()))
}

/// Parse a drvmap from a JSON string (e.g. stdout of nix-instantiate).
pub fn parse(json: &str) -> Result<Drvmap> {
    serde_json::from_str(json).context("parsing drvmap JSON")
}

/// Compute the diff between a parent drvmap and the current drvmap.
///
/// A target is considered "changed" if its drvPath differs between
/// parent and current. New targets (in current but not parent) are
/// returned as `added`. Removed targets (in parent but not current)
/// are returned as `removed`.
pub fn diff(parent: &Drvmap, current: &Drvmap) -> DrvmapDiff {
    let mut added = Drvmap::new();
    let mut changed = Drvmap::new();
    let mut unchanged = Drvmap::new();
    let mut removed = Drvmap::new();

    for (tree_path, current_info) in current {
        match parent.get(tree_path) {
            None => {
                added.insert(tree_path.clone(), current_info.clone());
            },
            Some(parent_info) => {
                if parent_info.drv_path == current_info.drv_path {
                    unchanged.insert(tree_path.clone(), current_info.clone());
                } else {
                    changed.insert(tree_path.clone(), current_info.clone());
                }
            },
        }
    }

    for (tree_path, parent_info) in parent {
        if !current.contains_key(tree_path) {
            removed.insert(tree_path.clone(), parent_info.clone());
        }
    }

    DrvmapDiff {
        added,
        changed,
        unchanged,
        removed,
    }
}

/// Group targets by their `system` field. Targets without a system
/// are placed under the empty-string key.
pub fn group_by_system(drvmap: &Drvmap) -> BTreeMap<String, Drvmap> {
    let mut groups: BTreeMap<String, Drvmap> = BTreeMap::new();
    for (tree_path, info) in drvmap {
        let system = info.system.clone().unwrap_or_default();
        groups
            .entry(system)
            .or_default()
            .insert(tree_path.clone(), info.clone());
    }
    groups
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_info(drv_path: &str, system: &str) -> TargetInfo {
        TargetInfo {
            drv_path: drv_path.to_string(),
            attr_path: vec![],
            system: Some(system.to_string()),
            owners: vec![],
            deps: vec![],
            outputs: BTreeMap::new(),
            dev_attr_type: None,
        }
    }

    fn make_drvmap(entries: Vec<(&str, &str, &str)>) -> Drvmap {
        entries
            .into_iter()
            .map(|(tree_path, drv_path, system)| {
                (tree_path.to_string(), make_info(drv_path, system))
            })
            .collect()
    }

    #[test]
    fn test_diff_added() {
        let parent = Drvmap::new();
        let current = make_drvmap(vec![("a", "/nix/store/a.drv", "x86_64-linux")]);
        let diff = diff(&parent, &current);
        assert_eq!(diff.added.len(), 1);
        assert_eq!(diff.changed.len(), 0);
        assert_eq!(diff.unchanged.len(), 0);
        assert_eq!(diff.removed.len(), 0);
    }

    #[test]
    fn test_diff_changed() {
        let parent = make_drvmap(vec![("a", "/nix/store/a-v1.drv", "x86_64-linux")]);
        let current = make_drvmap(vec![("a", "/nix/store/a-v2.drv", "x86_64-linux")]);
        let diff = diff(&parent, &current);
        assert_eq!(diff.added.len(), 0);
        assert_eq!(diff.changed.len(), 1);
        assert_eq!(diff.unchanged.len(), 0);
        assert_eq!(diff.removed.len(), 0);
    }

    #[test]
    fn test_diff_unchanged() {
        let parent = make_drvmap(vec![("a", "/nix/store/a.drv", "x86_64-linux")]);
        let current = parent.clone();
        let diff = diff(&parent, &current);
        assert_eq!(diff.changed_count(), 0);
        assert_eq!(diff.unchanged.len(), 1);
    }

    #[test]
    fn test_diff_removed() {
        let parent = make_drvmap(vec![("a", "/nix/store/a.drv", "x86_64-linux")]);
        let current = Drvmap::new();
        let diff = diff(&parent, &current);
        assert_eq!(diff.removed.len(), 1);
    }

    #[test]
    fn test_group_by_system() {
        let drvmap = make_drvmap(vec![
            ("a", "/nix/store/a.drv", "x86_64-linux"),
            ("b", "/nix/store/b.drv", "aarch64-darwin"),
            ("c", "/nix/store/c.drv", "x86_64-linux"),
        ]);
        let groups = group_by_system(&drvmap);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups["x86_64-linux"].len(), 2);
        assert_eq!(groups["aarch64-darwin"].len(), 1);
    }
}
