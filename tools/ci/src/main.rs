//! CI orchestrator: replaces shell-script pipeline-gen with a Rust binary.
//!
//! Subcommands:
//! - `pipeline-gen`: Compute changed targets via double nix-instantiate
//!   and emit Buildkite pipeline YAML.
//! - `build`: Run `nix-store --realise` with log parsing and annotation output.
//! - `post-build`: Post-build hooks (gcroot, notifications).

use anyhow::Result;
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
        #[arg(long, default_value = "trunk")]
        trunk_branch: String,

        /// Write the generated pipeline to this file instead of stdout.
        #[arg(long)]
        output: Option<String>,
    },

    /// Run nix-store --realise with log parsing.
    Build {
        /// Path to the drvmap JSON file containing targets to build.
        #[arg(long, default_value = "pipeline/drvmap.json")]
        drvmap_file: String,

        /// Write Buildkite annotations to this file instead of stdout.
        #[arg(long)]
        annotation_file: Option<String>,
    },

    /// Post-build: create gcroots, dispatch notifications.
    PostBuild,
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
            annotation_file,
        } => cmd_build(repo_root, &drvmap_file, annotation_file.as_deref()),

        Commands::PostBuild => cmd_post_build(repo_root),
    }
}

/// Pipeline generation: double instantiate, diff, emit YAML.
fn cmd_pipeline_gen(
    repo_root: &std::path::Path,
    trunk_branch: &str,
    output: Option<&str>,
) -> Result<()> {
    tracing::info!("computing merge-base with {}", trunk_branch);
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

    // Also write the current drvmap for the build steps to consume
    let drvmap_path = repo_root.join("pipeline").join("drvmap.json");
    if let Some(parent) = drvmap_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let drvmap_json = serde_json::to_string_pretty(&current_drvmap)?;
    std::fs::write(&drvmap_path, drvmap_json)?;
    tracing::info!("wrote drvmap to {}", drvmap_path.display());

    Ok(())
}

/// Build: run nix-store --realise on changed targets.
fn cmd_build(
    _repo_root: &std::path::Path,
    drvmap_file: &str,
    annotation_file: Option<&str>,
) -> Result<()> {
    // Load the full current drvmap (contains all targets)
    let full_drvmap = drvmap::load(std::path::Path::new(drvmap_file))?;

    // Compile env var — the pipeline step sets NIX_SYSTEM to filter
    // to just this system's targets.
    let target_system = std::env::var("NIX_SYSTEM").unwrap_or_default();

    // Filter to targets for this system
    let to_build: drvmap::Drvmap = if target_system.is_empty() {
        full_drvmap.clone()
    } else {
        full_drvmap
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

    let mut tracker = annotation::AnnotationTracker::new(&to_build);

    let success = realise::realise(&drv_paths, &drv_to_tree, &drv_to_system, &mut |event| {
        tracker.on_event(event);
        // Emit annotation periodically
        let annotation = tracker.render();
        if let Some(ref path) = annotation_file {
            let _ = std::fs::write(path, &annotation);
        }
    })?;

    // Final annotation
    let final_annotation = tracker.render();
    println!("{final_annotation}");

    if let Some(path) = annotation_file {
        std::fs::write(path, &final_annotation)?;
    }

    if !success {
        anyhow::bail!("some builds failed");
    }

    Ok(())
}

/// Post-build: gcroot management and notifications.
fn cmd_post_build(_repo_root: &std::path::Path) -> Result<()> {
    // TODO: Phase 2 — gcroot management, notification dispatch
    tracing::info!("post-build: nothing to do yet (phase 2)");
    Ok(())
}
