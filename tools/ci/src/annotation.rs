//! Buildkite annotation output: per-target status tables emitted as
//! annotations visible in the Buildkite UI.
//!
//! Two annotations are produced:
//! 1. A persistent main table (context `build-{system}`) showing all targets
//!    with status, duration, and owners. Updated live during the build.
//! 2. A failure summary (context `build-{system}-failures`, only when failures
//!    exist) listing failed targets with owners and log tails, plus skipped
//!    targets (not built because a dependency failed).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Write;
use std::time::Instant;

use anyhow::Context;

use crate::drvmap::Owner;
use crate::realise::BuildEvent;

fn type_badge(attr_type: &Option<String>) -> &'static str {
    match attr_type.as_deref() {
        Some("nixos-system") => ":nix:",
        Some("darwin-system") => ":mac:",
        Some("home-manager-system") => ":house_with_garden:",
        Some("formatting-check") => ":mag:",
        _ => ":package:",
    }
}

/// Accumulated status for a single target.
#[derive(Debug, Clone)]
pub struct TargetStatus {
    pub tree_path: String,
    pub drv_path: String,
    pub state: BuildState,
    pub owners: Vec<Owner>,
    pub deps: Vec<String>,
    pub dev_attr_type: Option<String>,
    /// Wall-clock start time (set on first Start event).
    pub started_at: Option<Instant>,
    /// Accumulated duration in milliseconds.
    pub duration_ms: u64,
    /// Exit code (only for failed).
    pub exit_code: Option<i64>,
    /// Log tail for failed builds.
    pub log_tail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildState {
    Pending,
    Building,
    Succeeded,
    Failed,
    Skipped,
}

/// A live status tracker that builds annotations for Buildkite.
pub struct AnnotationTracker {
    /// All targets, keyed by tree path.
    targets: BTreeMap<String, TargetStatus>,
    /// Reverse dependency map: tree_path → set of tree_paths that depend on it.
    /// Populated lazily from forward deps.
    reverse_deps: HashMap<String, Vec<String>>,
    /// System label (e.g. "x86_64-linux") for annotation context.
    system: String,
}

impl AnnotationTracker {
    /// Create a new tracker seeded with all targets to build (all pending).
    pub fn new(to_build: &crate::drvmap::Drvmap, system: &str) -> Self {
        let targets: BTreeMap<String, TargetStatus> = to_build
            .iter()
            .map(|(tree_path, info)| {
                (
                    tree_path.clone(),
                    TargetStatus {
                        tree_path: tree_path.clone(),
                        drv_path: info.drv_path.clone(),
                        state: BuildState::Pending,
                        owners: info.owners.clone(),
                        deps: info.deps.clone(),
                        dev_attr_type: info.dev_attr_type.clone(),
                        started_at: None,
                        duration_ms: 0,
                        exit_code: None,
                        log_tail: None,
                    },
                )
            })
            .collect();

        AnnotationTracker {
            targets,
            reverse_deps: HashMap::new(),
            system: system.to_string(),
        }
    }

    /// Get the annotation context key for the main table.
    pub fn main_context(&self) -> String {
        format!("build-{}", self.system)
    }

    /// Get the annotation context key for the failure summary.
    pub fn failure_context(&self) -> String {
        format!("build-{}-failures", self.system)
    }

    /// Build (or retrieve) the reverse dependency map.
    fn ensure_reverse_deps(&mut self) {
        if !self.reverse_deps.is_empty() {
            return;
        }
        let mut rdeps: HashMap<String, Vec<String>> = HashMap::new();
        for (tree_path, status) in &self.targets {
            for dep in &status.deps {
                rdeps
                    .entry(dep.clone())
                    .or_default()
                    .push(tree_path.clone());
            }
        }
        self.reverse_deps = rdeps;
    }

    /// Compute the set of targets transitively dependent on a failed target.
    fn transitive_dependents(&mut self, failed_path: &str) -> HashSet<String> {
        self.ensure_reverse_deps();
        let mut visited = HashSet::new();
        let mut stack: Vec<String> = vec![failed_path.to_string()];
        while let Some(current) = stack.pop() {
            if !visited.insert(current.clone()) {
                continue;
            }
            if let Some(dependents) = self.reverse_deps.get(&current) {
                for dep in dependents {
                    if !visited.contains(dep) {
                        stack.push(dep.clone());
                    }
                }
            }
        }
        // Don't include the failed target itself as "skipped" — it failed
        visited.remove(failed_path);
        visited
    }

