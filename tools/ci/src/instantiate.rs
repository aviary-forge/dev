//! Run `nix eval` to produce a drvmap from Nix expressions.

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};

use crate::drvmap::Drvmap;

/// Path to the Nix expression that produces a drvmap.
/// Relative to the repo root.
const DRVMAP_EXPR: &str = "tools/ci/drvmap.nix";

/// Run `nix eval --json -f <expr> drvmap` in the given directory
/// and parse the JSON output into a Drvmap.
///
/// For the base commit, this is run in a temporary worktree. For HEAD,
/// this is run in the current repo.
///
/// When evaluating in a worktree, the `drvmap.nix` file may not exist
/// there (it was created on the current branch). In that case we copy
/// it from `repo_root` into the worktree so `nix eval` can find it.
/// The file's internal `import ../..` resolves relative to its physical
/// location, so placing it in the worktree ensures it picks up the
/// base commit's Nix code for the parent drvmap.
pub fn instantiate_drvmap(repo_root: &Path, worktree: Option<&Path>) -> Result<Drvmap> {
    let cwd = worktree.unwrap_or(repo_root);

    // If evaluating in a worktree, ensure drvmap.nix exists there.
    // The file was created on this branch and may not exist at the base commit.
    let drvmap_path = if worktree.is_some() {
        let target = cwd.join(DRVMAP_EXPR);
        if !target.exists() {
            let source = repo_root.join(DRVMAP_EXPR);
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("creating {}", parent.display()))?;
            }
            std::fs::copy(&source, &target)
                .with_context(|| format!("copying {} -> {}", source.display(), target.display()))?;
            tracing::info!("copied drvmap.nix to worktree at {}", target.display());
        }
        target
    } else {
        cwd.join(DRVMAP_EXPR)
    };

    let output = Command::new("nix")
        .args([
            "eval",
            "--json",
            "-f",
            drvmap_path.to_str().unwrap(),
            "drvmap",
        ])
        .current_dir(cwd)
        .output()
        .with_context(|| {
            format!(
                "nix eval --json -f {} drvmap in {}",
                DRVMAP_EXPR,
                cwd.display()
            )
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("nix eval failed: {stderr}");
    }

    let stdout = String::from_utf8(output.stdout).context("invalid UTF-8 from nix eval")?;

    crate::drvmap::parse(&stdout).context("parsing drvmap from nix eval output")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_drvmap_expr_exists() {
        // Tests run with cwd = crate root (tools/ci/).
        // The workspace root is two levels up.
        let workspace_root = Path::new("../..");
        let path = workspace_root.join(DRVMAP_EXPR);
        // In Nix sandboxes (crane builds), .nix files are filtered out
        // by cleanCargoSource. Skip rather than fail.
        if !path.exists() {
            eprintln!(
                "skipping: {} not found (filtered in sandbox?)",
                path.display()
            );
            return;
        }
    }
}
