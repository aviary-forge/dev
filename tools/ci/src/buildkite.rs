//! Buildkite artifact lookup: recover a previously-uploaded drvmap from an
//! earlier `pipeline-gen` build of the same pipeline.
//!
//! This is the middle layer of the parent-drvmap fallback chain:
//! local cache → Buildkite artifact → worktree eval. A previous trunk build
//! uploaded `pipeline/drvmap.json` as a build artifact; if one of those
//! builds ran at *exactly* the merge-base commit, its drvmap is directly
//! comparable with the current one (drvPath diffing requires identical Nix
//! evaluation inputs — a "close enough" commit would spuriously mark every
//! target as changed, so we only accept exact commit matches).
//!
//! Validation mirrors the local cache sidecar: the entry-point content at the
//! artifact's commit (`git show <commit>:tools/ci/drvmap.nix`) must equal the
//! current checkout's, since that's the expression that produced the map.
//!
//! Everything fails open to `None` — this is an optimization, and the
//! worktree eval remains the correctness backstop.

use std::path::Path;

use anyhow::Context;
use serde_json::Value;

use crate::drvmap::Drvmap;
use crate::instantiate::DRVMAP_EXPR;

/// Artifact path the pipeline-gen step uploads the full drvmap snapshot to.
/// Must match what `pre-build` uploads and the GraphQL filter below.
const DRVMAP_ARTIFACT: &str = "pipeline/drvmap.json";

/// How far back to search for a matching build.
const MAX_BUILDS: u32 = 50;

/// Try to fetch a drvmap produced at `commit` by a previous Buildkite build.
///
/// Returns `None` (with a logged reason) whenever the lookup can't be
/// attempted or doesn't produce a valid, comparable drvmap.
pub fn fetch_drvmap(
    repo_root: &Path,
    trunk_branch: &str,
    commit: &str,
    current_entry_point: Option<&[u8]>,
) -> Option<Drvmap> {
    let (org, pipeline) = match pipeline_slug() {
        Some(pair) => pair,
        None => {
            tracing::debug!("buildkite drvmap lookup: not in a buildkite pipeline, skipping");
            return None;
        },
    };

    let token = match read_token() {
        Ok(token) => token,
        Err(err) => {
            tracing::debug!("buildkite drvmap lookup: {err}");
            return None;
        },
    };

    // The artifact was produced by the entry point at `commit`; validate
    // against the current checkout's copy before trusting the map.
    let commit_entry_point =
        match crate::git::show_file(repo_root, commit, crate::instantiate::DRVMAP_EXPR) {
            Ok(content) => Some(content),
            Err(err) => {
                tracing::debug!("buildkite drvmap lookup: no {DRVMAP_EXPR} at {commit}: {err}");
                None
            },
        };

    match (commit_entry_point.as_deref(), current_entry_point) {
        (Some(produced), Some(current)) if produced == current => {},
        (Some(_), Some(_)) => {
            tracing::info!(
                "buildkite drvmap lookup: {DRVMAP_EXPR} differs between current checkout and {commit}; ignoring artifact"
            );
            return None;
        },
        // Can't validate — don't trust.
        _ => {
            tracing::debug!("buildkite drvmap lookup: cannot validate entry point for {commit}");
            return None;
        },
    }

    let response = match graphql(&token, &build_query(&org, &pipeline, trunk_branch)) {
        Ok(response) => response,
        Err(err) => {
            tracing::warn!("buildkite drvmap lookup: GraphQL query failed: {err}");
            return None;
        },
    };

    let download_url = match extract_download_url(&response, commit) {
        Some(url) => url,
        None => {
            tracing::info!("buildkite drvmap lookup: no matching drvmap artifact for {commit}");
            return None;
        },
    };

    match download_drvmap(&download_url) {
        Ok(drvmap) => {
            tracing::info!("buildkite drvmap lookup: hit for {commit} ({download_url})");
            Some(drvmap)
        },
        Err(err) => {
            tracing::warn!("buildkite drvmap lookup: artifact download failed: {err}");
            None
        },
    }
}

/// Buildkite exposes the org and pipeline slugs as env vars on agents.
fn pipeline_slug() -> Option<(String, String)> {
    let org = std::env::var("BUILDKITE_ORGANIZATION_SLUG").ok()?;
    let pipeline = std::env::var("BUILDKITE_PIPELINE_SLUG").ok()?;
    Some((org, pipeline))
}

/// Read the GraphQL API token. Same convention as the legacy
/// `fetch-parent-targets` task: `BUILDKITE_TOKEN_PATH`, defaulting to
/// `~/buildkite-token`.
fn read_token() -> anyhow::Result<String> {
    let path = match std::env::var("BUILDKITE_TOKEN_PATH") {
        Ok(path) => std::path::PathBuf::from(path),
        Err(_) => {
            let home = std::env::var("HOME").context("no HOME set")?;
            Path::new(&home).join("buildkite-token")
        },
    };

    std::fs::read_to_string(&path)
        .map(|t| t.trim().to_string())
        .with_context(|| format!("reading buildkite token from {}", path.display()))
}