    /// Update state based on a build event.
    pub fn on_event(&mut self, event: &BuildEvent) {
        if let Some(target) = self.targets.get_mut(&event.tree_path) {
            match &event.status {
                crate::realise::BuildStatus::Started => {
                    if target.started_at.is_none() {
                        target.started_at = Some(Instant::now());
                    }
                    target.state = BuildState::Building;
                },
                crate::realise::BuildStatus::Succeeded
                | crate::realise::BuildStatus::Substitution => {
                    // Capture elapsed time since last start
                    if let Some(start) = target.started_at.take() {
                        target.duration_ms += start.elapsed().as_millis() as u64;
                    }
                    target.state = BuildState::Succeeded;
                },
                crate::realise::BuildStatus::Failed { exit_code } => {
                    if let Some(start) = target.started_at.take() {
                        target.duration_ms += start.elapsed().as_millis() as u64;
                    }
                    target.exit_code = *exit_code;
                    target.state = BuildState::Failed;

                    // Mark all transitive dependents as skipped.
                    let dependents = self.transitive_dependents(&event.tree_path);
                    for dep_path in &dependents {
                        if let Some(dep_target) = self.targets.get_mut(dep_path)
                            && dep_target.state == BuildState::Pending
                        {
                            dep_target.state = BuildState::Skipped;
                        }
                    }
                },
                crate::realise::BuildStatus::Skipped => {
                    target.state = BuildState::Skipped;
                },
            }
        }
    }

    /// Record log tail for a failed target.
    pub fn set_log_tail(&mut self, tree_path: &str, log_tail: String) {
        if let Some(target) = self.targets.get_mut(tree_path) {
            target.log_tail = Some(log_tail);
        }
    }

    /// Count targets in each state.
    fn counts(&self) -> (usize, usize, usize, usize, usize) {
        let mut pending = 0;
        let mut building = 0;
        let mut succeeded = 0;
        let mut failed = 0;
        let mut skipped = 0;

        for t in self.targets.values() {
            match t.state {
                BuildState::Pending => pending += 1,
                BuildState::Building => building += 1,
                BuildState::Succeeded => succeeded += 1,
                BuildState::Failed => failed += 1,
                BuildState::Skipped => skipped += 1,
            }
        }

        (pending, building, succeeded, failed, skipped)
    }

    /// Render the main annotation table.
    pub fn render_main(&self) -> String {
        let (pending, building, succeeded, failed, skipped) = self.counts();
        let mut out = String::new();

        // Skipped targets count as failures: they were not built because a
        // dependency failed (either a tracked failed target, or a third-party
        // drv outside the drvmap that nix refused via --keep-going).
        let failure_count = failed + skipped;
        let skipped_note = if skipped > 0 {
            format!(" ({} skipped: dependency failure)", skipped)
        } else {
            String::new()
        };

        // Header with summary
        let building_str = if building > 0 {
            format!(" | {} building", building)
        } else {
            String::new()
        };
        let pending_str = if pending > 0 {
            format!(" | {} pending", pending)
        } else {
            String::new()
        };

        out.push_str(&format!(
            "### Build: {} — {} succeeded, {} failed{}{}{}\n\n",
            self.system, succeeded, failure_count, skipped_note, building_str, pending_str
        ));

        // Table header
        out.push_str("| Status | Type | Target | Duration | Owners |\n");
        out.push_str("|--------|------|--------|----------|--------|\n");

        // Sort by target name
        let mut sorted: Vec<&TargetStatus> = self.targets.values().collect();
        sorted.sort_by(|a, b| a.tree_path.cmp(&b.tree_path));

        for t in &sorted {
            let status_icon = match t.state {
                BuildState::Pending => ":hourglass:",
                BuildState::Building => ":hammer:",
                BuildState::Succeeded => ":white_check_mark:",
                BuildState::Failed => ":x:",
                BuildState::Skipped => ":no_entry_sign:",
            };

            let duration_str = match t.state {
                BuildState::Building => {
                    if let Some(start) = t.started_at {
                        let elapsed = start.elapsed().as_millis() as u64;
                        format!("{:.1}s", elapsed as f64 / 1000.0)
                    } else {
                        "—".to_string()
                    }
                },
                BuildState::Pending | BuildState::Skipped => "—".to_string(),
                _ => {
                    if t.duration_ms > 0 {
                        format!("{:.1}s", t.duration_ms as f64 / 1000.0)
                    } else {
                        "—".to_string()
                    }
                },
            };

            let owners_str = if t.owners.is_empty() {
                "—".to_string()
            } else {
                t.owners
                    .iter()
                    .map(|o| {
                        o.github
                            .as_deref()
                            .unwrap_or(o.discord.as_deref().unwrap_or("?"))
                    })
                    .collect::<Vec<&str>>()
                    .join(", ")
            };

            let type_badge = type_badge(&t.dev_attr_type);
            out.push_str(&format!(
                "| {} | {} | `{}` | {} | {} |\n",
                status_icon, type_badge, t.tree_path, duration_str, owners_str
            ));
        }

        out
    }

