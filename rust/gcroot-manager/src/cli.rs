use std::path::PathBuf;

use clap::Parser;

/// Very simple tool to "keep the last N commits as gcroots"
/// This tool:
/// - accepts an artifact that you would like to keep as a gcroot ref (should
///   ideally represent the commit we are running as)
/// - assumes you are always running at the latest of your main branch
/// - lists the last N commits (including HEAD)
/// - creates a symlink to the HEAD commit to the given artifact
#[derive(Debug, Parser)]
pub struct Args {
    /// The item to symlink to. Should be an item in the Nix store that
    /// contains the derivations you want to keep from being GC'd
    #[arg(short = 'p', long = "artifact-path", env = "GCROOT_ARTIFACT_PATH")]
    pub artifact: PathBuf,

    /// The directory to manage for our gcroots
    #[arg(
        short = 'd',
        long,
        env = "GCROOT_GCROOT_DIR",
        default_value = "/nix/var/nix/gcroot/ci"
    )]
    pub gcroot_dir: PathBuf,

    /// The git repository we are creating gcroots for
    #[arg(short, long, env = "BUILDKITE_BUILD_CHECKOUT_PATH")]
    pub repository_dir: Option<PathBuf>,

    /// The number of commits to keep gcroots for
    #[arg(short = 'n', long, env = "GCROOT_COMMITS_TO_KEEP", default_value_t = 5)]
    pub commits_to_keep: u8,
}
