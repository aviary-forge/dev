//! CI orchestrator: replaces shell-script pipeline-gen with a Rust binary.
//!
//! Subcommands:
//! - `pipeline-gen`: Compute changed targets via double nix-instantiate
//!   and emit Buildkite pipeline YAML.
//! - `build`: Run `nix-store --realise` with log parsing, annotation posting,
//!   retry logic, and results file output.
//! - `post-build`: Aggregate per-system results, dispatch Discord notifications,
//!   and manage gcroots.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

mod annotation;
mod drvmap;
mod git;
mod instantiate;
mod pipeline;
mod realise;

/// CI orchestrator for a Nix-based monorepo.
#[derive(Parser)]
#[command(name = "ci-orchestrator", version = "0.1.0")]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Path to the repository root.
    #[arg(long, default_value = ".")]
    repo_root: String,
}

#[derive(Subcommand)]
enum Commands {
    /// Compute changed targets and emit Buildkite pipeline YAML.
    PipelineGen {
        /// The trunk branch name for merge-base computation.
        /// Defaults to origin/trunk so we always have the latest ref.
        #[arg(long, default_value = "origin/trunk")]
        trunk_branch: String,

        /// Write the generated pipeline to this file instead of stdout.
        #[arg(long)]
        output: Option<String>,
    },

    /// Run nix-store --realise with log parsing and annotation output.
    Build {
        /// Path to the drvmap JSON file containing targets to build.
        #[arg(long, default_value = "pipeline/drvmap.json")]
        drvmap_file: String,

        /// Maximum retries for transient failures (network, remote builder).
        #[arg(long, default_value = "3")]
        max_retries: u32,

        /// Throttle annotation updates to at most one per this many seconds.
        #[arg(long, default_value = "3")]
        annotation_throttle_secs: u64,
    },

    /// Post-build: aggregate results, dispatch Discord notifications, gcroot.
    PostBuild,

    /// Validate that every CI target has at least one owner.
    /// Reads a pre-computed drvmap file (from pipeline-gen) rather than
    /// re-running nix eval.
    ValidateOwners {
        /// Path to the drvmap JSON file.
        #[arg(long, default_value = "pipeline/drvmap.json")]
        drvmap_file: String,
    },
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();
    let repo_root = &cli.repo_root;
    let repo_root = std::path::Path::new(repo_root);

    match cli.command {
        Commands::PipelineGen {
            trunk_branch,
            output,
        } => cmd_pipeline_gen(repo_root, &trunk_branch, output.as_deref()),

        Commands::Build {
            drvmap_file,
            max_retries,
            annotation_throttle_secs,
        } => cmd_build(
            repo_root,
            &drvmap_file,
            max_retries,
            annotation_throttle_secs,
        ),

        Commands::PostBuild => cmd_post_build(repo_root),
        Commands::ValidateOwners { drvmap_file } => cmd_validate_owners(repo_root, &drvmap_file),
    }
}

// --- Shared types for results deserialization ---

#[derive(serde::Deserialize)]
struct ResultsFile {
    system: String,
    #[allow(dead_code)]
    branch: String,
    #[allow(dead_code)]
    commit: String,
    #[allow(dead_code)]
    success: bool,
    targets: Vec<TargetEntry>,
}

#[derive(serde::Deserialize)]
struct TargetEntry {
    tree_path: String,
    status: String,
    #[serde(default)]
    exit_code: Option<i64>,
    #[serde(default)]
    log_tail: Option<String>,
    #[serde(default)]
    owners: Vec<drvmap::Owner>,
}

// --- Subcommand implementations ---

