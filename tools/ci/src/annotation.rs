//! Buildkite annotation output: per-target status tables emitted as
//! annotations visible in the Buildkite UI.

use crate::realise::BuildEvent;
use std::collections::BTreeMap;

/// Accumulated status for a single target.
#[derive(Debug, Clone)]
struct TargetStatus {
    tree_path: String,
    drv_path: String,
    state: BuildState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum BuildState {
    Pending,
    Building,
    Succeeded,
    Failed,
}

/// A live status tracker that builds annotations for Buildkite.
pub struct AnnotationTracker {
    targets: BTreeMap<String, TargetStatus>,
}

impl AnnotationTracker {
    /// Create a new tracker seeded with all targets to build (all pending).
    pub fn new(to_build: &crate::drvmap::Drvmap) -> Self {
        let targets: BTreeMap<String, TargetStatus> = to_build
            .iter()
            .map(|(tree_path, info)| {
                (
                    tree_path.clone(),
                    TargetStatus {
                        tree_path: tree_path.clone(),
                        drv_path: info.drv_path.clone(),
                        state: BuildState::Pending,
                    },
                )
            })
            .collect();

        AnnotationTracker { targets }
    }

    /// Update state based on a build event.
    pub fn on_event(&mut self, event: &BuildEvent) {
        if let Some(target) = self.targets.get_mut(&event.tree_path) {
            target.state = match event.status {
                crate::realise::BuildStatus::Started => BuildState::Building,
                crate::realise::BuildStatus::Succeeded
                | crate::realise::BuildStatus::Substitution => BuildState::Succeeded,
                crate::realise::BuildStatus::Failed { .. } => BuildState::Failed,
            };
        }
    }

    /// Count targets in each state.
    fn counts(&self) -> (usize, usize, usize, usize) {
        let mut pending = 0;
        let mut building = 0;
        let mut succeeded = 0;
        let mut failed = 0;

        for t in self.targets.values() {
            match t.state {
                BuildState::Pending => pending += 1,
                BuildState::Building => building += 1,
                BuildState::Succeeded => succeeded += 1,
                BuildState::Failed => failed += 1,
            }
        }

        (pending, building, succeeded, failed)
    }

    /// Render the current state as a Buildkite annotation (Markdown table).
    pub fn render(&self) -> String {
        let (pending, building, succeeded, failed) = self.counts();
        let total = self.targets.len();

        let mut out = String::new();

        // Header with summary
        out.push_str(&format!(
            "### Build Status: {} total | {} succeeded | {} failed | {} building | {} pending\n\n",
            total, succeeded, failed, building, pending
        ));

        // Table header
        out.push_str("| Status | Target | DrvPath |\n");
        out.push_str("|--------|--------|--------|\n");

        // Sort: failed first, then building, then succeeded, then pending
        let mut sorted: Vec<&TargetStatus> = self.targets.values().collect();
        sorted.sort_by(|a, b| {
            let prio = |s: &BuildState| match s {
                BuildState::Failed => 0,
                BuildState::Building => 1,
                BuildState::Pending => 2,
                BuildState::Succeeded => 3,
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
            };

            // Truncate drvPath to just the basename for readability
            let drv_basename = t
                .drv_path
                .strip_prefix("/nix/store/")
                .unwrap_or(&t.drv_path);

            out.push_str(&format!(
                "| {} | `{}` | `{}` |\n",
                status_icon, t.tree_path, drv_basename
            ));
        }

        out
    }

    /// Did all targets succeed?
    #[allow(dead_code)]
    pub fn all_succeeded(&self) -> bool {
        self.targets
            .values()
            .all(|t| t.state == BuildState::Succeeded)
    }
}