/// GraphQL query for recent trunk builds with a passed `pipeline-gen` job.
///
/// Mirrors the legacy `fetch-parent-targets` query, plus the build's commit
/// SHA so we can require an exact match. `RUNNING` is included because a
/// still-running trunk build has already finished its pipeline-gen job.
fn build_query(org: &str, pipeline: &str, branch: &str) -> String {
    format!(
        r#"{{ pipeline(slug: "{org}/{pipeline}") {{ builds(first: {MAX_BUILDS}, branch: ["{branch}"], state: [RUNNING, PASSED]) {{ edges {{ node {{ commit jobs(passed: true, first: 1, type: [COMMAND], step: {{key: ["pipeline-gen"]}}) {{ edges {{ node {{ ... on JobTypeCommand {{ artifacts(first: 10) {{ edges {{ node {{ path downloadURL }} }} }} }} }} }} }} }} }} }} }}"#
    )
}

/// Find the download URL of the drvmap artifact from the first build whose
/// commit matches, mirroring the legacy jq filter.
fn extract_download_url(response: &Value, commit: &str) -> Option<String> {
    let edges = response
        .pointer("/data/pipeline/builds/edges")?
        .as_array()?;

    for edge in edges {
        let node = &edge["node"];
        if node["commit"].as_str() != Some(commit) {
            continue;
        }
        let job_edges = node.pointer("/jobs/edges")?.as_array()?;
        for job_edge in job_edges {
            let artifact_edges = job_edge["node"].pointer("/artifacts/edges")?.as_array()?;
            for artifact_edge in artifact_edges {
                let artifact = &artifact_edge["node"];
                if artifact["path"].as_str() == Some(DRVMAP_ARTIFACT) {
                    return artifact["downloadURL"].as_str().map(String::from);
                }
            }
        }
    }

    None
}

fn graphql(token: &str, query: &str) -> anyhow::Result<Value> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .context("building http client")?;

    let response: Value = client
        .post("https://graphql.buildkite.com/v1")
        .bearer_auth(token)
        .json(&serde_json::json!({ "query": query }))
        .send()
        .context("sending graphql request")?
        .error_for_status()
        .context("graphql request rejected")?
        .json()
        .context("parsing graphql response")?;

    if let Some(errors) = response.get("errors") {
        anyhow::bail!("graphql errors: {errors}");
    }

    Ok(response)
}

fn download_drvmap(url: &str) -> anyhow::Result<Drvmap> {
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .context("building http client")?;

    let bytes = client
        .get(url)
        .send()
        .context("downloading drvmap artifact")?
        .error_for_status()
        .context("drvmap artifact download rejected")?
        .bytes()
        .context("reading drvmap artifact body")?;

    serde_json::from_slice(&bytes).context("parsing drvmap artifact")
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn sample_response() -> Value {
        json!({
            "data": {
                "pipeline": {
                    "builds": {
                        "edges": [
                            {
                                "node": {
                                    "commit": "aaaa",
                                    "jobs": { "edges": [ ] }
                                }
                            },
                            {
                                "node": {
                                    "commit": "bbbb",
                                    "jobs": {
                                        "edges": [
                                            {
                                                "node": {
                                                    "artifacts": {
                                                        "edges": [
                                                            {
                                                                "node": {
                                                                    "path": "pipeline/drvmap-changed.json",
                                                                    "downloadURL": "https://example.com/changed"
                                                                }
                                                            },
                                                            {
                                                                "node": {
                                                                    "path": "pipeline/drvmap.json",
                                                                    "downloadURL": "https://example.com/full"
                                                                }
                                                            }
                                                        ]
                                                    }
                                                }
                                            }
                                        ]
                                    }
                                }
                            }
                        ]
                    }
                }
            }
        })
    }

    #[test]
    fn test_extract_download_url_matches_commit_and_path() {
        assert_eq!(
            extract_download_url(&sample_response(), "bbbb").as_deref(),
            Some("https://example.com/full")
        );
    }

    #[test]
    fn test_extract_download_url_no_match() {
        assert_eq!(extract_download_url(&sample_response(), "cccc"), None);
    }

    #[test]
    fn test_extract_download_url_malformed() {
        assert_eq!(extract_download_url(&json!({ "data": null }), "bbbb"), None);
        assert_eq!(extract_download_url(&json!({ "errors": [] }), "bbbb"), None);
    }

    #[test]
    fn test_build_query_shape() {
        let query = build_query("my-org", "my-pipe", "trunk");
        assert!(query.contains(r#"pipeline(slug: "my-org/my-pipe")"#));
        assert!(query.contains("branch: [\"trunk\"]"));
        assert!(query.contains("state: [RUNNING, PASSED]"));
        assert!(query.contains("step: {key: [\"pipeline-gen\"]}"));
    }
}
