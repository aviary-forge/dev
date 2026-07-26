//! Buildkite annotation output: per-target status tables emitted as
//! annotations visible in the Buildkite UI.
//!
//! Two annotations are produced:
//! 1. A persistent main table (context `build-{system}`) showing all targets
//!    with status, duration, and owners. Updated live during the build.
//! 2. A failure summary (context `build-{system}-failures`, only when failures
//!    exist) listing failed targets with owners and log tails.

use crate::drvmap::Owner;
use crate::realise::BuildEvent;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::Instant;

/// Accumulated status for a single target.
#[derive(Debug, Clone)]
pub struct TargetStatus {
    pub tree_path: String,
    pub drv_path: String,
    pub state: BuildState,
    pub owners: Vec<Owner>,
    pub deps: Vec<String>,
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
                }
                crate::realise::BuildStatus::Succeeded
                | crate::realise::BuildStatus::Substitution => {
                    // Capture elapsed time since last start
                    if let Some(start) = target.started_at.take() {
                        target.duration_ms += start.elapsed().as_millis() as u64;
                    }
                    target.state = BuildState::Succeeded;
                }
                crate::realise::BuildStatus::Failed { exit_code } => {
                    if let Some(start) = target.started_at.take() {
                        target.duration_ms += start.elapsed().as_millis() as u64;
                    }
                    target.exit_code = *exit_code;
                    target.state = BuildState::Failed;

                    // Mark all transitive dependents as skipped.
                    let dependents = self.transitive_dependents(&event.tree_path);
                    for dep_path in &dependents {
                        if let Some(dep_target) = self.targets.get_mut(dep_path) {
                            if dep_target.state == BuildState::Pending {
                                dep_target.state = BuildState::Skipped;
                            }
                        }
                    }
                }
                crate::realise::BuildStatus::Skipped => {
                    target.state = BuildState::Skipped;
                }
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
        let skipped_str = if skipped > 0 {
            format!(" | {} skipped", skipped)
        } else {
            String::new()
        };

        out.push_str(&format!(
            "### Build: {} — {} succeeded, {} failed{}{}{}\n\n",
            self.system, succeeded, failed, building_str, pending_str, skipped_str
        ));

        // Table header
        out.push_str("| Status | Target | Duration | Owners |\n");
        out.push_str("|--------|--------|----------|--------|\n");

        // Sort: failed → building → pending → skipped → succeeded
        let mut sorted: Vec<&TargetStatus> = self.targets.values().collect();
        sorted.sort_by(|a, b| {
            let prio = |s: &BuildState| match s {
                BuildState::Failed => 0,
                BuildState::Building => 1,
                BuildState::Pending => 2,
                BuildState::Skipped => 3,
                BuildState::Succeeded => 4,
            };
            prio(&a.state)
                .cmp(&prio(&b.state))
                .then_with(|| a.tree_path.cmp(&b.tree_path))
        });

        for t in &sorted {
            let status_icon = match t.state {
                BuildState::Pending => "⏳",
                BuildState::Building => "🔨",
                BuildState::Succeeded => "✅",
                BuildState::Failed => "❌",
                BuildState::Skipped => "⏭",
            };

            let duration_str = match t.state {
                BuildState::Building => {
                    if let Some(start) = t.started_at {
                        let elapsed = start.elapsed().as_millis() as u64;
                        format!("{:.1}s", elapsed as f64 / 1000.0)
                    } else {
                        "—".to_string()
                    }
                }
                BuildState::Pending | BuildState::Skipped => "—".to_string(),
                _ => {
                    if t.duration_ms > 0 {
                        format!("{:.1}s", t.duration_ms as f64 / 1000.0)
                    } else {
                        "—".to_string()
                    }
                }
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

            out.push_str(&format!(
                "| {} | `{}` | {} | {} |\n",
                status_icon, t.tree_path, duration_str, owners_str
            ));
        }

        out
    }

    /// Render the failure summary annotation (only when failures exist).
    /// Returns `None` if there are no failures.
    pub fn render_failure_summary(&self) -> Option<String> {
        let failed: Vec<&TargetStatus> = self
            .targets
            .values()
            .filter(|t| t.state == BuildState::Failed)
            .collect();

        if failed.is_empty() {
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

            out.push_str(&format!(
                "**`{}`** — {}  \nOwners: {}\n\n",
                t.tree_path, exit_str, owners_str
            ));

            if let Some(ref log_tail) = t.log_tail {
                out.push_str("```\n");
                out.push_str(log_tail);
                out.push_str("\n```\n\n");
            }

            out.push_str("---\n\n");
        }

        Some(out)
    }

    /// Did all targets succeed?
    pub fn all_succeeded(&self) -> bool {
        self.targets
            .values()
            .all(|t| matches!(t.state, BuildState::Succeeded | BuildState::Skipped))
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
pub fn post_annotation(context: &str, style: &str, content: &str) -> Result<(), String> {
    let mut result = std::process::Command::new("buildkite-agent")
        .args(["annotate", "--context", context, "--style", style])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawning buildkite-agent annotate: {e}"))?;

    // Write content to stdin
    use std::io::Write;
    if let Some(ref mut stdin) = result.stdin {
        stdin
            .write_all(content.as_bytes())
            .map_err(|e| format!("writing annotation: {e}"))?;
    }

    let output = result
        .wait_with_output()
        .map_err(|e| format!("waiting for buildkite-agent: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("buildkite-agent annotate failed: {stderr}"));
    }

    Ok(())
}
