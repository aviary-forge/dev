//! Run `nix-store --realise` with `--log-format internal-json` and parse
//! the `@nix {...}` JSON line stream into per-target build events.
//!
//! Supports `--keep-going` (build everything possible), transient failure
//! retry with backoff, and log tail extraction for failed builds.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

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
    Substitution,
    /// Skipped because a dependency failed (--keep-going semantics).
    Skipped,
}

/// A build event attributed to a specific target.
#[derive(Debug, Clone)]
pub struct BuildEvent {
    /// The tree path (e.g. "rust/gcroot-manager").
    pub tree_path: String,
    /// The derivation path.
    pub drv_path: String,
    /// The system.
    pub system: String,
    /// What happened.
    pub status: BuildStatus,
    /// Exit code for failed builds.
    pub exit_code: Option<i64>,
    /// Last N lines of the build log (only populated for failures).
    pub log_tail: Option<String>,
}

/// Result for a single target after building.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TargetResult {
    pub tree_path: String,
    pub drv_path: String,
    pub status: String, // "succeeded", "failed", "skipped"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub log_tail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_count: Option<u32>,
}

/// Transient failure patterns for retry detection.
const TRANSIENT_PATTERNS: &[&str] = &[
    "curl error",
    "unable to download",
    "Connection refused",
    "connection refused",
    "timeout",
    "Timed out",
    "ssh: connect to host",
    "broken pipe",
    "Broken pipe",
    "remote builder unavailable",
    "unexpected end-of-file",
    "cannot connect to",
    "HTTP 502",
    "HTTP 503",
    "HTTP 504",
    "Could not resolve host",
    "Temporary failure in name resolution",
    "No route to host",
];

/// Check if a build log contains transient failure signatures.
fn is_transient_failure(log_output: &str) -> bool {
    TRANSIENT_PATTERNS
        .iter()
        .any(|pattern| log_output.contains(pattern))
}

/// Extract the last N lines from a string.
fn last_n_lines(s: &str, n: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    let start = if lines.len() > n { lines.len() - n } else { 0 };
    lines[start..].join("\n")
}

/// Get the build log for a derivation via `nix log`.
fn nix_log(drv_path: &str) -> Result<String> {
    let output = Command::new("nix")
        .args(["log", drv_path])
        .output()
        .with_context(|| format!("nix log {drv_path}"))?;

    // nix log can fail if the log is unavailable; don't treat as fatal
    String::from_utf8(output.stdout)
        .or_else(|_| Ok(String::from_utf8_lossy(&output.stderr).into_owned()))
        .map_err(|e: std::string::FromUtf8Error| anyhow::anyhow!("invalid UTF-8 from nix log: {e}"))
}