/// Pipeline generation: double instantiate, diff, emit YAML.
fn cmd_pipeline_gen(
    repo_root: &std::path::Path,
    trunk_branch: &str,
    output: Option<&str>,
) -> Result<()> {
    tracing::info!("computing merge-base with {}", trunk_branch);

    // Buildkite agents only fetch the PR branch by default.
    // Ensure we have the latest trunk ref before diffing.
    if let Some(branch) = trunk_branch.strip_prefix("origin/") {
        git::fetch_branch(repo_root, branch)?;
    }

    let base_commit = git::merge_base(repo_root, trunk_branch)?;
    tracing::info!("base commit: {}", base_commit);

    // Create a worktree at the base commit
    tracing::info!("creating worktree at base commit");
    let worktree = git::create_worktree(repo_root, &base_commit, "base")?;

    // Instantiate drvmap at base commit
    tracing::info!("instantiating drvmap at base commit");
    let parent_drvmap = instantiate::instantiate_drvmap(repo_root, Some(&worktree))?;

    // Clean up the worktree
    git::remove_worktree(&worktree, repo_root)?;
    tracing::info!("parent drvmap has {} targets", parent_drvmap.len());

    // Instantiate drvmap at HEAD
    tracing::info!("instantiating drvmap at HEAD");
    let current_drvmap = instantiate::instantiate_drvmap(repo_root, None)?;
    tracing::info!("current drvmap has {} targets", current_drvmap.len());

    // Diff
    let diff = drvmap::diff(&parent_drvmap, &current_drvmap);
    tracing::info!(
        "changed: {} ({} added, {} changed, {} unchanged, {} removed)",
        diff.changed_count(),
        diff.added.len(),
        diff.changed.len(),
        diff.unchanged.len(),
        diff.removed.len(),
    );

    // Group by system
    let to_build = diff.to_build();
    let by_system = drvmap::group_by_system(&to_build);
    for (system, targets) in &by_system {
        tracing::info!("  {}: {} targets", system, targets.len());
    }

    // Generate pipeline
    let pipeline = pipeline::generate_pipeline(&by_system);
    let pipeline_str = serde_json::to_string_pretty(&pipeline)?;

    match output {
        Some(path) => std::fs::write(path, &pipeline_str)?,
        None => println!("{pipeline_str}"),
    }

    // Also write the current drvmap for future builds to diff against.
    let drvmap_path = repo_root.join("pipeline").join("drvmap.json");
    if let Some(parent) = drvmap_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let drvmap_json = serde_json::to_string_pretty(&current_drvmap)?;
    std::fs::write(&drvmap_path, drvmap_json)?;
    tracing::info!("wrote full drvmap to {}", drvmap_path.display());

    // Write the changed-only drvmap for the build steps to consume.
    // The build step should only build targets that actually changed,
    // not the full target set.
    let changed_path = repo_root.join("pipeline").join("drvmap-changed.json");
    let changed_json = serde_json::to_string_pretty(&to_build)?;
    std::fs::write(&changed_path, changed_json)?;
    tracing::info!(
        "wrote changed drvmap ({}) to {}",
        to_build.len(),
        changed_path.display()
    );

    Ok(())
}

/// Build: run nix-store --realise on changed targets with live annotation.
fn cmd_build(
    repo_root: &std::path::Path,
    drvmap_file: &str,
    max_retries: u32,
    annotation_throttle_secs: u64,
) -> Result<()> {
    // Load the changed-target drvmap (only targets that differ from base).
    let changed_drvmap = drvmap::load(std::path::Path::new(drvmap_file))?;

    // The pipeline step sets NIX_SYSTEM to scope this agent to its platform.
    let target_system = std::env::var("NIX_SYSTEM").unwrap_or_default();

    // Filter to targets for this system
    let to_build: drvmap::Drvmap = if target_system.is_empty() {
        changed_drvmap.clone()
    } else {
        changed_drvmap
            .iter()
            .filter(|(_, info)| info.system.as_deref().unwrap_or_default() == target_system)
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    };

    tracing::info!(
        "building {} targets for system '{}'",
        to_build.len(),
        target_system
    );

    let drv_paths = realise::drv_paths(&to_build);
    let (drv_to_tree, drv_to_system) = realise::build_lookup_maps(&to_build);

    let mut tracker = annotation::AnnotationTracker::new(&to_build, &target_system);

    // Post initial annotation
    let initial = tracker.render_main();
    let _ = annotation::post_annotation(&tracker.main_context(), "info", &initial);

    // Throttle state for annotation updates
    let mut last_annotation = std::time::Instant::now();
    let throttle = std::time::Duration::from_secs(annotation_throttle_secs);

    let (results, all_succeeded) = realise::realise(
        &drv_paths,
        &drv_to_tree,
        &drv_to_system,
        max_retries,
        &mut |event| {
            tracker.on_event(event);

            // Post log tail if this is a failure event with log data
            if let Some(ref log_tail) = event.log_tail {
                tracker.set_log_tail(&event.tree_path, log_tail.clone());
            }

            // Throttled annotation update
            let now = std::time::Instant::now();
            if now.duration_since(last_annotation) >= throttle {
                last_annotation = now;
                let annotation = tracker.render_main();
                let _ = annotation::post_annotation(&tracker.main_context(), "info", &annotation);
            }
        },
    )?;

    // Final annotation update (always post)
    let final_annotation = tracker.render_main();
    let _ = annotation::post_annotation(
        &tracker.main_context(),
        if all_succeeded { "success" } else { "error" },
        &final_annotation,
    );

    // Post failure summary if any failures exist
    if let Some(failure_summary) = tracker.render_failure_summary() {
        let _ = annotation::post_annotation(&tracker.failure_context(), "error", &failure_summary);
    }

    // Write results file for post-build consumption
    let results_dir = repo_root.join("pipeline");
    std::fs::create_dir_all(&results_dir)?;
    let results_file = results_dir.join(format!("results-{}.json", target_system));

    let results_json = build_results_json(&target_system, &results, &tracker)?;
    std::fs::write(&results_file, &results_json)?;
    tracing::info!("wrote results to {}", results_file.display());

    if !all_succeeded {
        anyhow::bail!("some builds failed");
    }

    Ok(())
}