    /// Render the failure summary annotation (only when failures exist).
    /// Skipped targets are failures too — they were not built because a
    /// dependency failed. Returns `None` if there are neither.
    pub fn render_failure_summary(&self) -> Option<String> {
        let failed: Vec<&TargetStatus> = self
            .targets
            .values()
            .filter(|t| t.state == BuildState::Failed)
            .collect();

        let skipped: Vec<&TargetStatus> = self
            .targets
            .values()
            .filter(|t| t.state == BuildState::Skipped)
            .collect();

        if failed.is_empty() && skipped.is_empty() {
            return None;
        }

        let mut out = String::new();

        out.push_str(&format!("### ❌ Build failures — {}\n\n", self.system));

        for t in &failed {
            let owners_str = if t.owners.is_empty() {
                "none".to_string()
            } else {
                t.owners
                    .iter()
                    .map(|o| {
                        format!(
                            "@{}",
                            o.github
                                .as_deref()
                                .unwrap_or(o.discord.as_deref().unwrap_or("?"))
                        )
                    })
                    .collect::<Vec<String>>()
                    .join(", ")
            };

            let exit_str = match t.exit_code {
                Some(code) => format!("exit code {}", code),
                None => "unknown exit".to_string(),
            };

            let type_badge = type_badge(&t.dev_attr_type);
            out.push_str(&format!(
                "**`{}`** ({}) — {}  \nOwners: {}\n\n",
                t.tree_path, type_badge, exit_str, owners_str
            ));

            if let Some(ref log_tail) = t.log_tail {
                out.push_str("```\n");
                out.push_str(log_tail);
                out.push_str("\n```\n\n");
            }

            out.push_str("---\n\n");
        }

        if !skipped.is_empty() {
            out.push_str(&format!(
                "### :no_entry_sign: Skipped — {}\n\nNot built: a dependency failed.\n\n",
                self.system
            ));

            for t in &skipped {
                let owners_str = if t.owners.is_empty() {
                    "none".to_string()
                } else {
                    t.owners
                        .iter()
                        .map(|o| {
                            format!(
                                "@{}",
                                o.github
                                    .as_deref()
                                    .unwrap_or(o.discord.as_deref().unwrap_or("?"))
                            )
                        })
                        .collect::<Vec<String>>()
                        .join(", ")
                };

                let type_badge = type_badge(&t.dev_attr_type);
                out.push_str(&format!(
                    "**`{}`** ({}) — skipped (dependency failure)  \nOwners: {}\n\n",
                    t.tree_path, type_badge, owners_str
                ));
            }
        }

        Some(out)
    }

    /// Did all targets succeed?
    ///
    /// Skipped targets are failures: they were not built because a
    /// dependency failed. This must agree with the exit-code decision,
    /// which is driven by `realise::realise`'s own `all_succeeded`.
    pub fn all_succeeded(&self) -> bool {
        self.targets
            .values()
            .all(|t| t.state == BuildState::Succeeded)
    }

    /// Get failed targets for results file.
    pub fn failed_targets(&self) -> Vec<&TargetStatus> {
        self.targets
            .values()
            .filter(|t| t.state == BuildState::Failed)
            .collect()
    }

    /// Get all target statuses (for results file export).
    pub fn all_targets(&self) -> &BTreeMap<String, TargetStatus> {
        &self.targets
    }
}

/// Post an annotation to Buildkite via `buildkite-agent annotate`.
pub fn post_annotation(context: &str, style: &str, content: &str) -> anyhow::Result<()> {
    let mut result = std::process::Command::new("buildkite-agent")
        .args(["annotate", "--context", context, "--style", style])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .context("spawning buildkite-agent annotate")?;

    if let Some(ref mut stdin) = result.stdin {
        stdin
            .write_all(content.as_bytes())
            .context("writing annotation to stdin")?;
    }

    let output = result
        .wait_with_output()
        .context("waiting for buildkite-agent")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("buildkite-agent annotate failed: {stderr}");
    }

    Ok(())
}
