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
    arch: String,
}

/// Parse a Nix system triple (e.g. "x86_64-linux") into (arch, os).
fn parse_nix_system(system: &str) -> (&str, &str) {
    if let Some((arch, os)) = system.split_once('-') {
        (arch, os)
    } else {
        // Fallback: treat the whole string as system, unknown arch
        ("unknown", system)
    }
}

/// Build the `nix-store --realise` command for a set of drvPaths.
fn build_step_command(drv_paths: &[String]) -> String {
    let paths_quoted: Vec<String> = drv_paths.iter().map(|p| format!("'{}'", p)).collect();
    // Note: --log-format internal-json is omitted until ci-orchestrator
    // build mode is wired in to parse it. Currently it just floods
    // the Buildkite log with @nix JSON lines.
    format!("nix-store --realise {}", paths_quoted.join(" "))
}

/// Generate pipeline YAML (as a JSON string, since Buildkite accepts
/// JSON as a YAML subset) for the given set of changed targets,
/// grouped by system.
///
/// The static pipeline (`pipelines/default.yaml`) already handles
/// pipeline generation and orchestration. This function only emits
/// the per-system build steps and a post-build step — no duplicate
/// pipeline-gen key.
pub fn generate_pipeline(
    by_system: &std::collections::BTreeMap<String, Drvmap>,
) -> serde_json::Value {
    let mut steps: Vec<BuildkiteStep> = Vec::new();

    // One build step per system.
    // These depend on the static pipeline's "pipeline-gen" step.
    for (system, targets) in by_system {
        if targets.is_empty() {
            continue;
        }

        let drv_paths: Vec<String> = crate::realise::drv_paths(targets);
        let target_count = drv_paths.len();

        let (arch, os) = parse_nix_system(system);

        steps.push(BuildkiteStep {
            label: format!(":nix: build {} ({})", system, target_count),
            key: format!("build-{}", system.replace('.', "-")),
            command: build_step_command(&drv_paths),
            depends_on: vec!["pipeline-gen".to_string()],
            agents: Some(BuildkiteAgents {
                arch: arch.to_string(),
                os: os.to_string(),
            }),
            env: {
                let mut env = std::collections::BTreeMap::new();
                env.insert("NIX_SYSTEM".to_string(), system.clone());
                Some(env)
            },
        });
    }

    // Post-build step (gcroot, notifications).
    // Only emitted if there are build steps to depend on.
    if !steps.is_empty() {
        steps.push(BuildkiteStep {
            label: ":point_up: post-build".to_string(),
            key: "ci-post-build".to_string(),
            command:
                "\"$(nix-build -A pipelines.tasks.ci-orchestrator)/bin/ci-orchestrator\" post-build"
                    .to_string(),
            depends_on: steps.iter().map(|s| s.key.clone()).collect(),
            agents: None,
            env: None,
        });
    }

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
        // No targets → no build steps → no post-build step
        assert!(steps.is_empty());
    }
}
