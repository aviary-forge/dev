//! Buildkite pipeline YAML generation.
//!
//! Produces a minimal pipeline: one build step per system, each running
//! `ci-orchestrator build` to invoke `nix-store --realise` with live
//! annotation output.

use crate::drvmap::Drvmap;

/// A Buildkite pipeline step.
#[derive(Debug, serde::Serialize)]
struct BuildkiteStep {
    label: String,
    key: String,
    command: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    depends_on: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agents: Option<BuildkiteAgents>,
    #[serde(skip_serializing_if = "Option::is_none")]
    env: Option<std::collections::BTreeMap<String, String>>,
}

#[derive(Debug, serde::Serialize)]
struct BuildkiteAgents {
    os: String,
}

/// Architecture mapping — Nix systems to Buildkite-compatible OS labels.
fn nix_system_to_os(system: &str) -> &str {
    if system.contains("darwin") {
        "macos"
    } else {
        "linux"
    }
}

/// Build the `nix-store --realise` command for a set of drvPaths.
/// The binary invokes itself in `build` mode, passing the drvPaths.
fn build_step_command(drv_paths: &[String]) -> String {
    let paths_quoted: Vec<String> = drv_paths
        .iter()
        .map(|p| format!("'{}'", p))
        .collect();
    format!(
        "nix-store --realise --log-format internal-json {}",
        paths_quoted.join(" ")
    )
}

/// Generate pipeline YAML (as a JSON string, since Buildkite accepts
/// JSON as a YAML subset) for the given set of changed targets,
/// grouped by system.
pub fn generate_pipeline(
    by_system: &std::collections::BTreeMap<String, Drvmap>,
) -> serde_json::Value {
    let mut steps: Vec<BuildkiteStep> = Vec::new();

    // Pipeline-gen step that runs first
    steps.push(BuildkiteStep {
        label: ":thinking_face: pipeline-gen".to_string(),
        key: "pipeline-gen".to_string(),
        command: "ci-orchestrator pipeline-gen".to_string(),
        depends_on: vec![],
        agents: None,
        env: None,
    });

    // One build step per system
    for (system, targets) in by_system {
        if targets.is_empty() {
            continue;
        }

        let drv_paths: Vec<String> = crate::realise::drv_paths(targets);
        let target_count = drv_paths.len();

        steps.push(BuildkiteStep {
            label: format!(":nix: build {} ({})", system, target_count),
            key: format!("build-{}", system.replace('.', "-")),
            command: build_step_command(&drv_paths),
            depends_on: vec!["pipeline-gen".to_string()],
            agents: Some(BuildkiteAgents {
                os: nix_system_to_os(system).to_string(),
            }),
            env: {
                let mut env = std::collections::BTreeMap::new();
                env.insert("NIX_SYSTEM".to_string(), system.clone());
                Some(env)
            },
        });
    }

    // Post-build step (gcroot, notifications)
    steps.push(BuildkiteStep {
        label: ":point_up: post-build".to_string(),
        key: "post-build".to_string(),
        command: "ci-orchestrator post-build".to_string(),
        depends_on: steps
            .iter()
            .filter(|s| s.key.starts_with("build-"))
            .map(|s| s.key.clone())
            .collect(),
        agents: None,
        env: None,
    });

    serde_json::json!({
        "steps": steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_empty_pipeline() {
        let by_system = std::collections::BTreeMap::new();
        let pipeline = generate_pipeline(&by_system);
        let steps = pipeline["steps"].as_array().unwrap();
        // Even with no targets, we have pipeline-gen and post-build
        assert!(steps.len() >= 2);
    }
}