/// Build the results JSON payload from the realise output and tracker state.
fn build_results_json(
    system: &str,
    results: &std::collections::HashMap<String, realise::TargetResult>,
    tracker: &annotation::AnnotationTracker,
) -> Result<String> {
    let branch = std::env::var("BUILDKITE_BRANCH").unwrap_or_default();
    let commit = std::env::var("BUILDKITE_COMMIT").unwrap_or_default();

    let mut targets: Vec<serde_json::Value> = Vec::new();

    for (tree_path, status) in tracker.all_targets() {
        let owners: Vec<serde_json::Value> = status
            .owners
            .iter()
            .map(|o| {
                serde_json::json!({
                    "discord": o.discord,
                    "github": o.github,
                })
            })
            .collect();

        let result_entry = results.get(tree_path);

        targets.push(serde_json::json!({
            "tree_path": tree_path,
            "drv_path": status.drv_path,
            "status": match &status.state {
                annotation::BuildState::Succeeded => "succeeded",
                annotation::BuildState::Failed => "failed",
                annotation::BuildState::Skipped => "skipped",
                annotation::BuildState::Building => "building",
                annotation::BuildState::Pending => "pending",
            },
            "duration_ms": status.duration_ms,
            "exit_code": result_entry.and_then(|r| r.exit_code),
            "owners": owners,
            "log_tail": result_entry.and_then(|r| r.log_tail.clone()),
        }));
    }

    let json = serde_json::json!({
        "system": system,
        "branch": branch,
        "commit": commit,
        "success": tracker.all_succeeded(),
        "targets": targets,
    });

    serde_json::to_string_pretty(&json).context("serializing results JSON")
}

/// Validate that every CI target has at least one owner with a GitHub
/// or Discord identity.  Posts a Buildkite annotation and fails if any
/// targets are unowned.
fn cmd_validate_owners(repo_root: &std::path::Path, drvmap_file: &str) -> Result<()> {
    tracing::info!("validating owners from {drvmap_file}");

    // Load the pre-computed drvmap (pipeline-gen already ran nix eval).
    let current_drvmap = drvmap::load(std::path::Path::new(drvmap_file))?;

    let _ = repo_root; // unused now, kept for consistency

    let unowned: Vec<&str> = current_drvmap
        .iter()
        .filter(|(_, info)| {
            info.owners.is_empty()
                || info.owners.iter().all(|o| {
                    o.github.as_deref().is_none_or(|s| s.is_empty())
                        && o.discord.as_deref().is_none_or(|s| s.is_empty())
                })
        })
        .map(|(tree_path, _)| tree_path.as_str())
        .collect();

    if unowned.is_empty() {
        tracing::info!("all {} targets have valid owners", current_drvmap.len());

        // Post a green annotation for visibility.
        let _ = annotation::post_annotation(
            "validate-owners",
            "success",
            &format!(
                "### :white_check_mark: Owner validation passed\n\nAll {} targets have at least one owner.",
                current_drvmap.len()
            ),
        );

        return Ok(());
    }

    // Build a failure annotation listing unowned targets.
    let mut md = format!(
        "### :no_entry: Owner validation failed\n\n{} of {} targets have **no owners** assigned.\n\n",
        unowned.len(),
        current_drvmap.len(),
    );
    md.push_str("| Target |\n");
    md.push_str("|--------|\n");
    for path in &unowned {
        md.push_str(&format!("| `{path}` |\n"));
    }
    md.push_str("\nEach target must declare `meta.owners` in its Nix expression.\n");

    let _ = annotation::post_annotation("validate-owners", "error", &md);

    anyhow::bail!(
        "{} unowned target(s): {}",
        unowned.len(),
        unowned.join(", ")
    );
}

