//! Run `nix-store --realise` with `--log-format internal-json` and parse
//! the `@nix {...}` JSON line stream into per-target build events.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

/// A parsed `@nix {...}` log line.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NixLogLine {
    pub action: Option<String>,
    pub fields: Option<Vec<serde_json::Value>>,
    pub id: Option<i64>,
    #[allow(dead_code)]
    pub level: Option<i32>,
    #[allow(dead_code)]
    pub parent: Option<i64>,
    #[allow(dead_code)]
    pub text: Option<String>,
    #[serde(rename = "type")]
    pub type_: Option<i64>,
}

/// Status of a single build action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildStatus {
    Started,
    Succeeded,
    Failed {
        exit_code: Option<i64>,
    },
    /// Built via substitution (downloaded from a binary cache).
    #[allow(dead_code)]
    Substitution,
}

/// A build event attributed to a specific target.
#[derive(Debug, Clone)]
pub struct BuildEvent {
    /// The tree path (e.g. "rust/gcroot-manager").
    pub tree_path: String,
    /// The derivation path.
    #[allow(dead_code)]
    pub drv_path: String,
    /// The system.
    #[allow(dead_code)]
    pub system: String,
    /// What happened.
    pub status: BuildStatus,
}

/// Build a set of derivation paths using `nix-store --realise`.
///
/// `drv_paths`: the list of drvPaths to build.
/// `drv_to_tree`: mapping from drvPath → treePath (for attribution).
/// `drv_to_system`: mapping from drvPath → system.
///
/// Parses the `@nix {...}` JSON line stream and calls `on_event` for
/// each build start/stop/result event.
///
/// Returns `true` if all builds succeeded, `false` if any failed.
pub fn realise<F: FnMut(&BuildEvent)>(
    drv_paths: &[String],
    drv_to_tree: &HashMap<String, String>,
    drv_to_system: &HashMap<String, String>,
    on_event: &mut F,
) -> Result<bool> {
    if drv_paths.is_empty() {
        tracing::info!("no derivations to build");
        return Ok(true);
    }

    tracing::info!("building {} derivations", drv_paths.len());

    let mut child = Command::new("nix-store")
        .arg("--realise")
        .arg("--log-format")
        .arg("internal-json")
        .args(drv_paths)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawning nix-store --realise")?;

    let stdout = child.stdout.take().context("capturing stdout")?;
    let reader = BufReader::new(stdout);

    // Map from nix log action id → drvPath (populated on "start")
    let mut id_to_drv: HashMap<i64, String> = HashMap::new();

    let mut any_failed = false;

    for line in reader.lines() {
        let line = line.context("reading nix log line")?;

        // Lines start with "@nix " prefix
        let json = if let Some(stripped) = line.strip_prefix("@nix ") {
            stripped
        } else {
            continue; // skip non-JSON lines (shouldn't happen with internal-json)
        };

        let log_line: NixLogLine =
            serde_json::from_str(json).with_context(|| format!("parsing log line: {json}"))?;

        let action = match &log_line.action {
            Some(a) => a.as_str(),
            None => continue,
        };

        match action {
            "start" => {
                let drv_path = log_line
                    .fields
                    .as_ref()
                    .and_then(|f| f.first())
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown");

                if let Some(id) = log_line.id {
                    id_to_drv.insert(id, drv_path.to_string());
                }

                let tree_path = drv_to_tree
                    .get(drv_path)
                    .cloned()
                    .unwrap_or_else(|| drv_path.to_string());
                let system = drv_to_system
                    .get(drv_path)
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());

                on_event(&BuildEvent {
                    tree_path,
                    drv_path: drv_path.to_string(),
                    system,
                    status: BuildStatus::Started,
                });
            }

            "result" => {
                // Result lines have type_ indicating success/failure
                // type=104 = build succeeded, type=105 = build start (not a result)
                // The result action means the build finished.
                if let (Some(id), Some(type_)) = (log_line.id, log_line.type_) {
                    if let Some(drv_path) = id_to_drv.get(&id).cloned() {
                        let tree_path = drv_to_tree
                            .get(&drv_path)
                            .cloned()
                            .unwrap_or_else(|| drv_path.clone());
                        let system = drv_to_system
                            .get(&drv_path)
                            .cloned()
                            .unwrap_or_else(|| "unknown".to_string());

                        let exit_code = log_line
                            .fields
                            .as_ref()
                            .and_then(|f| f.first())
                            .and_then(|v| v.as_i64());

                        let status = if exit_code == Some(0) || type_ == 104 {
                            BuildStatus::Succeeded
                        } else {
                            any_failed = true;
                            BuildStatus::Failed { exit_code }
                        };

                        on_event(&BuildEvent {
                            tree_path,
                            drv_path,
                            system,
                            status,
                        });
                    }
                }
            }

            _ => {}
        }
    }

    // Wait for the process to finish
    let output = child.wait_with_output().context("waiting for nix-store")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!("nix-store --realise failed: {stderr}");
    }

    Ok(!any_failed && output.status.success())
}

/// Extract just the drvPaths from a drvmap for passing to nix-store.
pub fn drv_paths(drvmap: &crate::drvmap::Drvmap) -> Vec<String> {
    drvmap.values().map(|info| info.drv_path.clone()).collect()
}

/// Build lookup maps from drvmap for log attribution.
pub fn build_lookup_maps(
    drvmap: &crate::drvmap::Drvmap,
) -> (HashMap<String, String>, HashMap<String, String>) {
    let mut drv_to_tree = HashMap::new();
    let mut drv_to_system = HashMap::new();

    for (tree_path, info) in drvmap {
        drv_to_tree.insert(info.drv_path.clone(), tree_path.clone());
        drv_to_system.insert(
            info.drv_path.clone(),
            info.system.clone().unwrap_or_default(),
        );
    }

    (drv_to_tree, drv_to_system)
}