/// Build a set of derivation paths using `nix-store --realise`.
///
/// Uses `--keep-going` so that all independent targets are attempted even
/// if some fail. Transient failures (network, remote builder) are retried
/// up to `max_retries` times with linear backoff.
///
/// Returns a map from tree_path to TargetResult and whether all builds succeeded.
pub fn realise<F: FnMut(&BuildEvent)>(
    drv_paths: &[String],
    drv_to_tree: &HashMap<String, String>,
    drv_to_system: &HashMap<String, String>,
    max_retries: u32,
    on_event: &mut F,
) -> Result<(HashMap<String, TargetResult>, bool)> {
    if drv_paths.is_empty() {
        tracing::info!("no derivations to build");
        return Ok((HashMap::new(), true));
    }

    tracing::info!(
        "building {} derivations (--keep-going, max retries: {})",
        drv_paths.len(),
        max_retries
    );

    // Track start times for duration computation.
    let mut start_times: HashMap<String, Instant> = HashMap::new();
    let mut results: HashMap<String, TargetResult> = HashMap::new();

    // Initialize all targets as pending.
    for dp in drv_paths {
        let tree = drv_to_tree.get(dp).cloned().unwrap_or_else(|| dp.clone());
        results.insert(
            tree.clone(),
            TargetResult {
                tree_path: tree,
                drv_path: dp.clone(),
                status: "pending".to_string(),
                exit_code: None,
                duration_ms: None,
                log_tail: None,
                retry_count: None,
            },
        );
    }

    // --- Main build pass ---
    let mut child = Command::new("nix-store")
        .arg("--realise")
        .arg("--keep-going")
        .arg("--log-format")
        .arg("internal-json")
        .args(drv_paths)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawning nix-store --realise")?;

    // @nix log lines go to stderr with --log-format internal-json.
    // stdout carries the realised store paths (one per line).
    let stderr_pipe = child.stderr.take().context("capturing stderr")?;
    let reader = BufReader::new(stderr_pipe);

    // Map from nix log action id → drvPath (populated on "start")
    let mut id_to_drv: HashMap<i64, String> = HashMap::new();
    let mut any_failed = false;

    for line in reader.lines() {
        let line = line.context("reading nix log line")?;

        let json = if let Some(stripped) = line.strip_prefix("@nix ") {
            stripped
        } else {
            continue;
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
                    .unwrap_or("unknown")
                    .to_string();

                if let Some(id) = log_line.id {
                    id_to_drv.insert(id, drv_path.clone());
                }

                let tree_path = drv_to_tree
                    .get(&drv_path)
                    .cloned()
                    .unwrap_or_else(|| drv_path.clone());
                let system = drv_to_system
                    .get(&drv_path)
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());

                start_times.insert(tree_path.clone(), Instant::now());

                on_event(&BuildEvent {
                    tree_path: tree_path.clone(),
                    drv_path: drv_path.clone(),
                    system,
                    status: BuildStatus::Started,
                    exit_code: None,
                    log_tail: None,
                });
            }

            "result" => {
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

                        let duration_ms = start_times
                            .get(&tree_path)
                            .map(|t| t.elapsed().as_millis() as u64);

                        // type_ == 0 means build failed
                        let status = if exit_code == Some(0) || type_ != 0 {
                            BuildStatus::Succeeded
                        } else {
                            any_failed = true;
                            BuildStatus::Failed { exit_code }
                        };

                        if let Some(entry) = results.get_mut(&tree_path) {
                            entry.status = match &status {
                                BuildStatus::Succeeded => "succeeded".to_string(),
                                BuildStatus::Failed { .. } => "failed".to_string(),
                                _ => entry.status.clone(),
                            };
                            entry.exit_code = exit_code;
                            entry.duration_ms = duration_ms;
                        }

                        on_event(&BuildEvent {
                            tree_path,
                            drv_path,
                            system,
                            status,
                            exit_code,
                            log_tail: None,
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
        tracing::warn!(
            "nix-store --realise exited with status {}",
            output
                .status
                .code()
                .map_or("unknown".to_string(), |c| c.to_string())
        );
    }

    // --- Retry transient failures ---
    if any_failed && max_retries > 0 {
        let failed_drvs: Vec<String> = results
            .values()
            .filter(|r| r.status == "failed")
            .map(|r| r.drv_path.clone())
            .collect();

        for drv_path in &failed_drvs {
            let tree_path = drv_to_tree
                .get(drv_path)
                .cloned()
                .unwrap_or_else(|| drv_path.clone());

            // Fetch the build log to check if this is transient
            let log_output = match nix_log(drv_path) {
                Ok(log) => log,
                Err(e) => {
                    tracing::warn!("could not fetch log for {drv_path}: {e}");
                    continue;
                }
            };

            if !is_transient_failure(&log_output) {
                tracing::info!("{tree_path}: non-transient failure, not retrying");
                // Store log tail for non-transient failures
                if let Some(entry) = results.get_mut(&tree_path) {
                    entry.log_tail = Some(last_n_lines(&log_output, 20));
                }
                continue;
            }

            tracing::info!(
                "{tree_path}: transient failure detected, retrying up to {max_retries} times"
            );

            let mut retry_success = false;
            for attempt in 1..=max_retries {
                let backoff = Duration::from_secs(5 * attempt as u64);
                tracing::info!(
                    "{tree_path}: retry attempt {attempt}/{max_retries} (waiting {}s)",
                    backoff.as_secs()
                );
                std::thread::sleep(backoff);

                // Record start time for this retry
                let retry_start = Instant::now();
                let retry_system = drv_to_system
                    .get(drv_path)
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());

                on_event(&BuildEvent {
                    tree_path: tree_path.clone(),
                    drv_path: drv_path.clone(),
                    system: retry_system.clone(),
                    status: BuildStatus::Started,
                    exit_code: None,
                    log_tail: None,
                });

                let retry_child = Command::new("nix-store")
                    .arg("--realise")
                    .arg(drv_path)
                    .output()
                    .with_context(|| format!("retrying nix-store --realise {drv_path}"))?;

                let retry_duration_ms = retry_start.elapsed().as_millis() as u64;

                if retry_child.status.success() {
                    tracing::info!(
                        "{tree_path}: retry {attempt} succeeded ({retry_duration_ms}ms)"
                    );
                    if let Some(entry) = results.get_mut(&tree_path) {
                        entry.status = "succeeded".to_string();
                        entry.exit_code = Some(0);
                        entry.duration_ms =
                            Some(entry.duration_ms.unwrap_or(0) + retry_duration_ms);
                        entry.retry_count = Some(attempt);
                        entry.log_tail = None;
                    }

                    on_event(&BuildEvent {
                        tree_path: tree_path.clone(),
                        drv_path: drv_path.clone(),
                        system: retry_system,
                        status: BuildStatus::Succeeded,
                        exit_code: Some(0),
                        log_tail: None,
                    });

                    retry_success = true;
                    break;
                } else {
                    let retry_log = String::from_utf8_lossy(&retry_child.stderr).to_string();
                    tracing::warn!(
                        "{tree_path}: retry {attempt} failed: {}",
                        last_n_lines(&retry_log, 3)
                    );
                }
            }

            if !retry_success {
                // Persist log tail after all retries exhausted
                let final_log = nix_log(drv_path).unwrap_or_else(|_| "log unavailable".to_string());
                if let Some(entry) = results.get_mut(&tree_path) {
                    entry.log_tail = Some(last_n_lines(&final_log, 20));
                    entry.retry_count = Some(max_retries);
                }
            }
        }
    }

    // Resolve still-pending targets.
    //
    // If nix-store --realise exited successfully, any target that never
    // emitted a start/result event was already in the store (substituted
    // or previously built) — mark it as succeeded, not skipped.
    //
    // If nix-store exited with failure, pending targets may be either
    // already-in-store (succeeded) or truly skipped by --keep-going.
    // Check store validity to distinguish.
    let build_succeeded = output.status.success();
    for entry in results.values_mut() {
        if entry.status == "pending" {
            let already_valid = if build_succeeded {
                // Exit 0 means all requested drvPaths were realised.
                // Any still-pending target was already in the store.
                true
            } else {
                // Some targets failed. Check if this specific drvPath
                // actually exists in the store.
                std::path::Path::new(&entry.drv_path).exists()
            };

            if already_valid {
                entry.status = "succeeded".to_string();
                let tree_path = entry.tree_path.clone();
                let drv_path = entry.drv_path.clone();
                let system = drv_to_system
                    .get(&drv_path)
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());
                on_event(&BuildEvent {
                    tree_path,
                    drv_path,
                    system,
                    status: BuildStatus::Succeeded,
                    exit_code: Some(0),
                    log_tail: None,
                });
            } else {
                entry.status = "skipped".to_string();
                let tree_path = entry.tree_path.clone();
                let drv_path = entry.drv_path.clone();
                let system = drv_to_system
                    .get(&drv_path)
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());
                on_event(&BuildEvent {
                    tree_path,
                    drv_path,
                    system,
                    status: BuildStatus::Skipped,
                    exit_code: None,
                    log_tail: None,
                });
            }
        }
    }

    // Determine overall success
    let all_succeeded = results.values().all(|r| r.status != "failed");

    Ok((results, all_succeeded))
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