/// Post-build: download per-system results artifacts, aggregate, dispatch
/// Discord notifications, and create gcroots for trunk builds.
fn cmd_post_build(repo_root: &std::path::Path) -> Result<()> {
    tracing::info!("post-build: downloading results artifacts");

    // Download per-system results artifacts
    let pipeline_dir = repo_root.join("pipeline");
    std::fs::create_dir_all(&pipeline_dir)?;

    let download = std::process::Command::new("buildkite-agent")
        .args(["artifact", "download", "pipeline/results-*.json", "."])
        .current_dir(repo_root)
        .output()
        .context("downloading results artifacts")?;

    if !download.status.success() {
        let stderr = String::from_utf8_lossy(&download.stderr);
        // Not fatal — there might not be any results files
        tracing::warn!("artifact download: {stderr}");
    }

    // Find all results files
    let mut results_paths: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&pipeline_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with("results-") && name_str.ends_with(".json") {
                results_paths.push(entry.path());
            }
        }
    }

    if results_paths.is_empty() {
        tracing::info!("no results files found, nothing to do");
        return Ok(());
    }

    tracing::info!("found {} results file(s)", results_paths.len());

    // Parse and aggregate
    let mut all_results: Vec<ResultsFile> = Vec::new();
    for path in &results_paths {
        let data =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let rf: ResultsFile =
            serde_json::from_str(&data).with_context(|| format!("parsing {}", path.display()))?;
        all_results.push(rf);
    }

    // Dispatch Discord notifications
    dispatch_notifications(&all_results)?;

    // Gcroot management for trunk builds
    let branch = std::env::var("BUILDKITE_BRANCH").unwrap_or_default();
    if branch == "trunk" {
        create_gcroots(repo_root)?;
    }

    Ok(())
}

/// Dispatch Discord webhook notifications for build failures.
fn dispatch_notifications(all_results: &[ResultsFile]) -> Result<()> {
    let webhook_url = std::env::var("DISCORD_WEBHOOK_URL").unwrap_or_default();
    if webhook_url.is_empty() {
        tracing::info!("DISCORD_WEBHOOK_URL not set, skipping Discord notifications");
        return Ok(());
    }

    let branch = std::env::var("BUILDKITE_BRANCH").unwrap_or_default();
    let build_url = std::env::var("BUILDKITE_BUILD_URL").unwrap_or_default();
    let is_trunk = branch == "trunk";

    // Collect all failed targets, grouped by owner
    let mut failures_by_owner: std::collections::HashMap<String, Vec<&TargetEntry>> =
        std::collections::HashMap::new();
    let mut any_failure = false;

    for rf in all_results {
        for target in &rf.targets {
            if target.status == "failed" {
                any_failure = true;

                if target.owners.is_empty() {
                    failures_by_owner
                        .entry("unknown".to_string())
                        .or_default()
                        .push(target);
                } else {
                    for owner in &target.owners {
                        let key = owner.discord.clone().unwrap_or_else(|| {
                            owner
                                .github
                                .clone()
                                .unwrap_or_else(|| "unknown".to_string())
                        });
                        failures_by_owner.entry(key).or_default().push(target);
                    }
                }
            }
        }
    }

    if !any_failure {
        // Trunk success → compact green blip to #ci channel
        if is_trunk {
            let total_targets: usize = all_results.iter().map(|r| r.targets.len()).sum();

            let content = format!(
                "🟢 **trunk** — {} targets built successfully\n[View build →]({})",
                total_targets, build_url
            );
            send_discord_webhook(&webhook_url, &content, 0x00FF00)?;
        }
        return Ok(());
    }

    // For each owner, send a notification with their failed targets
    for (owner_key, targets) in &failures_by_owner {
        let system_list: Vec<&str> = all_results.iter().map(|r| r.system.as_str()).collect();
        let systems_str = system_list.join(", ");

        let mut content = format!(
            "🔴 **Build failure** — `{}`\n\n**System:** `{}`\n**Failed targets ({}):**\n\n",
            branch,
            systems_str,
            targets.len()
        );

        for t in targets {
            let exit_str = match t.exit_code {
                Some(code) => format!("(exit {})", code),
                None => String::new(),
            };
            content.push_str(&format!("- `{}` {}\n", t.tree_path, exit_str));
        }

        content.push_str(&format!("\n[View build →]({})", build_url));

        let _ = send_discord_webhook(&webhook_url, &content, 0xFF0000);

        // Try to base64-decode the discord snowflake and ping the user
        if let Ok(decoded) = decode_discord_snowflake(owner_key) {
            let ping_content = format!(
                "<@{}> your changes broke {} target(s) in `{}`:\n",
                decoded,
                targets.len(),
                branch
            );
            let _ = send_discord_webhook(&webhook_url, &ping_content, 0xFF0000);
        }
    }

    Ok(())
}

/// Base64-decode a Discord snowflake (user ID).
fn decode_discord_snowflake(encoded: &str) -> Result<String, String> {
    let decoded = base64_decode(encoded)?;
    if decoded.chars().all(|c| c.is_ascii_digit()) {
        Ok(decoded)
    } else {
        Err("not a numeric snowflake".to_string())
    }
}

/// Minimal base64 decode (standard alphabet).
fn base64_decode(input: &str) -> Result<String, String> {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut chars: Vec<u8> = Vec::new();

    for c in input.chars() {
        if c == '=' {
            break;
        }
        if let Some(pos) = alphabet.find(c) {
            chars.push(pos as u8);
        } else {
            return Err(format!("invalid base64 char: {c}"));
        }
    }

    if chars.is_empty() {
        return Ok(String::new());
    }

    let mut result = Vec::new();
    for chunk in chars.chunks(4) {
        let b0 = u32::from(chunk.first().copied().unwrap_or(0));
        let b1 = u32::from(chunk.get(1).copied().unwrap_or(0));
        let b2 = u32::from(chunk.get(2).copied().unwrap_or(0));
        let b3 = u32::from(chunk.get(3).copied().unwrap_or(0));

        let combined = (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;

        result.push(((combined >> 16) & 0xFF) as u8);
        if chunk.len() > 2 {
            result.push(((combined >> 8) & 0xFF) as u8);
        }
        if chunk.len() > 3 {
            result.push((combined & 0xFF) as u8);
        }
    }

    String::from_utf8(result).map_err(|e| format!("invalid UTF-8: {e}"))
}

/// Send a message to a Discord webhook via curl.
fn send_discord_webhook(webhook_url: &str, content: &str, color: u32) -> Result<()> {
    let payload = serde_json::json!({
        "embeds": [{
            "description": content,
            "color": color,
        }]
    });

    let payload_str = serde_json::to_string(&payload)?;

    let output = std::process::Command::new("curl")
        .args([
            "-s",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-d",
            &payload_str,
            webhook_url,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .output()
        .context("sending Discord webhook via curl")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::warn!("Discord webhook failed: {stderr}");
    } else {
        tracing::info!("Discord notification sent");
    }

    Ok(())
}

/// Create gcroots for all built outputs on trunk to prevent GC.
fn create_gcroots(repo_root: &std::path::Path) -> Result<()> {
    tracing::info!("creating gcroots for trunk build");

    let gcroots_dir = repo_root.join("gcroots");
    std::fs::create_dir_all(&gcroots_dir)?;

    let output = std::process::Command::new("nix-build")
        .args(["-A", "ci.gcroot", "--no-out-link"])
        .current_dir(repo_root)
        .output()
        .context("nix-build ci.gcroot")?;

    if output.status.success() {
        tracing::info!("gcroots created successfully");
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::warn!("gcroot creation failed (non-fatal): {stderr}");
    }

    Ok(())
}
